import XCTest
@testable import Telemetry

/// Windowed integration is what makes a retrospective receipt useful: the
/// engine tells us how long a generation took, so the interval is known exactly
/// — afterwards. The GUI's episode tracker opened and closed on a 0.2 Hz busy
/// signal and therefore missed anything shorter than one poll.
final class PowerTraceTests: XCTestCase {

    private func at(_ s: Double) -> Instant { Instant(s) }

    private func trace(_ pairs: [(Double, Double)]) -> PowerTrace {
        var t = PowerTrace()
        for (time, w) in pairs { t.note(w, at: at(time)) }
        return t
    }

    // MARK: - The integral

    func testConstantDrawIntegratesToWattsTimesSeconds() {
        let t = trace([(0, 20), (5, 20), (10, 20)])
        XCTAssertEqual(t.energy(from: at(0), to: at(10)).value!, 200, accuracy: 1e-9)
    }

    func testRampIntegratesTrapezoidally() {
        // 10 W to 30 W over 10 s = mean 20 W = 200 J.
        let t = trace([(0, 10), (10, 30)])
        XCTAssertEqual(t.energy(from: at(0), to: at(10)).value!, 200, accuracy: 1e-9)
    }

    func testAWindowShorterThanTheSamplingIntervalStillIntegrates() {
        // THE case the episode tracker missed entirely: a 2.2 s generation
        // inside a 5 s sampling gap. Endpoints are interpolated, so the answer
        // is an approximation — but an approximation beats no envelope at all.
        let t = trace([(0, 20), (5, 40), (10, 20)])
        let e = t.energy(from: at(1), to: at(3.2))
        XCTAssertNotNil(e.value, "a sub-interval window must still yield energy")
        // w(t) = 20 + 4t across [0,5], so the exact integral over [1, 3.2] is
        // 20*2.2 + 2*(3.2^2 - 1^2) = 62.48 J. Linear interpolation makes the
        // single-panel trapezoid exact here, which is the point: the estimate
        // does not degrade just because the window is small.
        XCTAssertEqual(e.value!, 62.48, accuracy: 0.01)
    }

    func testSubIntervalWindowIsNeverHighConfidence() {
        // The source refreshes every ~4 s; the interior of the window was never
        // actually measured.
        let t = trace([(0, 20), (5, 40)])
        XCTAssertEqual(t.energy(from: at(1), to: at(2)).confidence, .low)
    }

    func testAWindowIsIntegratedFromItsOwnBoundsNotTheNearestSamples() {
        let t = trace([(0, 100), (10, 100), (20, 100)])
        XCTAssertEqual(t.energy(from: at(4), to: at(6)).value!, 200, accuracy: 1e-9)
    }

    // MARK: - Coverage is a precondition, not a detail

    func testAWindowStartingBeforeTheTraceIsUnavailableNotPartial() {
        // A partial integral presented as a whole one would understate energy
        // and therefore understate J/token — a plausible, wrong number.
        let t = trace([(10, 20), (20, 20)])
        let e = t.energy(from: at(0), to: at(20))
        XCTAssertNil(e.value)
        XCTAssertTrue(e.confidence.reason!.contains("began"), e.confidence.reason!)
    }

    func testAWindowEndingAfterTheTraceIsUnavailable() {
        let t = trace([(0, 20), (10, 20)])
        let e = t.energy(from: at(0), to: at(30))
        XCTAssertNil(e.value)
        XCTAssertTrue(e.confidence.reason!.contains("ends"), e.confidence.reason!)
    }

    func testAnEmptyTraceSaysWhyRatherThanReturningZero() {
        let e = PowerTrace().energy(from: at(0), to: at(1))
        XCTAssertNil(e.value)
        XCTAssertTrue(e.confidence.reason!.contains("on AC"), e.confidence.reason!)
    }

    func testAZeroLengthWindowIsRejected() {
        let t = trace([(0, 20), (10, 20)])
        XCTAssertNil(t.energy(from: at(5), to: at(5)).value)
    }

    // MARK: - Absent wattage is not zero wattage

    func testNilWattsIsDroppedRatherThanIntegratedAsZero() {
        // On AC the source has no number at all. Storing 0 would integrate to a
        // free lunch: a generation that apparently cost nothing.
        var t = PowerTrace()
        t.note(20, at: at(0))
        t.note(nil, at: at(5))
        t.note(20, at: at(10))
        XCTAssertEqual(t.count, 2)
        XCTAssertEqual(t.energy(from: at(0), to: at(10)).value!, 200, accuracy: 1e-9)
    }

    func testNonFiniteAndNegativeReadingsAreRejected() {
        var t = PowerTrace()
        t.note(.nan, at: at(0))
        t.note(.infinity, at: at(1))
        t.note(-5, at: at(2))
        t.note(0, at: at(3))
        XCTAssertEqual(t.count, 0)
    }

    // MARK: - Idle floor

    func testIdleFloorIsTheLowestQuietReading() {
        let t = trace([(0, 22), (5, 19), (10, 25), (15, 21)])
        XCTAssertEqual(t.idleFloor.value!, 19, accuracy: 1e-9)
    }

    func testBusyWindowsAreExcludedFromTheFloor() {
        // Otherwise a generation's own draw becomes the baseline it is measured
        // against, and the marginal cost of inference collapses toward zero.
        var t = trace([(0, 20), (5, 100), (10, 105), (15, 21), (20, 23)])
        t.markBusy(from: at(4), to: at(11))
        let floor = t.idleFloor
        XCTAssertEqual(floor.value!, 20, accuracy: 1e-9)
        XCTAssertEqual(floor.sampleCount, 3, "only the quiet readings count")
    }

    func testASessionThatWasBusyThroughoutHasNoFloor() {
        var t = trace([(0, 100), (5, 102), (10, 101)])
        t.markBusy(from: at(0), to: at(10))
        XCTAssertNil(t.idleFloor.value)
        XCTAssertFalse(t.idleFloor.confidence.isAvailable)
    }

    func testFloorNeedsEnoughSamplesToBeMeaningful() {
        let t = trace([(0, 20), (5, 21)])
        XCTAssertNil(t.idleFloor.value, "two readings is not a baseline")
    }

    // MARK: - Mean

    func testMeanWattsIsTheIntegralOverTheDuration() {
        let t = trace([(0, 10), (10, 30)])
        XCTAssertEqual(t.meanWatts(from: at(0), to: at(10))!, 20, accuracy: 1e-9)
    }

    func testMeanIsNilWhenTheWindowIsNotCovered() {
        let t = trace([(10, 20), (20, 20)])
        XCTAssertNil(t.meanWatts(from: at(0), to: at(20)))
    }

    // MARK: - Bookkeeping

    func testTheTraceIsBoundedAndKeepsTheNewestReadings() {
        var t = PowerTrace(capacity: 10)
        for i in 0..<50 { t.note(Double(i + 1), at: at(Double(i))) }
        XCTAssertEqual(t.count, 10)
        XCTAssertEqual(t.latest?.watts, 50)
        XCTAssertEqual(t.span!, 9, accuracy: 1e-9)
    }
}

/// The two edges of a window are not symmetric, and treating them as such
/// meant no energy was ever reported.
final class PowerTraceEdgeTests: XCTestCase {

    private func at(_ s: Double) -> Instant { Instant(s) }

    func testASubSecondTrailingGapIsToleratedAsAHeldValue() {
        // MEASURED: every real generation failed with "power trace ends 0.5s
        // before this generation finished". The generation ends when it ends;
        // our sampler last fired slightly earlier. That is sampling phase, not
        // missing data, and the source holds its value for ~4 s anyway.
        var t = PowerTrace()
        t.note(20, at: at(0))
        t.note(20, at: at(9.5))
        let e = t.energy(from: at(0), to: at(10))
        XCTAssertNotNil(e.value, e.confidence.reason ?? "")
        XCTAssertEqual(e.value!, 200, accuracy: 1e-9)
    }

    func testALargeTrailingGapIsStillRefused() {
        var t = PowerTrace()
        t.note(20, at: at(0))
        t.note(20, at: at(5))
        XCTAssertNil(t.energy(from: at(0), to: at(20)).value,
                     "a 15 s tail is missing data, not sampling phase")
    }

    func testTheLeadingEdgeGetsNoTolerance() {
        // Asymmetric on purpose: a window starting before the trace is genuinely
        // unobserved, and a partial integral would understate J/token.
        var t = PowerTrace()
        t.note(20, at: at(0.2))
        t.note(20, at: at(10))
        let e = t.energy(from: at(0), to: at(10))
        XCTAssertNil(e.value)
        XCTAssertTrue(e.confidence.reason!.contains("began"))
    }
}
