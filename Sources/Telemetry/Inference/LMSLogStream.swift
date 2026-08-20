import Foundation

/// Per-prediction telemetry for LM Studio / Bionic, including its **embedded
/// MLX** engine — the one backend nothing else in this app can instrument.
///
/// `LMStudioProbe` documents why MLX is invisible to process discovery: no
/// listening socket, Bionic's internal IPC instead of HTTP, no /slots and no
/// port to find. That is still true. What has changed is that
/// `lms log stream --json --stats` exposes the app's own diagnostics channel,
/// and that channel reports finished predictions for **every** client of the
/// instance — GUI, SDK, CLI and the OpenAI-compatible server alike. Verified
/// with that server switched OFF: GUI-driven generations still arrive.
///
/// What it does NOT provide is anything per-token. Exactly one event lands at
/// the end of each prediction and nothing during decode, so this closes the
/// energy-per-token gap retrospectively and leaves the live decode rate exactly
/// as unknowable as it was. See `PredictionSample` for why that must not be
/// papered over.
///
/// Four things this design is deliberately careful about:
///
///   * **It is its own actor.** `LMStudioProbe.snapshot()` blocks on
///     `readDataToEndOfFile()` + `waitUntilExit()` *inside* the
///     `LiveTelemetryFeed` actor, stalling every other collector for ~240 ms
///     every 5 s. A long-lived child process must never be attached that way.
///   * **`--filter output` is load-bearing twice over.** It drops
///     `llm.prediction.input` events, which are simultaneously the privacy
///     exposure (the entire rendered prompt, ~25k tokens observed) and the only
///     observed source of malformed output: one such line arrived truncated at
///     exactly 81920 bytes with an unterminated string. Every `output` event
///     observed was under 2.2 KB and parsed cleanly.
///   * **stderr goes to /dev/null, never to stdout.** The banner and *all*
///     logger output are on stderr by construction in the CLI, so stdout is
///     pure NDJSON — but merging the two would poison it.
///   * **The child must not outlive us.** MEASURED: killing the parent leaves
///     `lms log stream` running indefinitely. It never writes when no model is
///     loaded, so it never takes SIGPIPE from the closed pipe, and macOS has no
///     equivalent of Linux's `PR_SET_PDEATHSIG`. An orphan here is not merely
///     untidy: it holds a live subscription to every prompt on the machine.
///
///     The child therefore runs under a shell that dies when we do, and the
///     mechanism matters. Polling `kill -0 <our pid>` was the first attempt and
///     it FAILED in testing: macOS recycled the pid, some unrelated process
///     inherited it, and the watchdog polled a stranger forever while two
///     orphans kept streaming. So the shell instead blocks reading a pipe whose
///     write end only WE hold. When this process dies the descriptor closes,
///     the read returns EOF, and the child is killed — immediately, and immune
///     to pid reuse because no pid is consulted. The pid poll is kept only as a
///     slow backstop.
///   * **The upstream API is named `unstable_streamLogs`.** Every stats field
///     is optional in the engine's own schema, and `stats` itself is optional.
///     A shape change must degrade to `.unavailable`, never crash and never
///     invent a zero.
public actor LMSLogStream {

    public enum Event: Sendable {
        case prediction(PredictionSample)
        /// The stream's own health. `.ok` on a parsed receipt; a non-OK outcome
        /// when the child dies, so the UI can tell "LM Studio is not running"
        /// (absent — nothing has failed) from "the stream broke" (dark).
        case health(outcome: Outcome, t: Instant)
    }

    public nonisolated let events: AsyncStream<Event>
    private let cont: AsyncStream<Event>.Continuation

    public static let defaultCLI =
        ("~/.lmstudio/bin/lms" as NSString).expandingTildeInPath

    /// Arguments, in one place because each one is a decision.
    ///   log stream  — the diagnostics channel
    ///   --json      — NDJSON, one compact object per line
    ///   --stats     — the prediction stats block; requires --source model,
    ///                 which is the default and must not be overridden
    ///   --filter output — see the note above; not merely an optimisation
    public static let arguments = ["log", "stream", "--json", "--stats", "--filter", "output"]

    private let cli: String
    /// nonisolated so callers can key health samples on the same engine the
    /// stream reports under, without awaiting the actor.
    public nonisolated let engine: EngineID
    private var child: Process?
    /// Held open for the lifetime of the child; see runOnce().
    private var deathPipe: Pipe?
    private var pump: Task<Void, Never>?
    private var running = false

    /// Consecutive unexpected exits, for backoff. A child that cannot start
    /// stays unable to start; asking sixty times a minute learns nothing.
    private var failures = 0
    private(set) public var linesSeen = 0
    /// Lines that were not valid JSON. Published rather than swallowed: if the
    /// source is emitting broken output, that is itself a fact about the system
    /// under study — the same reasoning as `InferenceSample.malformedRepairs`.
    private(set) public var malformedLines = 0
    private(set) public var predictionsSeen = 0

    public init(cli: String = LMSLogStream.defaultCLI, engine: EngineID = .bionic) {
        self.cli = cli
        self.engine = engine
        var c: AsyncStream<Event>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { c = $0 }
        self.cont = c
    }

    public var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: cli) }

    public func start() {
        guard !running else { return }
        running = true
        pump = Task { [weak self] in await self?.supervise() }
    }

    public func stop() {
        running = false
        pump?.cancel()
        pump = nil
        terminateChild()
        cont.finish()
    }

    // MARK: - Supervision

    /// Restart on unexpected exit, with the same capped backoff shape the
    /// /slots poller uses. Distinguishes the two failure modes that must not
    /// look alike: LM Studio not being there at all, versus the stream dying
    /// while it is.
    private func supervise() async {
        while running && !Task.isCancelled {
            guard isAvailable else {
                // No CLI: not a fault, there is simply nothing to stream.
                cont.yield(.health(outcome: .other("lms CLI not installed at \(cli)"),
                                   t: Instant.now()))
                return
            }
            let status = await runOnce()
            guard running && !Task.isCancelled else { return }

            switch status {
            case .cleanExit:
                // The CLI exits 0 when told to stop. If we did not ask, LM
                // Studio went away underneath it.
                failures = 0
                cont.yield(.health(outcome: .other("lms log stream ended — LM Studio not running"),
                                   t: Instant.now()))
            case .failed(let code):
                failures += 1
                cont.yield(.health(outcome: .other("lms log stream exited \(code)"),
                                   t: Instant.now()))
            case .couldNotLaunch(let why):
                failures += 1
                cont.yield(.health(outcome: .other("could not launch lms: \(why)"),
                                   t: Instant.now()))
            }

            let backoff = min(30.0, pow(2.0, Double(min(failures, 5))))
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1e9))
        }
    }

    private enum ExitKind {
        case cleanExit
        case failed(Int32)
        case couldNotLaunch(String)
    }

    /// Wraps the CLI in a parent-death watchdog.
    ///
    /// `stop()` covers every orderly path, but a crash or SIGKILL would leave
    /// the stream running with nobody reading it — while it goes on receiving
    /// every prompt on the machine. The shell polls our pid and terminates the
    /// child once we stop existing. `exec` is deliberately NOT used for the
    /// inner command: the shell has to outlive it in order to do the watching.
    /// Builds the parent-death watchdog script.
    ///
    /// `cat > /dev/null` blocks on stdin, which is a pipe whose write end this
    /// process holds and never writes to. Our death closes it, the read returns
    /// EOF, and the kill fires. The trailing pid poll is a backstop for the case
    /// where stdin is somehow already closed; it is NOT the primary mechanism,
    /// because a recycled pid makes it unreliable.
    ///
    /// `exec` is deliberately not used for the inner command: the shell has to
    /// outlive it in order to do the watching.
    static func watchdogInvocation(cli: String, ppid: Int32) -> [String] {
        func shellQuote(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let command = ([cli] + arguments).map(shellQuote).joined(separator: " ")
        // The trap is what makes this correct under BOTH shutdown paths, and it
        // was added because the second one was measured failing: closing the
        // pipe works, but a caller that also signals the shell would otherwise
        // kill the very process responsible for reaping the CLI, stranding it.
        // With an EXIT/TERM/INT trap, the child dies no matter how the shell
        // goes away.
        let script = "child=''\n"
            + "trap 'kill \"$child\" 2>/dev/null' EXIT TERM INT HUP\n"
            + command + " &\n"
            + "child=$!\n"
            + "cat > /dev/null 2>&1\n"
            + "while kill -0 \(ppid) 2>/dev/null; do sleep 2; done\n"
        return ["-c", script]
    }

    private func runOnce() async -> ExitKind {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = Self.watchdogInvocation(
            cli: cli, ppid: ProcessInfo.processInfo.processIdentifier)
        let out = Pipe()
        p.standardOutput = out
        // Never 2>&1: the banner and every logger line are on stderr, and
        // merging them would put non-JSON into the NDJSON.
        p.standardError = FileHandle.nullDevice
        // The death signal. We hold the write end and never write to it, so the
        // watchdog's read blocks until this process exits. Retained as a stored
        // property on purpose: if the Pipe were deallocated the descriptor would
        // close and the watchdog would kill the child immediately.
        let death = Pipe()
        p.standardInput = death
        self.deathPipe = death

        do { try p.run() } catch {
            return .couldNotLaunch((error as NSError).localizedDescription)
        }
        child = p

        // AsyncLineSequence handles partial-line reassembly across reads, which
        // is the same problem MLXLogTailer solves by hand with `carry`.
        do {
            for try await line in out.fileHandleForReading.bytes.lines {
                guard running, !Task.isCancelled else { break }
                ingest(line)
            }
        } catch {
            // A read error is not fatal to the app; the supervisor decides.
        }

        p.waitUntilExit()
        let code = p.terminationStatus
        child = nil
        // Releasing this closes our write end. Harmless now — the child has
        // already exited — but it must not be released while it is running.
        deathPipe = nil
        return code == 0 ? .cleanExit : .failed(code)
    }

    private func terminateChild() {
        // Close our end of the death pipe FIRST and let the watchdog do the
        // work. Signalling the shell directly is worse than useless: the shell
        // is the thing that runs `kill "$child"`, so killing it strands the CLI
        // it was supposed to reap — MEASURED as one surviving orphan per ^C.
        // Closing the descriptor makes the shell's read return EOF, so it kills
        // the child and exits on its own.
        if let d = deathPipe {
            try? d.fileHandleForWriting.close()
            deathPipe = nil
        }
        guard let c = child, c.isRunning else { return }
        // SIGTERM is handled by the CLI: it unsubscribes, disposes its client
        // and exits 0. Verified. But `child` is the watchdog shell now, and
        // signalling only the shell would leave the CLI behind — so signal the
        // whole group, which Process makes the shell the leader of.
        // Then signal the actual CLI directly, by pid.
        //
        // MEASURED, three ways: closing the pipe did not reliably reach the
        // shell's read, polling our pid broke under pid reuse, and terminating
        // the shell stranded the very process it was meant to reap. None of
        // those are load-bearing any more — the grandchild's pid is read from
        // the process table and signalled directly, which needs nothing to
        // cooperate. `lms` handles SIGTERM by unsubscribing and exiting 0.
        let shell = c.processIdentifier
        if shell > 0 {
            for grandchild in ProcSampler.children(of: shell) {
                kill(grandchild, SIGTERM)
            }
        }
        // Now the shell, whose trap covers anything spawned since the scan.
        for _ in 0..<20 {
            if !c.isRunning { break }
            usleep(25_000)
        }
        if c.isRunning { c.terminate() }
        child = nil
    }

    // MARK: - Ingest

    private func ingest(_ line: String) {
        linesSeen += 1
        let t = Instant.now()
        switch Self.parse(line, engine: engine, at: t) {
        case .prediction(let s):
            predictionsSeen += 1
            cont.yield(.prediction(s))
            cont.yield(.health(outcome: .ok, t: t))
        case .otherEvent:
            // runtime.log / server.log lines. Not health: these are not
            // predictions, and counting them as arrivals would inflate the
            // measured rate of a source that only reports finished work.
            break
        case .malformed:
            malformedLines += 1
        }
    }

    // MARK: - Parsing (pure, so it can be tested against captured fixtures)

    enum ParseResult {
        case prediction(PredictionSample)
        case otherEvent
        case malformed
    }

    /// Parses one NDJSON line.
    ///
    /// Envelope: `{"timestamp": epoch_ms, "data": {"type": ..., ...}}`. Only
    /// `llm.prediction.output` carries stats. Every stats field is optional in
    /// the engine's schema and `stats` itself is optional, so absence is the
    /// normal case and maps to `.unavailable`, never to zero.
    static func parse(_ line: String, engine: EngineID, at t: Instant) -> ParseResult {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .otherEvent }
        guard let raw = trimmed.data(using: .utf8) else { return .malformed }

        // The one new source with a KNOWN malformed-output mode, so it gets the
        // repair pass that llama-server's bodies already get.
        let repaired = LenientJSON.repair(raw)
        guard let obj = try? JSONSerialization.jsonObject(with: repaired.data),
              let top = obj as? [String: Any],
              let data = top["data"] as? [String: Any],
              let type = data["type"] as? String
        else { return .malformed }

        guard type == "llm.prediction.output" else { return .otherEvent }

        // NOTE: `output` is deliberately never read. It holds the full
        // completion text and must not enter any Sample.
        let model = (data["modelIdentifier"] as? String) ?? "unknown"
        let stats = data["stats"] as? [String: Any]

        func dbl(_ k: String) -> Double? { (stats?[k] as? NSNumber)?.doubleValue }
        func int(_ k: String) -> Int? { (stats?[k] as? NSNumber)?.intValue }

        let noStats = "LM Studio reported no stats for this prediction"

        let tps: Estimate<Double> = dbl("tokensPerSecond").map { .high($0) }
            ?? .unavailable(stats == nil ? noStats : "tokensPerSecond absent")

        let ttft: Estimate<Double> = dbl("timeToFirstTokenSec").map { .high($0) }
            ?? .unavailable(stats == nil ? noStats : "timeToFirstTokenSec absent")

        return .prediction(PredictionSample(
            t: t,
            engine: engine,
            modelIdentifier: model,
            stopReason: (stats?["stopReason"] as? String) ?? "unknown",
            tokensPerSecond: tps,
            timeToFirstToken: ttft,
            draftAccepted: acceptRate(accepted: int("acceptedDraftTokensCount"),
                                      total: int("totalDraftTokensCount"),
                                      rejected: int("rejectedDraftTokensCount")),
            totalSeconds: dbl("totalTimeSec"),
            promptTokens: int("promptTokensCount"),
            predictedTokens: int("predictedTokensCount"),
            totalTokens: int("totalTokensCount"),
            draftModel: stats?["usedDraftModelKey"] as? String,
            source: "lms log stream --stats"))
    }

    /// accepted / drafted.
    ///
    /// The README lists speculative accept rate under "not measurable here",
    /// because /slots exposes the configuration only. These counters would
    /// measure it — but they are absent unless a draft model actually ran, and
    /// absent must not become 0%, which would read as a catastrophically bad
    /// draft model rather than as no draft model at all.
    static func acceptRate(accepted: Int?, total: Int?, rejected: Int?) -> Estimate<Double> {
        guard let a = accepted else {
            return .unavailable("no draft model in use — speculative counters absent")
        }
        // Prefer the engine's own total; fall back to accepted + rejected.
        let denominator = total ?? rejected.map { a + $0 }
        guard let d = denominator, d > 0 else {
            return .unavailable("no drafted tokens to accept")
        }
        return .high(Double(a) / Double(d))
    }
}
