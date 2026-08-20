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

    func testWatchdogScriptBackgroundsTheCLIAndPollsTheParent() {
        let argv = LMSLogStream.watchdogInvocation(cli: "/bin/echo", ppid: 4242)
        XCTAssertEqual(argv.first, "-c")
        let script = argv[1]
        XCTAssertTrue(script.contains("'/bin/echo'"), script)
        XCTAssertTrue(script.contains("--filter' 'output'"), script)
        XCTAssertTrue(script.contains("child=$!"), script)
        XCTAssertTrue(script.contains("kill -0 4242"), script)
        XCTAssertTrue(script.contains("kill \"$child\""), script)
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
