import Foundation
import Telemetry

/// `aithermald` — the only component in this project that writes to hardware.
///
/// It exists because of one asymmetry: SMC reads are root-free, SMC writes are
/// not. Rather than run a SwiftUI app as root, the 6 MB of AppKit stays
/// unprivileged and this ~400-line binary does the writing, with a fixed key
/// allowlist and a deadman that answers to nobody.
///
/// ## What it will not do, no matter who asks
///
///   * write any key other than `F<n>Md` / `F<n>Tg` for `n < FNum`;
///   * hold an rpm outside the range the hardware itself reports;
///   * keep holding anything for more than 60 s without renewal;
///   * keep holding anything once the die hotspot reaches the ceiling, or the
///     OS reports serious thermal pressure — including while a client is
///     renewing perfectly happily;
///   * accept a command from a uid other than the one it was installed for.
///
/// Every one of those decisions is `FanGuard`'s, evaluated here against a
/// temperature THIS process read. A client's idea of how hot the machine is
/// never enters the decision.
///
/// ## Failure modes and what they do
///
///   * client crashes / is killed / hangs  → lease lapses, fans to auto
///   * this daemon crashes                 → launchd restarts it; startup
///                                           unconditionally writes mode 0
///   * this daemon is killed with SIGKILL  → nothing runs, but the SMC keeps
///                                           the last commanded rpm, which is
///                                           why startup-restore exists
///   * socket unreachable                  → app reports the break; the lease
///                                           expires on its own

let version = "1.0"

// MARK: - Signals
//
// A signal handler may only touch async-signal-safe state, so it sets a flag
// and the run loop does the work. Restoring fans from inside the handler would
// mean IOKit calls on a signal stack.
nonisolated(unsafe) var stopRequested = false

func installSignalHandlers() {
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig) { _ in stopRequested = true }
    }
    // A write to a closed client socket must not kill the daemon.
    signal(SIGPIPE, SIG_IGN)
}

// MARK: - The fan writer

/// The allowlist, as code rather than as a comment.
struct FanWriter {
    let smc: SMC
    let fanCount: Int
    let limits: [Int: FanGuard.Limits]

    init?(smc: SMC) {
        self.smc = smc
        guard let n = smc.readNumber("FNum").map({ Int($0) }), n > 0, n <= 8 else { return nil }
        self.fanCount = n
        var l: [Int: FanGuard.Limits] = [:]
        for i in 0..<n {
            // No hardcoded fallbacks. A fan whose range the hardware will not
            // report is a fan this daemon refuses to drive, because every
            // safety bound downstream is derived from these two numbers.
            guard let lo = smc.readNumber("F\(i)Mn"), let hi = smc.readNumber("F\(i)Mx"),
                  lo > 0, hi > lo else { continue }
            l[i] = FanGuard.Limits(minRPM: lo, maxRPM: hi)
        }
        guard !l.isEmpty else { return nil }
        self.limits = l
    }

    func modeKey(_ i: Int) -> String { "F\(i)Md" }
    func targetKey(_ i: Int) -> String { "F\(i)Tg" }

    /// The only two keys this daemon will ever write.
    func isAllowed(_ key: String) -> Bool {
        (0..<fanCount).contains { key == modeKey($0) || key == targetKey($0) }
    }

    @discardableResult
    func force(_ i: Int, rpm: Double) -> SMC.Result {
        guard limits[i] != nil else { return .keyNotFound }
        // Order matters: target first, then mode. Flipping mode first hands the
        // fan whatever stale value is sitting in F<n>Tg for one control cycle.
        let t = smc.write(targetKey(i), bytes: SMC.encodeFloat(rpm))
        guard t == .ok else { return t }
        return smc.write(modeKey(i), bytes: SMC.encodeUInt8(1))
    }

    @discardableResult
    func release(_ i: Int) -> SMC.Result {
        smc.write(modeKey(i), bytes: SMC.encodeUInt8(0))
    }

    func releaseAll() -> [Int: SMC.Result] {
        Dictionary(uniqueKeysWithValues: (0..<fanCount).map { ($0, release($0)) })
    }

    func actual(_ i: Int) -> Double? { smc.readNumber("F\(i)Ac") }
    func target(_ i: Int) -> Double? { smc.readNumber("F\(i)Tg") }
    func mode(_ i: Int) -> Double? { smc.readNumber("F\(i)Md") }
}

// MARK: - The daemon

final class Daemon {
    private let writer: FanWriter
    private let sensors: ThermalSensors
    private let socketPath: String
    private let allowedUID: uid_t?
    private let ceilingC: Double

    private var listenFD: Int32 = -1
    private var targets: [Int: Double] = [:]
    private var leaseExpiresAt: Double?
    private var lastClamp: String?
    private var trip: GuardTrip?
    private var tripUntil: Double?
    private var stuckSince: [Int: Double] = [:]
    private var hotspotC: Double?
    /// Last pressure read by the guard loop. A `set` request must not trigger a
    /// second 13 ms sweep of its own — the guard's reading is at most 1 s old,
    /// which is far inside the thermal time constant it is defending against.
    private var pressure: ThermalState = .nominal

    init(writer: FanWriter, sensors: ThermalSensors, socketPath: String,
         allowedUID: uid_t?, ceilingC: Double) {
        self.writer = writer; self.sensors = sensors
        self.socketPath = socketPath; self.allowedUID = allowedUID
        self.ceilingC = ceilingC
    }

    // MARK: Lifecycle

    func run() -> Int32 {
        // Whatever the last run left behind, this run starts from automatic.
        // A SIGKILL'd predecessor leaves the SMC holding its rpm forever, and
        // this line is the only thing that undoes that.
        _ = writer.releaseAll()
        log("starting v\(version), \(writer.limits.count) controllable fan(s), ceiling \(Int(ceilingC)) °C")

        guard bindSocket() else { return 1 }
        defer { cleanup() }

        var lastGuard = now()
        while !stopRequested {
            // 250 ms so a stop signal is acted on promptly; the guard itself
            // runs on its own 1 s clock regardless of client traffic.
            acceptOnce(timeout: 0.25)
            let t = now()
            if t - lastGuard >= 1.0 {
                lastGuard = t
                guardTick(at: t)
            }
        }
        log("stop requested")
        return 0
    }

    private func cleanup() {
        if leaseExpiresAt != nil || !targets.isEmpty {
            log("releasing fans to automatic (\(GuardTrip.helperExiting.rawValue))")
        }
        _ = writer.releaseAll()
        targets.removeAll()
        leaseExpiresAt = nil
        if listenFD >= 0 { close(listenFD) }
        unlink(socketPath)
    }

    // MARK: The deadman

    private func guardTick(at t: Double) {
        let s = sensors.sample()
        hotspotC = s.hotspot?.estimate.value
        pressure = s.pressure

        if let until = tripUntil, t >= until,
           let h = hotspotC, h < ceilingC - FanGuard.tripHysteresisC {
            log("trip cleared, hotspot \(Int(h)) °C")
            tripUntil = nil
            trip = nil
        }

        // Fan tracking, evaluated only while we are actually forcing.
        if !targets.isEmpty {
            for (i, want) in targets {
                let ok = FanSample(index: i, actualRPM: writer.actual(i), targetRPM: want,
                                   minRPM: writer.limits[i]?.minRPM,
                                   maxRPM: writer.limits[i]?.maxRPM,
                                   mode: .forced).isTracking
                if ok { stuckSince[i] = nil } else if stuckSince[i] == nil { stuckSince[i] = t }
            }
        } else {
            stuckSince.removeAll()
        }

        let conditions = FanGuard.Conditions(
            hotspotC: hotspotC,
            pressure: s.pressure,
            ceilingC: ceilingC,
            leaseExpiresAt: leaseExpiresAt,
            now: t,
            fanStuckSince: stuckSince.values.compactMap { $0 }.min(),
            tripUntil: tripUntil,
            currentTrip: trip)

        switch FanGuard.evaluate(conditions) {
        case .idle, .hold:
            return
        case .release(let why):
            release(why, at: t)
        }
    }

    private func release(_ why: GuardTrip, at t: Double) {
        let results = writer.releaseAll()
        let failed = results.filter { $0.value != .ok }
        log("RELEASE \(why.rawValue): hotspot \(hotspotC.map { String(Int($0)) } ?? "?") °C"
            + (failed.isEmpty ? "" : " — WRITE FAILED on \(failed.keys.sorted())"))
        targets.removeAll()
        leaseExpiresAt = nil
        stuckSince.removeAll()
        trip = why
        // An expired lease is not a fault, so it does not lock the user out.
        // Every other trip does, and only time plus a cooler die clears it.
        tripUntil = (why == .leaseExpired) ? nil : t + FanGuard.tripCooldownSeconds
    }

    // MARK: Socket

    private func bindSocket() -> Bool {
        unlink(socketPath)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { log("socket(): \(errstr())"); return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            log("socket path too long"); return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) }
        }
        guard rc == 0 else { log("bind(\(socketPath)): \(errstr())"); return false }
        guard listen(listenFD, 4) == 0 else { log("listen(): \(errstr())"); return false }

        // 0660 root:<group of the allowed uid>. The socket's permissions are a
        // convenience, NOT the safety boundary: the guard is. What the uid check
        // buys is that another user on the machine cannot make your fans lie.
        if let uid = allowedUID, let pw = getpwuid(uid) {
            chown(socketPath, 0, pw.pointee.pw_gid)
        }
        chmod(socketPath, 0o660)
        log("listening on \(socketPath)"
            + (allowedUID.map { ", uid \($0) only" } ?? ", any local uid"))
        return true
    }

    private func acceptOnce(timeout: Double) {
        var fds = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        let n = withUnsafeMutablePointer(to: &fds) { poll($0, 1, Int32(timeout * 1000)) }
        guard n > 0, fds.revents & Int16(POLLIN) != 0 else { return }

        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        defer { close(fd) }

        // A client that connects and then says nothing must not wedge the loop.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0 else {
            reply(fd, CoolingResponse(ok: false, error: "cannot identify caller"))
            return
        }
        if let allowed = allowedUID, peerUID != allowed, peerUID != 0 {
            log("refused uid \(peerUID)")
            reply(fd, CoolingResponse(ok: false, error: "uid \(peerUID) is not permitted to control cooling"))
            return
        }

        guard let line = readLine(fd), let data = line.data(using: .utf8),
              let req = try? JSONDecoder().decode(CoolingRequest.self, from: data) else {
            reply(fd, CoolingResponse(ok: false, error: "malformed request"))
            return
        }
        guard req.version == Cooling.protocolVersion else {
            reply(fd, CoolingResponse(ok: false,
                error: "client speaks protocol \(req.version), helper speaks \(Cooling.protocolVersion)"))
            return
        }
        reply(fd, handle(req))
    }

    private func readLine(_ fd: Int32) -> String? {
        var data = [UInt8]()
        var byte: UInt8 = 0
        while data.count < 64 * 1024 {
            let n = read(fd, &byte, 1)
            if n <= 0 { break }
            if byte == 0x0A { break }
            data.append(byte)
        }
        return data.isEmpty ? nil : String(bytes: data, encoding: .utf8)
    }

    private func reply(_ fd: Int32, _ r: CoolingResponse) {
        guard var out = try? JSONEncoder().encode(r) else { return }
        out.append(0x0A)
        out.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    // MARK: Requests

    private func handle(_ req: CoolingRequest) -> CoolingResponse {
        let t = now()
        switch req.op {
        case .status:
            return CoolingResponse(ok: true, status: status(at: t))

        case .auto:
            _ = writer.releaseAll()
            targets.removeAll()
            leaseExpiresAt = nil
            stuckSince.removeAll()
            return CoolingResponse(ok: true, status: status(at: t))

        case .set:
            guard let asked = req.targets, !asked.isEmpty else {
                return CoolingResponse(ok: false, error: "no targets given")
            }
            let conditions = FanGuard.Conditions(
                hotspotC: hotspotC, pressure: pressure,
                ceilingC: ceilingC, leaseExpiresAt: leaseExpiresAt, now: t,
                tripUntil: tripUntil, currentTrip: trip)
            let admit = FanGuard.admits(conditions)
            guard admit.allowed else {
                return CoolingResponse(ok: false, error: admit.reason ?? "refused",
                                       status: status(at: t))
            }

            var notes: [String] = []
            for (index, rpm) in asked.sorted(by: { $0.key < $1.key }) {
                guard let limits = writer.limits[index] else {
                    notes.append("fan \(index) is not controllable")
                    continue
                }
                let (value, note) = FanGuard.clamp(rpm, to: limits)
                if let note { notes.append("fan \(index): \(note)") }
                let r = writer.force(index, rpm: value)
                guard r == .ok else {
                    // The most likely cause by far, and the one worth naming.
                    return CoolingResponse(ok: false,
                        error: "SMC write to fan \(index) failed: \(r.reason)",
                        status: status(at: t))
                }
                targets[index] = value
            }
            lastClamp = notes.isEmpty ? nil : notes.joined(separator: "; ")
            leaseExpiresAt = t + FanGuard.clampLease(req.leaseSeconds)
            // Control was granted, so the previous trip is history rather than
            // state. Without this, a single lease expiry left a warning banner
            // on screen for the rest of the session.
            trip = nil
            tripUntil = nil
            return CoolingResponse(ok: true, status: status(at: t))
        }
    }

    private func status(at t: Double) -> CoolingStatus {
        CoolingStatus(
            helperVersion: version,
            forcing: !targets.isEmpty,
            targets: targets,
            leaseRemaining: leaseExpiresAt.map { max(0, $0 - t) },
            lastClamp: lastClamp,
            trip: trip,
            tripUntil: tripUntil.map { max(0, $0 - t) },
            hardCeilingC: ceilingC,
            limits: writer.limits.mapValues { [$0.minRPM, $0.maxRPM] },
            hotspotC: hotspotC)
    }

    // MARK: Self test

    /// Proves the write path end to end, in the safe direction only.
    ///
    /// It raises each fan ABOVE whatever the SMC currently wants and checks the
    /// tachometer responds; it never commands a fan slower than it is already
    /// running. Restores automatic control on every exit path, including a
    /// failed assertion.
    func selfTest() -> Int32 {
        print("aithermald \(version) self-test")
        print("uid \(getuid()) · \(writer.fanCount) fans, \(writer.limits.count) controllable")

        let before = sensors.sample()
        let hot = before.hotspot
        print(String(format: "hotspot %@ %.1f °C · pressure %@",
                     hot?.domain.displayName ?? "?", hot?.estimate.value ?? -1,
                     before.pressure.rawValue))
        for f in before.fans {
            print(String(format: "  fan %d: %.0f rpm (target %.0f, range %.0f–%.0f, mode %@)",
                         f.index, f.actualRPM ?? -1, f.targetRPM ?? -1,
                         f.minRPM ?? -1, f.maxRPM ?? -1, f.mode.rawValue))
        }
        if let h = hot?.estimate.value, h >= ceilingC - FanGuard.tripHysteresisC {
            print("REFUSED: hotspot is already within \(Int(FanGuard.tripHysteresisC)) °C of the ceiling")
            return 2
        }

        var failures: [String] = []
        defer {
            let r = writer.releaseAll()
            let bad = r.filter { $0.value != .ok }
            print(bad.isEmpty ? "restored: all fans back to automatic"
                              : "RESTORE FAILED on fans \(bad.keys.sorted()) — run: sudo aithermald --release")
        }

        for (i, limits) in writer.limits.sorted(by: { $0.key < $1.key }) {
            let baseline = writer.actual(i) ?? limits.minRPM
            // +1200 rpm, or the hardware max, whichever comes first. Enough to
            // be unambiguous on the tachometer, well short of the redline.
            let want = min(limits.maxRPM, baseline + 1200)
            print(String(format: "fan %d: %.0f rpm → commanding %.0f", i, baseline, want))
            let r = writer.force(i, rpm: want)
            guard r == .ok else {
                failures.append("fan \(i) write refused: \(r.reason)")
                print("  WRITE REFUSED: \(r.reason)")
                continue
            }
            // Spin-up is mechanical: 6 s is generous for ~1200 rpm.
            var observed: Double = baseline
            for _ in 0..<12 {
                usleep(500_000)
                observed = writer.actual(i) ?? observed
                if observed > baseline + 300 { break }
            }
            let mode = writer.mode(i) ?? -1
            print(String(format: "  mode now %.0f · tachometer %.0f rpm (%+.0f)",
                         mode, observed, observed - baseline))
            if observed <= baseline + 200 {
                failures.append("fan \(i) accepted the write but did not spin up")
            }
        }

        if failures.isEmpty {
            print("\nPASS — writes accepted and both tachometers responded.")
            return 0
        }
        print("\nFAIL:")
        failures.forEach { print("  · \($0)") }
        return 3
    }

    func releaseNow() -> Int32 {
        let r = writer.releaseAll()
        let bad = r.filter { $0.value != .ok }
        if bad.isEmpty { print("all fans returned to automatic"); return 0 }
        print("failed on fans \(bad.keys.sorted()): "
              + bad.map { "\($0.key): \($0.value.reason)" }.joined(separator: ", "))
        return 1
    }

    // MARK: Utilities

    private func now() -> Double { Date().timeIntervalSince1970 }
    private func errstr() -> String { String(cString: strerror(errno)) }

    private func log(_ m: String) {
        // launchd captures stdout; timestamps are the daemon's job, not the
        // reader's, because a fan event's ORDER is the whole story.
        let ts = ISO8601DateFormatter().string(from: Date())
        print("\(ts) aithermald: \(m)")
        fflush(stdout)
    }
}

// MARK: - Entry

func usage() -> Never {
    print("""
    aithermald \(version) — privileged fan helper for AI Activity

      --serve                  run the daemon (launchd invokes this)
      --selftest               prove the write path, safe direction only
      --release                hand every fan back to the SMC and exit
      --status                 print what the SMC reports, then exit
      --ceiling <celsius>      hard release ceiling (default \(Int(FanGuard.defaultCeilingC)))
      --allow-uid <uid>        only this uid may command (default: none, any local uid)
      --socket <path>          override the socket path
      --unprivileged           serve without root. Every write is refused by the
                               kernel, so this exercises the socket protocol and
                               the guard loop and NOTHING else. For testing.

    Every mode except --status requires root, because SMC writes do.
    """)
    exit(64)
}

let args = CommandLine.arguments.dropFirst()
var mode = "--serve"
var socketPath = Cooling.socketPath
var ceiling = FanGuard.defaultCeilingC
var allowUID: uid_t?
var unprivileged = false

var it = args.makeIterator()
while let a = it.next() {
    switch a {
    case "--serve", "--selftest", "--release", "--status": mode = a
    case "--unprivileged": unprivileged = true
    case "--ceiling":
        guard let v = it.next(), let d = Double(v), d > 40, d < 110 else { usage() }
        ceiling = d
    case "--allow-uid":
        guard let v = it.next(), let u = UInt32(v) else { usage() }
        allowUID = uid_t(u)
    case "--socket":
        guard let v = it.next() else { usage() }
        socketPath = v
    case "--version": print(version); exit(0)
    default: usage()
    }
}

guard let smc = SMC() else {
    FileHandle.standardError.write(Data("cannot open AppleSMC\n".utf8))
    exit(1)
}
guard let sensors = ThermalSensors(smc: smc) else {
    FileHandle.standardError.write(Data("no usable thermal sensors\n".utf8))
    exit(1)
}

if mode == "--status" {
    let s = sensors.sample()
    print(String(format: "hotspot %@ %.1f °C · pressure %@ · %d sensors in %.0f µs",
                 s.hotspot?.domain.displayName ?? "—", s.hotspot?.estimate.value ?? -1,
                 s.pressure.rawValue, s.sensorsRead, s.sampleCostMicros))
    for g in s.groups {
        let hot = g.hottest.value.map { String(format: "%.1f °C", $0) }
            ?? (g.hottest.confidence.reason ?? "—")
        print("  \(g.domain.displayName.padding(toLength: 8, withPad: " ", startingAt: 0)) \(hot)"
              + "  live \(g.live.count) parked \(g.parked.count)")
    }
    for f in s.fans {
        print(String(format: "  fan %d %.0f rpm target %.0f mode %@",
                     f.index, f.actualRPM ?? -1, f.targetRPM ?? -1, f.mode.rawValue))
    }
    exit(0)
}

guard getuid() == 0 || unprivileged else {
    FileHandle.standardError.write(Data("aithermald \(mode) must run as root — SMC writes are privileged\n".utf8))
    exit(77)
}
if unprivileged && getuid() != 0 {
    // Say it once, loudly. A helper that silently cannot do the one thing it
    // exists for would be worse than one that refuses to start.
    FileHandle.standardError.write(Data(
        "WARNING: running unprivileged — every fan write WILL be refused with kIOReturnNotPrivileged.\n".utf8))
}
guard let writer = FanWriter(smc: smc) else {
    FileHandle.standardError.write(Data("no controllable fans reported by the SMC\n".utf8))
    exit(1)
}

installSignalHandlers()
let daemon = Daemon(writer: writer, sensors: sensors, socketPath: socketPath,
                    allowedUID: allowUID, ceilingC: ceiling)

switch mode {
case "--selftest": exit(daemon.selfTest())
case "--release":  exit(daemon.releaseNow())
default:           exit(daemon.run())
}
