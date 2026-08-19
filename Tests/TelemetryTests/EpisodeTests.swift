import XCTest
@testable import Telemetry

/// Episodes are what make MLX comparable to llama.cpp at all: MLX exposes no
/// tokens, but duration, GPU shape and integrated energy are observable for
/// both backends.
final class EpisodeTests: XCTestCase {

    func testOpensAndClosesOnBusyEdges() {
        var t = EpisodeTracker()
        t.note(generating: false, backend: "MLX", model: "m", at: Instant(0))
        XCTAssertNil(t.current)
        t.note(generating: true, backend: "MLX", model: "m", at: Instant(1))
        XCTAssertNotNil(t.current)
        t.note(generating: true, backend: "MLX", model: "m", at: Instant(2))
        XCTAssertEqual(t.episodes.count, 1, "a run in progress must not start a second episode")
        t.note(generating: false, backend: "MLX", model: "m", at: Instant(6))
        XCTAssertNil(t.current)
        XCTAssertEqual(t.completed.first?.duration ?? 0, 5, accuracy: 0.001)
    }

    func testIntegratesEnergyTrapezoidally() {
        var t = EpisodeTracker()
        t.note(generating: true, backend: "llama.cpp", model: "m", at: Instant(0))
        // 10 W then 30 W, 4 s apart -> trapezoid = 20 W * 4 s = 80 J
        t.noteWatts(10, at: Instant(0))
        t.noteWatts(30, at: Instant(4))
        t.note(generating: false, backend: "llama.cpp", model: "m", at: Instant(4))
        let e = t.completed.first!
        XCTAssertEqual(e.energyJoules, 80, accuracy: 0.01)
    }

    // A backend with no token telemetry must yield an em-dash, never a zero.
    func testMLXEpisodeReportsNoTokensRatherThanZero() {
        var t = EpisodeTracker()
        t.note(generating: true, backend: "MLX", model: "qwen", at: Instant(0))
        t.noteWatts(20, at: Instant(0))
        t.noteWatts(20, at: Instant(5))
        t.note(generating: false, backend: "MLX", model: "qwen", at: Instant(5))
        let e = t.completed.first!
        XCTAssertNil(e.tokens)
        XCTAssertNil(e.joulesPerToken.value)
        XCTAssertEqual(e.joulesPerToken.confidence.reason,
                       "this backend reports no token count")
        XCTAssertEqual(e.energy.value ?? 0, 100, accuracy: 0.01,
                       "energy IS observable for MLX even though tokens are not")
    }

    func testJoulesPerTokenWhenTokensAreKnown() {
        var t = EpisodeTracker()
        t.note(generating: true, backend: "llama.cpp", model: "m", at: Instant(0))
        t.noteWatts(50, at: Instant(0))
        t.noteWatts(50, at: Instant(10))          // 500 J
        t.noteTokens(100, prefillEnded: Instant(2))
        t.note(generating: false, backend: "llama.cpp", model: "m", at: Instant(10))
        let e = t.completed.first!
        XCTAssertEqual(e.tokens, 100)
        XCTAssertEqual(e.joulesPerToken.value!, 5.0, accuracy: 0.01)
        XCTAssertEqual(e.prefillSeconds!, 2.0, accuracy: 0.001)
    }

    func testGPUPeakAndMean() {
        var t = EpisodeTracker()
        t.note(generating: true, backend: "MLX", model: "m", at: Instant(0))
        for (i, g) in [0.2, 0.9, 0.7].enumerated() { t.noteGPU(g, at: Instant(Double(i))) }
        t.note(generating: false, backend: "MLX", model: "m", at: Instant(3))
        let e = t.completed.first!
        XCTAssertEqual(e.peakGPU, 0.9, accuracy: 0.001)
        XCTAssertEqual(e.meanGPU, 0.6, accuracy: 0.001)
    }

    // Long stalls between power reads must not be integrated as if continuous.
    func testIgnoresImplausiblePowerGaps() {
        var t = EpisodeTracker()
        t.note(generating: true, backend: "MLX", model: "m", at: Instant(0))
        t.noteWatts(20, at: Instant(0))
        t.noteWatts(20, at: Instant(120))     // 2-minute gap: reject
        t.note(generating: false, backend: "MLX", model: "m", at: Instant(120))
        XCTAssertEqual(t.completed.first!.energyJoules, 0)
    }
}

/// mlx-lm has no /slots and no /metrics; its log is the telemetry channel.
final class MLXLogTailerTests: XCTestCase {

    func write(_ lines: [String]) -> String {
        let p = NSTemporaryDirectory() + "mlxtest-\(UUID().uuidString).log"
        FileManager.default.createFile(atPath: p, contents: Data())
        try? lines.joined(separator: "\n").appending("\n").write(toFile: p, atomically: false, encoding: .utf8)
        return p
    }

    func testParsesPrefillProgress() {
        let p = write([])
        let t = MLXLogTailer(path: p)
        try? "2026-08-19 16:31:11,359 - INFO - Prompt processing progress: 34/35\n"
            .write(toFile: p, atomically: false, encoding: .utf8)
        let s = t.poll(now: Instant(1))
        XCTAssertEqual(s.promptProcessed, 34)
        XCTAssertEqual(s.promptTotal, 35)
        XCTAssertTrue(s.prefilling, "34 of 35 means prefill is still running")
    }

    func testPrefillCompletesWhenProgressReachesTotal() {
        let p = write([])
        let t = MLXLogTailer(path: p)
        try? "INFO - Prompt processing progress: 35/35\n"
            .write(toFile: p, atomically: false, encoding: .utf8)
        XCTAssertFalse(t.poll(now: Instant(1)).prefilling)
    }

    func testParsesUsageFromTheLoggedResponseBody() {
        let p = write([])
        let t = MLXLogTailer(path: p)
        try? "\t\t\"completion_tokens\": 80,\n\t\t\t\"cached_tokens\": 12\n"
            .write(toFile: p, atomically: false, encoding: .utf8)
        let s = t.poll(now: Instant(1))
        XCTAssertEqual(s.completionTokens, 80)
        XCTAssertEqual(s.cachedTokens, 12)
        XCTAssertEqual(s.requestsSeen, 1)
    }

    func testParsesPromptCacheLine() {
        let p = write([])
        let t = MLXLogTailer(path: p)
        try? "INFO - Prompt Cache: 3 sequences, 1.25 GB\n"
            .write(toFile: p, atomically: false, encoding: .utf8)
        let s = t.poll(now: Instant(1))
        XCTAssertEqual(s.cacheSequences, 3)
        XCTAssertEqual(s.cacheGB ?? 0, 1.25, accuracy: 0.001)
    }

    // A truncated final line must not be parsed until it is complete.
    func testHoldsPartialLines() {
        let p = write([])
        let t = MLXLogTailer(path: p)
        try? "INFO - Prompt processing progr".write(toFile: p, atomically: false, encoding: .utf8)
        XCTAssertNil(t.poll(now: Instant(1)).promptProcessed)
        try? "INFO - Prompt processing progress: 7/9\n".write(toFile: p, atomically: false, encoding: .utf8)
        // The file was rewritten smaller then larger; the tailer must recover.
        _ = t.poll(now: Instant(2))
    }

    func testMissingLogIsReportedNotFabricated() {
        let t = MLXLogTailer(path: "/nonexistent/mlx.log")
        XCTAssertFalse(t.exists)
        let s = t.poll(now: Instant(1))
        XCTAssertNil(s.completionTokens)
        XCTAssertNil(s.promptTotal)
    }
}
