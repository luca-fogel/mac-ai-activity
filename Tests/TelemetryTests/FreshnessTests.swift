import XCTest
@testable import Telemetry

/// The five states must be reachable and must not be confusable. Every case
/// here corresponds to something the app got wrong on screen: a red chip next
/// to a healthy generation, a warning-coloured hold, or a permanent error on a
/// source whose health was never emitted at all.
final class FreshnessTests: XCTestCase {

    private func at(_ s: Double) -> Instant { Instant(s) }

    // MARK: - Absent outranks everything

    func testAbsentSourceIsNeverAFaultEvenWithFailuresOnRecord() {
        // MLX case: the runtime is there, the channel is not. A leftover
        // failure record must not turn a structural gap into a red error.
        let f = Freshness.judge(
            FreshnessInput(now: at(100), lastOKAt: nil,
                           consecutiveFailures: 9, lastOutcome: .refused,
                           exists: false,
                           absentReason: "embedded MLX exposes no per-token counters"),
            policy: .polled(expected: 1))
        XCTAssertEqual(f, .absent("embedded MLX exposes no per-token counters"))
        XCTAssertFalse(f.isDark)
    }

    func testAbsentFallsBackToAGenericReasonRatherThanEmptyText() {
        let f = Freshness.judge(FreshnessInput(now: at(1), exists: false),
                                policy: .polled(expected: 1))
        XCTAssertEqual(f, .absent("not running"))
    }

    // MARK: - Cold start is not a fault

    func testNoAttemptYetReadsAbsentNotDark() {
        // This is the "inf no samples yet" bug: red, at launch, before any poll
        // could possibly have completed.
        let f = Freshness.judge(
            FreshnessInput(now: at(0.2), lastOKAt: nil, lastOutcome: nil),
            policy: .polled(expected: 1))
        XCTAssertEqual(f, .absent("no sample yet"))
        XCTAssertFalse(f.isDark)
    }

    func testAFailedAttemptIsDarkWithItsRealReason() {
        // Distinct from the above: an attempt DID finish, and it failed.
        let f = Freshness.judge(
            FreshnessInput(now: at(1), lastOKAt: nil, lastOutcome: .refused),
            policy: .polled(expected: 1))
        XCTAssertEqual(f, .dark(reason: "connection refused"))
    }

    func testThreeConsecutiveFailuresGoDarkUnderEveryPolicy() {
        let input = FreshnessInput(now: at(10), lastOKAt: at(9),
                                   consecutiveFailures: 3, lastOutcome: .http(500))
        for policy: FreshnessPolicy in [.polled(expected: 1),
                                        .heldValue(pollExpected: 5, refreshBound: 30),
                                        .eventDriven(quietAfter: 60)] {
            XCTAssertEqual(Freshness.judge(input, policy: policy),
                           .dark(reason: "HTTP 500"), "policy \(policy)")
        }
    }

    // MARK: - Polled

    func testPolledLiveWithinTwiceTheExpectedInterval() {
        let f = Freshness.judge(
            FreshnessInput(now: at(11.5), lastOKAt: at(11), lastOutcome: .ok,
                           measuredHz: 1.02, jitter: 0.04),
            policy: .polled(expected: 1))
        XCTAssertEqual(f, .live(hz: 1.02, jitter: 0.04))
    }

    func testPolledStaleBeyondTwiceAndDarkBeyondTen() {
        let base = { (now: Double) in
            FreshnessInput(now: Instant(now), lastOKAt: Instant(0), lastOutcome: .ok)
        }
        XCTAssertEqual(Freshness.judge(base(3), policy: .polled(expected: 1)),
                       .stale(age: 3))
        guard case .dark = Freshness.judge(base(11), policy: .polled(expected: 1)) else {
            return XCTFail("11 s against a 1 s expectation should be dark")
        }
    }

    // MARK: - Held value: two clocks, which is the pwr bug

    func testHealthyPollWithAnUnmovedValueIsHeldNotStale() {
        // The exact shape of "pwr stale 44.5s": the poll answered 1 s ago, the
        // value last moved 4 s ago, and the source is entirely healthy.
        let f = Freshness.judge(
            FreshnessInput(now: at(100), lastOKAt: at(99),
                           lastValueChangedAt: at(96), lastOutcome: .ok),
            policy: .heldValue(pollExpected: 5, refreshBound: 30))
        XCTAssertEqual(f, .held(age: 4))
    }

    func testValueFrozenBeyondItsObservedBoundIsStale() {
        let f = Freshness.judge(
            FreshnessInput(now: at(100), lastOKAt: at(99),
                           lastValueChangedAt: at(55.5), lastOutcome: .ok),
            policy: .heldValue(pollExpected: 5, refreshBound: 30))
        XCTAssertEqual(f, .stale(age: 44.5))
    }

    func testTheePollFailingOutranksTheValueBeingFresh() {
        // If nobody is answering us, the value's age is not the story.
        let f = Freshness.judge(
            FreshnessInput(now: at(100), lastOKAt: at(80),
                           lastValueChangedAt: at(99.5), lastOutcome: .ok),
            policy: .heldValue(pollExpected: 5, refreshBound: 30))
        XCTAssertEqual(f, .stale(age: 20))
    }

    func testHeldValueWithNoChangeTimestampFallsBackToLive() {
        let f = Freshness.judge(
            FreshnessInput(now: at(100), lastOKAt: at(99),
                           lastValueChangedAt: nil, lastOutcome: .ok, measuredHz: 0.2),
            policy: .heldValue(pollExpected: 5, refreshBound: 30))
        XCTAssertEqual(f, .live(hz: 0.2, jitter: 0))
    }

    func testValueAgeIsNeverNegativeWhenClocksDisagree() {
        let f = Freshness.judge(
            FreshnessInput(now: at(10), lastOKAt: at(10),
                           lastValueChangedAt: at(10.5), lastOutcome: .ok),
            policy: .heldValue(pollExpected: 5, refreshBound: 30))
        XCTAssertEqual(f, .held(age: 0))
    }

    // MARK: - Event driven: silence carries no health information

    func testPushSourceWithNoEventYetIsAbsentNotDark() {
        let f = Freshness.judge(
            FreshnessInput(now: at(30), lastOKAt: nil, lastOutcome: nil),
            policy: .eventDriven(quietAfter: 60))
        XCTAssertEqual(f, .absent("no event yet"))
    }

    func testPushSourceGoesQuietAsAbsentNeverStale() {
        // A prediction stream between predictions is idle, not degraded. This
        // is what makes it safe to render alongside polled sources.
        let f = Freshness.judge(
            FreshnessInput(now: at(400), lastOKAt: at(100), lastOutcome: .ok),
            policy: .eventDriven(quietAfter: 60))
        XCTAssertTrue(f.isAbsent, "quiet push source should be absent, got \(f)")
        XCTAssertFalse(f.isDark)
        if case .absent(let r) = f { XCTAssertTrue(r.contains("300")) }
    }

    func testPushSourceIsLiveWhileEventsAreArriving() {
        let f = Freshness.judge(
            FreshnessInput(now: at(120), lastOKAt: at(100), lastOutcome: .ok,
                           measuredHz: 0.05),
            policy: .eventDriven(quietAfter: 60))
        XCTAssertEqual(f, .live(hz: 0.05, jitter: 0))
    }

    // MARK: - The five states must be mutually exclusive

    func testNoTwoStatesCollideForTheSameInput() {
        let cases: [(FreshnessInput, FreshnessPolicy)] = [
            (FreshnessInput(now: at(1), exists: false), .polled(expected: 1)),
            (FreshnessInput(now: at(1), lastOKAt: nil), .polled(expected: 1)),
            (FreshnessInput(now: at(1), lastOKAt: at(0.9), lastOutcome: .ok),
             .polled(expected: 1)),
            (FreshnessInput(now: at(10), lastOKAt: at(9),
                            lastValueChangedAt: at(8), lastOutcome: .ok),
             .heldValue(pollExpected: 5, refreshBound: 30)),
            (FreshnessInput(now: at(10), lastOKAt: at(0), lastOutcome: .ok),
             .polled(expected: 1)),
            (FreshnessInput(now: at(100), lastOKAt: nil, lastOutcome: .timeout),
             .polled(expected: 1)),
        ]
        let results = cases.map { Freshness.judge($0.0, policy: $0.1) }
        // absent, absent, live, held, stale, dark — five distinct kinds present.
        let kinds = Set(results.map { r -> String in
            switch r {
            case .absent: return "absent"
            case .live:   return "live"
            case .held:   return "held"
            case .stale:  return "stale"
            case .dark:   return "dark"
            }
        })
        XCTAssertEqual(kinds, ["absent", "live", "held", "stale", "dark"])
    }
}
