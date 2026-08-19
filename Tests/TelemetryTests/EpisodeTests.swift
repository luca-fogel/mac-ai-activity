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
