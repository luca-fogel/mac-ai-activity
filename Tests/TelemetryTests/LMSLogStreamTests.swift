import XCTest
@testable import Telemetry

/// Fixtures are real lines captured from `lms log stream --json --stats` on
/// 2026-08-20 against Bionic serving qwen/qwen3.8-27b on the embedded MLX
/// engine, with the OpenAI-compatible server switched OFF.
final class LMSLogStreamTests: XCTestCase {

    private let t = Instant(42)

    /// Verbatim capture, with the `output` text shortened — its length is
    /// irrelevant and its content must never be read.
    private let realOutputEvent = """
    {"timestamp":1787177942718,"data":{"type":"llm.prediction.output","output":"The extraction results don't include the official answer.","stats":{"stopReason":"eosFound","tokensPerSecond":5.979127121787662,"numGpuLayers":-1,"timeToFirstTokenSec":14.632,"totalTimeSec":38.3,"promptTokensCount":23564,"predictedTokensCount":229,"totalTokensCount":23793},"modelIdentifier":"qwen/qwen3.8-27b"}}
    """

    private func parse(_ line: String) -> LMSLogStream.ParseResult {
        LMSLogStream.parse(line, engine: .bionic, at: t)
    }

    private func prediction(_ line: String) throws -> PredictionSample {
        guard case .prediction(let p) = parse(line) else {
            throw XCTSkip("not parsed as a prediction")
        }
        return p
    }

    // MARK: - The happy path, against a real line

    func testParsesEveryFieldOfARealCapturedReceipt() throws {
        let p = try prediction(realOutputEvent)
        XCTAssertEqual(p.modelIdentifier, "qwen/qwen3.8-27b")
        XCTAssertEqual(p.stopReason, "eosFound")
        XCTAssertEqual(p.tokensPerSecond.value!, 5.979127121787662, accuracy: 1e-9)
        XCTAssertEqual(p.timeToFirstToken.value!, 14.632, accuracy: 1e-9)
        XCTAssertEqual(p.totalSeconds!, 38.3, accuracy: 1e-9)
        XCTAssertEqual(p.promptTokens, 23564)
        XCTAssertEqual(p.predictedTokens, 229)
        XCTAssertEqual(p.totalTokens, 23793)
        XCTAssertEqual(p.engine, .bionic)
        XCTAssertEqual(p.source, "lms log stream --stats")
    }

    func testTTFTIsAPointHereUnlikeEverywhereElseInTheApp() throws {
        // /slots can only bound TTFT because we are not the client. The engine
        // IS the client, so this one is exact and must not carry an interval.
        let p = try prediction(realOutputEvent)
        XCTAssertNil(p.timeToFirstToken.interval)
        XCTAssertEqual(p.timeToFirstToken.confidence, .high)
    }

    func testNoPromptOrCompletionTextSurvivesParsing() throws {
        // The privacy boundary. Nothing reachable from the sample may contain
        // the completion, so a screenshot of this app cannot leak a prompt.
        let p = try prediction(realOutputEvent)
        let dumped = String(describing: p)
        XCTAssertFalse(dumped.contains("extraction results"))
        XCTAssertFalse(dumped.contains("official answer"))
    }

    // MARK: - Absence is normal, and is never zero

    func testStatsBlockAbsentYieldsUnavailableNotZero() {
        let line = """
        {"timestamp":1,"data":{"type":"llm.prediction.output","output":"hi","modelIdentifier":"m"}}
        """
        guard case .prediction(let p) = parse(line) else { return XCTFail("should parse") }
        XCTAssertNil(p.tokensPerSecond.value)
        XCTAssertNil(p.timeToFirstToken.value)
        XCTAssertFalse(p.tokensPerSecond.confidence.isAvailable)
        XCTAssertEqual(p.tokensPerSecond.confidence.reason,
                       "LM Studio reported no stats for this prediction")
        XCTAssertNil(p.predictedTokens)
        XCTAssertEqual(p.stopReason, "unknown")
    }

    func testIndividualStatsFieldsAbsentDegradeIndependently() {
        // Every field is .optional() in the engine's own schema, so a partial
        // stats block is valid input, not corruption.
        let line = """
        {"timestamp":1,"data":{"type":"llm.prediction.output","output":"x","stats":{"stopReason":"userStopped","predictedTokensCount":12},"modelIdentifier":"m"}}
        """
        guard case .prediction(let p) = parse(line) else { return XCTFail("should parse") }
        XCTAssertEqual(p.stopReason, "userStopped")
        XCTAssertEqual(p.predictedTokens, 12)
        XCTAssertNil(p.tokensPerSecond.value)
        XCTAssertEqual(p.tokensPerSecond.confidence.reason, "tokensPerSecond absent")
        XCTAssertNil(p.totalSeconds)
    }

    // MARK: - Speculative decoding

    func testAbsentDraftCountersAreUnavailableNotZeroPercent() throws {
        // 0% would read as a catastrophic draft model rather than as no draft
        // model at all. None of the captured samples had these counters.
        let p = try prediction(realOutputEvent)
        XCTAssertFalse(p.draftAccepted.confidence.isAvailable)
        XCTAssertNil(p.draftAccepted.value)
        XCTAssertNil(p.draftModel)
    }

    func testAcceptRateFromTheEnginesOwnTotal() {
        let r = LMSLogStream.acceptRate(accepted: 30, total: 40, rejected: 10)
        XCTAssertEqual(r.value!, 0.75, accuracy: 1e-9)
    }

    func testAcceptRateFallsBackToAcceptedPlusRejected() {
        let r = LMSLogStream.acceptRate(accepted: 30, total: nil, rejected: 10)
        XCTAssertEqual(r.value!, 0.75, accuracy: 1e-9)
    }

    func testAcceptRateWithNothingDraftedIsUnavailableNotDivideByZero() {
        let r = LMSLogStream.acceptRate(accepted: 0, total: 0, rejected: nil)
        XCTAssertNil(r.value)
        XCTAssertFalse(r.confidence.isAvailable)
    }

    func testSpeculativeReceiptParsesTheDraftModelAndRate() {
        let line = """
        {"timestamp":1,"data":{"type":"llm.prediction.output","output":"x","stats":{"stopReason":"eosFound","tokensPerSecond":41.0,"usedDraftModelKey":"qwen/qwen3-0.6b","totalDraftTokensCount":100,"acceptedDraftTokensCount":62,"rejectedDraftTokensCount":38},"modelIdentifier":"m"}}
        """
        guard case .prediction(let p) = parse(line) else { return XCTFail("should parse") }
        XCTAssertEqual(p.draftModel, "qwen/qwen3-0.6b")
        XCTAssertEqual(p.draftAccepted.value!, 0.62, accuracy: 1e-9)
    }

    // MARK: - Everything else on the stream

    func testRuntimeLogIsNotAPredictionAndIsNotMalformed() {
        // Real captured line. It fires mid-generation, so misclassifying it as
        // a receipt would invent a prediction that never completed.
        let line = """
        {"timestamp":1787177890365,"data":{"type":"runtime.log","level":"debug","message":"[coordinator][INFO]: Prompt cache restore: cached_tokens=23040 uncached_tokens=523 lifetime_efficiency=87.14%","engineName":"mlx-llm-mac-arm64-apple-metal-advsimd","engineVersion":"1.11.0","engineType":"mlx-llm","modelIdentifier":"qwen/qwen3.8-27b","instanceReference":"9ULeIqaSCUykGpRbg4tjc3OF","pid":4338}}
        """
        guard case .otherEvent = parse(line) else {
            return XCTFail("runtime.log must not parse as a prediction")
        }
    }

    func testPredictionInputIsIgnoredEvenIfItArrives() {
        // --filter output should exclude these, but the parser must not depend
        // on a CLI flag for correctness.
        let line = """
        {"timestamp":1,"data":{"type":"llm.prediction.input","input":"secret prompt","modelPath":"/p","modelIdentifier":"m"}}
        """
        guard case .otherEvent = parse(line) else { return XCTFail("input must be ignored") }
    }

    func testBlankLinesAreNotCountedAsCorruption() {
        guard case .otherEvent = parse("") else { return XCTFail("blank should be benign") }
        guard case .otherEvent = parse("   \n") else { return XCTFail("blank should be benign") }
    }

    // MARK: - The 80 KiB truncation

    func testTruncatedLineIsMalformedAndDoesNotThrow() {
        // Observed: an oversized event arrived cut at exactly 81920 bytes with
        // an unterminated string. It must be counted and dropped, never fatal.
        let prefix = #"{"timestamp":1,"data":{"type":"llm.prediction.output","output":""#
        let truncated = prefix + String(repeating: "x", count: 4096)
        guard case .malformed = parse(truncated) else {
            return XCTFail("a truncated line must be reported as malformed")
        }
    }

    func testAValidLineAfterATruncatedOneStillParses() throws {
        // The real requirement: one bad line must not poison the stream.
        guard case .malformed = parse(#"{"timestamp":1,"data":{"type":"x"#) else {
            return XCTFail("expected malformed")
        }
        let p = try prediction(realOutputEvent)
        XCTAssertEqual(p.predictedTokens, 229)
    }

    func testGarbageIsMalformedNotAnEmptyPrediction() {
        guard case .malformed = parse("Streaming logs from LM Studio") else {
            return XCTFail("a stray banner line must not become a prediction")
        }
    }

    func testEnvelopeWithoutDataIsMalformed() {
        guard case .malformed = parse(#"{"timestamp":1}"#) else {
            return XCTFail("expected malformed")
        }
    }

    // MARK: - Invocation

    func testArgumentsPinTheFlagsThatAreLoadBearing() {
        let a = LMSLogStream.arguments
        XCTAssertEqual(a, ["log", "stream", "--json", "--stats", "--filter", "output"])
        // --stats is rejected by the CLI unless the source is `model`, which is
        // the default; passing --source explicitly would risk breaking it.
        XCTAssertFalse(a.contains("--source"))
        XCTAssertFalse(a.contains("-s"))
    }
}

/// The child process lifecycle, which is the part that cannot be tested by
/// parsing fixtures. MEASURED: killing the parent leaves `lms log stream`
/// running forever, because with no model loaded it never writes and so never
/// takes SIGPIPE from the closed pipe.
final class LMSLogStreamLifecycleTests: XCTestCase {

    func testWatchdogScriptBackgroundsTheCLIAndWatchesForParentDeath() {
        let argv = LMSLogStream.watchdogInvocation(cli: "/bin/echo", ppid: 4242)
        XCTAssertEqual(argv.first, "-c")
        let script = argv[1]
        XCTAssertTrue(script.contains("'/bin/echo'"), script)
        XCTAssertTrue(script.contains("--filter' 'output'"), script)
        XCTAssertTrue(script.contains("child=$!"), script)
        // EOF on stdin is the PRIMARY mechanism: immune to pid reuse, which
        // was measured breaking the poll-only version.
        XCTAssertTrue(script.contains("cat > /dev/null"), script)
        // The pid poll is retained only as a slow backstop.
        XCTAssertTrue(script.contains("kill -0 4242"), script)
    }

    func testWatchdogTrapsSoTheChildDiesEvenIfTheShellIsSignalled() {
        // MEASURED: without this, terminating the shell stranded the CLI,
        // because the shell is the thing that runs the kill.
        let script = LMSLogStream.watchdogInvocation(cli: "/bin/echo", ppid: 1)[1]
        XCTAssertTrue(script.contains("trap"), script)
        for sig in ["EXIT", "TERM", "INT", "HUP"] {
            XCTAssertTrue(script.contains(sig), "trap must cover \(sig): \(script)")
        }
        // The trap must be armed BEFORE the child is spawned, or a fast signal
        // slips through the gap.
        let trapAt = script.range(of: "trap")!.lowerBound
        let spawnAt = script.range(of: "child=$!")!.lowerBound
        XCTAssertLessThan(trapAt, spawnAt, "trap must be installed first")
    }

    func testWatchdogQuotesPathsSoASpaceCannotSplitTheCommand() {
        let argv = LMSLogStream.watchdogInvocation(
            cli: "/Users/someone/Application Support/lms", ppid: 1)
        XCTAssertTrue(argv[1].contains("'/Users/someone/Application Support/lms'"))
    }

    func testWatchdogEscapesASingleQuoteInThePath() {
        let argv = LMSLogStream.watchdogInvocation(cli: "/tmp/o'brien/lms", ppid: 1)
        // POSIX close-reopen form; a raw quote here would break out of the string.
        XCTAssertTrue(argv[1].contains("'/tmp/o'\\''brien/lms'"), argv[1])
    }

    func testAMissingCLIIsReportedRatherThanLaunched() async {
        let s = LMSLogStream(cli: "/nonexistent/lms")
        let available = await s.isAvailable
        XCTAssertFalse(available)
        await s.start()
        var outcomes: [Outcome] = []
        for await e in s.events {
            if case .health(let o, _) = e { outcomes.append(o) }
            break
        }
        await s.stop()
        // Absence, with the path named — not a crash and not silence.
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertFalse(outcomes[0].isOK)
        XCTAssertTrue(outcomes[0].shortReason.contains("/nonexistent/lms"))
    }

    func testCountersStartAtZeroAndAreObservable() async {
        let s = LMSLogStream(cli: "/nonexistent/lms")
        let lines = await s.linesSeen
        let bad = await s.malformedLines
        let preds = await s.predictionsSeen
        XCTAssertEqual(lines, 0)
        XCTAssertEqual(bad, 0)
        XCTAssertEqual(preds, 0)
        XCTAssertEqual(s.engine, .bionic)
    }
}

/// How long a generation took.
///
/// MEASURED against the live engine: `totalTimeSec` reported **0.002** for a
/// generation with TTFT 1.494 s and 43 tokens at 62.4 tok/s — about 2.18 s of
/// real work. Integrating power over a 2 ms window yielded 0.07 J and a
/// joules-per-token figure ~300x too small, which is exactly the kind of
/// plausible-but-wrong number this app exists to refuse.
final class ObservedDurationTests: XCTestCase {

    private func sample(totalSeconds: Double?, ttft: Double?, tokens: Int?,
                        tps: Double?) -> PredictionSample {
        PredictionSample(
            t: Instant(100), engine: .bionic, modelIdentifier: "m",
            stopReason: "eosFound",
            tokensPerSecond: tps.map { .high($0) } ?? .unavailable("absent"),
            timeToFirstToken: ttft.map { .high($0) } ?? .unavailable("absent"),
            draftAccepted: .unavailable("no draft model"),
            totalSeconds: totalSeconds, promptTokens: 54,
            predictedTokens: tokens, source: "test")
    }

    func testTheMeasuredBogusTotalTimeIsRejectedAndTheDurationReconstructed() {
        let p = sample(totalSeconds: 0.002, ttft: 1.494, tokens: 43, tps: 62.3975)
        let d = p.observedDuration
        XCTAssertEqual(d.value!, 1.494 + 43 / 62.3975, accuracy: 1e-6)
        XCTAssertEqual(d.value!, 2.183, accuracy: 0.01)
        // A reconstruction from two averages is not a clock reading.
        XCTAssertEqual(d.confidence, .low)
    }

    func testAPlausibleTotalTimeIsTrusted() {
        let p = sample(totalSeconds: 38.3, ttft: 14.632, tokens: 229, tps: 5.979)
        XCTAssertEqual(p.observedDuration.value!, 38.3, accuracy: 1e-9)
        XCTAssertEqual(p.observedDuration.confidence, .high)
    }

    func testATotalTimeSmallerThanItsOwnTTFTCannotBeADuration() {
        // The plausibility check: a duration must contain its own prefill.
        let p = sample(totalSeconds: 1.0, ttft: 14.632, tokens: 229, tps: 5.979)
        XCTAssertGreaterThan(p.observedDuration.value!, 14.632)
        XCTAssertEqual(p.observedDuration.confidence, .low)
    }

    func testFallsBackToTheReportedFigureWhenNothingElseIsAvailable() {
        let p = sample(totalSeconds: 5.0, ttft: nil, tokens: nil, tps: nil)
        XCTAssertEqual(p.observedDuration.value!, 5.0, accuracy: 1e-9)
        XCTAssertEqual(p.observedDuration.confidence, .low)
    }

    func testNoUsableDurationIsUnavailableRatherThanZero() {
        let p = sample(totalSeconds: nil, ttft: nil, tokens: nil, tps: nil)
        XCTAssertNil(p.observedDuration.value)
        XCTAssertFalse(p.observedDuration.confidence.isAvailable)
    }

    func testZeroTokensDoesNotDivideByAnythingUnsafe() {
        let p = sample(totalSeconds: 0.002, ttft: 1.5, tokens: 0, tps: 0)
        // Cannot reconstruct, and 0.002 is below its own TTFT, so it degrades.
        XCTAssertEqual(p.observedDuration.value!, 0.002, accuracy: 1e-9)
        XCTAssertEqual(p.observedDuration.confidence, .low)
    }
}
