import Foundation

/// Talks to `aithermald` over its unix socket.
///
/// Deliberately synchronous and short-timeout: it is called from the thermal
/// collector's own task at 1 Hz, and a helper that has wedged must look like a
/// dead source within one tick rather than stalling the collector behind it.
public final class CoolingClient: @unchecked Sendable {

    public enum Err: Error, Equatable {
        case notInstalled
        case connect(String)
        case io(String)
        case protocolMismatch(Int)
        case refused(String)
    }

    private let path: String
    private let timeout: Double

    public init(path: String = Cooling.socketPath, timeout: Double = 1.0) {
        self.path = path
        self.timeout = timeout
    }

    /// Whether a helper is even installed. Cheap: a stat, not a connect.
    /// The absence of a socket is `absent`, not an error — read-only is this
    /// app's normal state.
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: path) }

    public func status() throws -> CoolingStatus {
        try send(CoolingRequest(op: .status))
    }

    public func setTargets(_ targets: [Int: Double], leaseSeconds: Double) throws -> CoolingStatus {
        try send(CoolingRequest(op: .set, targets: targets, leaseSeconds: leaseSeconds))
    }

    public func releaseToAuto() throws -> CoolingStatus {
        try send(CoolingRequest(op: .auto))
    }

    private func send(_ req: CoolingRequest) throws -> CoolingStatus {
        guard isInstalled else { throw Err.notInstalled }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Err.connect(String(cString: strerror(errno))) }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw Err.connect("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() { raw[i] = b }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard rc == 0 else { throw Err.connect(String(cString: strerror(errno))) }

        var line = try JSONEncoder().encode(req)
        line.append(0x0A)
        try line.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
                if n <= 0 { throw Err.io(String(cString: strerror(errno))) }
                off += n
            }
        }

        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !data.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { throw Err.io(String(cString: strerror(errno))) }
            if n == 0 { break }
            data.append(contentsOf: chunk[0..<n])
            if data.count > 1 << 20 { throw Err.io("response too large") }
        }
        guard let nl = data.firstIndex(of: 0x0A) else { throw Err.io("helper closed without replying") }
        let resp = try JSONDecoder().decode(CoolingResponse.self, from: data[..<nl])
        guard resp.ok, let s = resp.status else {
            throw Err.refused(resp.error ?? "helper refused the request")
        }
        guard s.version == Cooling.protocolVersion else {
            throw Err.protocolMismatch(s.version)
        }
        return s
    }
}

/// Holds the user's policy and keeps the lease alive.
///
/// The renewal loop is the reason this exists at all: the helper releases
/// everything if it is not spoken to, so "set it and forget it" is not an
/// available design. That is on purpose — the failure mode of this feature is a
/// fan stuck at the wrong speed, and a lease makes silence safe.
///
/// A lock rather than an actor, because every call it makes is a BLOCKING
/// socket round trip and it is driven from `ThermalProbe`'s own thread. Putting
/// blocking I/O behind an actor would have parked it on the cooperative pool.
public final class CoolingController: @unchecked Sendable {

    /// Renew at a third of the lease, so two lost ticks are survivable.
    public static let leaseSeconds: Double = 15
    private static let renewInterval: Double = 5

    private let client: CoolingClient
    private let lock = NSLock()
    private var policy: CoolingPolicy = .system
    private var lastSentRPM: Double?
    private var lastSentAt: Instant?
    private var lastStatus: CoolingStatus?
    private var lastError: String?
    private var lastGeneratingAt: Instant?
    private var pendingRelease = false
    /// After a refusal — a safety trip is the expected cause — stop asking for
    /// 5 s. Retrying at 1 Hz against a helper that is deliberately refusing is
    /// noise, and each attempt costs it a lock and a log line.
    private var retryNotBefore: Instant?

    public init(client: CoolingClient = CoolingClient()) { self.client = client }

    public func setPolicy(_ p: CoolingPolicy) {
        lock.lock()
        guard p != policy else { lock.unlock(); return }
        policy = p
        // A policy change takes effect on this tick, not at the next renewal.
        lastSentRPM = nil
        lastSentAt = nil
        // Releasing does socket I/O, so it is handed to the probe thread rather
        // than done here — this is called from the UI.
        if p == .system { pendingRelease = true }
        lock.unlock()
    }

    public var currentPolicy: CoolingPolicy { lock.withLock { policy } }
    public var status: CoolingStatus? { lock.withLock { lastStatus } }
    public var error: String? { lock.withLock { lastError } }
    public var isInstalled: Bool { client.isInstalled }

    /// Called once per thermal tick, on the probe's own thread.
    @discardableResult
    public func tick(hotspotC: Double?, generating: Bool, at t: Instant) -> CoolingStatus? {
        lock.lock()
        if generating { lastGeneratingAt = t }
        let p = policy
        let releasing = pendingRelease
        pendingRelease = false
        let want = releasing ? nil : p.desiredRPM(CoolingInput(hotspotC: hotspotC,
                                                              generating: generating,
                                                              lastGeneratingAt: lastGeneratingAt,
                                                              now: t))
        let sentRPM = lastSentRPM
        let sentAt = lastSentAt
        let knownFans = lastStatus?.limits.keys.sorted()
        let heldOff = retryNotBefore.map { t < $0 } ?? false
        lock.unlock()

        guard client.isInstalled else {
            lock.withLock { lastStatus = nil; lastError = nil }
            return nil
        }

        var newStatus: CoolingStatus?
        var newError: String?
        var newSentRPM: Double? = sentRPM
        var newSentAt: Instant? = sentAt
        var didSend = false
        do {
            if let want, !heldOff {
                // Re-send when the target moves by more than a rounding error,
                // or when the lease needs renewing. Chatter costs the helper an
                // SMC write, the one operation here with any risk attached.
                let moved = sentRPM.map { abs($0 - want) > 50 } ?? true
                let due = sentAt.map { t - $0 >= Self.renewInterval } ?? true
                if moved || due {
                    let fans = knownFans ?? [0, 1]
                    let targets = Dictionary(uniqueKeysWithValues: fans.map { ($0, want) })
                    newStatus = try client.setTargets(targets, leaseSeconds: Self.leaseSeconds)
                    newSentRPM = want
                    newSentAt = t
                    didSend = true
                } else {
                    newStatus = try client.status()
                }
            } else if want == nil {
                let s = try client.status()
                newStatus = s.forcing ? try client.releaseToAuto() : s
                newSentRPM = nil
            } else {
                // Backing off. Still read status, so a cleared trip is noticed.
                newStatus = try client.status()
            }
        } catch {
            newError = Self.describe(error)
            lock.lock(); retryNotBefore = Instant(t.s + 5); lock.unlock()
            didSend = false
            // A helper we cannot reach releases on its own when the lease
            // lapses, so there is nothing to undo here — and pretending we
            // still had control would be worse than reporting the break.
            newSentRPM = nil
        }

        lock.lock()
        // Cleared only by a command that actually landed. Clearing it on a mere
        // status read would defeat the backoff, since a refusing helper still
        // answers status perfectly happily.
        if didSend { retryNotBefore = nil }
        lastStatus = newStatus
        lastError = newError
        lastSentRPM = newSentRPM
        lastSentAt = newSentAt
        lock.unlock()
        return newStatus
    }

    /// Called when the app is going away. Best-effort: the lease is what makes
    /// this optional rather than load-bearing.
    public func shutdown() {
        guard client.isInstalled else { return }
        _ = try? client.releaseToAuto()
    }

    public static func describe(_ e: Error) -> String {
        switch e as? CoolingClient.Err {
        case .notInstalled?:            return "helper not installed"
        case .connect(let m)?:          return "cannot reach helper: \(m)"
        case .io(let m)?:               return "helper I/O: \(m)"
        case .protocolMismatch(let v)?: return "helper speaks protocol \(v), app speaks \(Cooling.protocolVersion)"
        case .refused(let m)?:          return m
        case nil:                       return (e as NSError).localizedDescription
        }
    }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
