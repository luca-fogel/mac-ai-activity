import XCTest
@testable import Telemetry

/// The status vocabulary is undocumented and was read too narrowly.
///
/// MEASURED against the live engine: a 4063-token prompt spent 53.1 s in
/// `processingPrompt` before one token was decoded, against ~12 s of decoding.
/// Matching only "generating" reported the engine as idle for most of the work,
/// and the UI then attributed the GPU load to nothing.
final class LMStudioProbeStatusTests: XCTestCase {

    private func entry(_ status: String?, format: String = "safetensors") -> LMStudioProbe.Entry {
        LMStudioProbe.Entry(identifier: "qwen/qwen3.8-27b", sizeBytes: 16_081_678_492,
                            contextLength: 208_384, architecture: "qwen3_5",
                            format: format, status: status)
    }

    func testPrefillCountsAsBusy() {
        // The case that was being missed, and it is the majority of the work.
        XCTAssertTrue(entry("processingPrompt").isBusy)
        XCTAssertTrue(entry("PROCESSINGPROMPT").isBusy)
        XCTAssertTrue(entry("prompt_processing").isBusy)
    }

    func testDecodingCountsAsBusy() {
        XCTAssertTrue(entry("generating").isBusy)
        XCTAssertTrue(entry("GENERATING").isBusy)
    }

    func testIdleStatesAreNotBusy() {
        XCTAssertFalse(entry("idle").isBusy)
        XCTAssertFalse(entry("IDLE").isBusy)
        XCTAssertFalse(entry("loaded").isBusy)
        XCTAssertFalse(entry("unloaded").isBusy)
    }

    func testMissingStatusIsNotBusyRatherThanAssumedBusy() {
        XCTAssertFalse(entry(nil).isBusy)
        XCTAssertFalse(entry("").isBusy)
    }

    func testAnUnknownNonIdleStatusIsTreatedAsWork() {
        // Deliberate: under-reporting busy hides real activity, while
        // over-reporting is caught downstream by the unattributed-activity check.
        XCTAssertTrue(entry("someFutureWorkingState").isBusy)
    }

    func testPhaseIsDistinguishableNotJustBusyOrNot() {
        // Prefill and decode are two visually distinct regimes and the app draws
        // them as such, so the probe must be able to tell them apart.
        XCTAssertTrue(entry("processingPrompt").isPrefilling)
        XCTAssertFalse(entry("processingPrompt").isDecoding)
        XCTAssertTrue(entry("generating").isDecoding)
        XCTAssertFalse(entry("generating").isPrefilling)
    }

    func testMLXIsIdentifiedByFormatNotByName() {
        XCTAssertTrue(entry("idle", format: "safetensors").isMLX)
        XCTAssertTrue(entry("idle", format: "SAFETENSORS").isMLX)
        XCTAssertFalse(entry("idle", format: "gguf").isMLX)
        XCTAssertFalse(LMStudioProbe.Entry(identifier: "m", sizeBytes: 0, contextLength: nil,
                                           architecture: nil, format: nil, status: "idle").isMLX)
    }

    func testTheLegacySpellingNowAnswersWhatCallersMeant() {
        XCTAssertTrue(entry("processingPrompt").isGenerating)
        XCTAssertFalse(entry("idle").isGenerating)
    }

    func testAMissingCLIYieldsNoEntriesRatherThanFailing() {
        // The probe is best-effort by design; a machine without LM Studio must
        // simply produce nothing.
        XCTAssertTrue(LMStudioProbe.snapshot(cli: "/nonexistent/lms", timeout: 1).isEmpty)
    }
}

/// Which log the mlx-lm tailer picks.
///
/// VERIFIED on this machine: the canonical `tools/mlx-serve.sh` path existed but
/// was stale, while the LaunchAgent's stderr next to it was newer. Preferring
/// the canonical path unconditionally would tail the dead file.
final class MLXLogPathTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mlxlog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCandidateOrderPutsTheCanonicalPathFirst() {
        let c = MLXLogTailer.candidatePaths
        XCTAssertEqual(c.first, MLXLogTailer.defaultPath)
        XCTAssertTrue(c.contains { $0.hasSuffix("ai-server/mlx-model.err") })
        XCTAssertFalse(c.contains { $0.contains("Library/Logs/Bionic") },
                       "the Electron log carries no engine telemetry and must not be a candidate")
    }

    func testNoCandidatePresentReportsAbsenceRatherThanAPath() {
        // Not a fault: the channel simply does not exist until the server is
        // started with its output redirected.
        XCTAssertNil(MLXLogTailer(path: dir.appendingPathComponent("nope.log").path)
                        .exists ? "" : nil)
    }

    func testMissingLogLeavesStateUntouchedAndFabricatesNothing() {
        let t = MLXLogTailer(path: dir.appendingPathComponent("absent.log").path)
        XCTAssertFalse(t.exists)
        let st = t.poll(now: Instant(1))
        XCTAssertNil(st.promptTotal)
        XCTAssertNil(st.completionTokens)
        XCTAssertEqual(st.requestsSeen, 0)
        XCTAssertFalse(st.prefilling)
    }

    func testTheTailerReportsWhichFileItIsReading() throws {
        // So the UI can name it instead of saying "no telemetry".
        let p = dir.appendingPathComponent("server.log").path
        try "".write(toFile: p, atomically: true, encoding: .utf8)
        XCTAssertEqual(MLXLogTailer(path: p).path, p)
    }
}
