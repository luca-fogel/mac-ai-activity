import XCTest
@testable import Telemetry

/// A receipt arrives at the END of a prediction, while busy/idle is observed on
/// the roster's 0.2 Hz clock. The two orderings are both real, and getting the
/// attachment wrong would either lose the only token count MLX ever produces or
/// invent a generation that never happened.
final class ReceiptTests: XCTestCase {

    private func at(_ s: Double) -> Instant { Instant(s) }

    private func openEpisode(_ tr: inout EpisodeTracker, at t: Double = 0) {
        tr.note(generating: true, backend: "MLX", model: "qwen3.8-27b", at: at(t))
    }

    private func receipt(_ tr: inout EpisodeTracker, at t: Double,
                         tokens: Int? = 229, grace: Double = 15) -> Bool {
        tr.noteReceipt(tokens: tokens, tokensPerSecond: 5.98, ttft: 14.632,
                       stopReason: "eosFound", reportedBy: "lms log stream --stats",
                       at: at(t), grace: grace)
    }

    // MARK: - The MLX case this exists for

    func testReceiptGivesAnMLXEpisodeTheTokenCountItCouldNotOtherwiseHave() {
        var tr = EpisodeTracker()
        openEpisode(&tr)
        tr.noteWatts(20, at: at(0))
        tr.noteWatts(30, at: at(10))
        // Without a receipt this is the documented MLX blind spot.
        XCTAssertNil(tr.current?.tokens)
        XCTAssertFalse(tr.current!.joulesPerToken.confidence.isAvailable)

        XCTAssertTrue(receipt(&tr, at: 10))
        XCTAssertEqual(tr.current?.tokens, 229)
        XCTAssertEqual(tr.current?.reportedTokensPerSecond, 5.98)
        XCTAssertEqual(tr.current?.reportedTTFT, 14.632)
        XCTAssertEqual(tr.current?.reportedStopReason, "eosFound")
        XCTAssertEqual(tr.current?.reportedBy, "lms log stream --stats")
        // 250 J over 229 tokens.
        let jpt = tr.current!.joulesPerToken
        XCTAssertEqual(jpt.value!, 250.0 / 229.0, accuracy: 1e-9)
    }

    func testReceiptAttachesToAJustClosedEpisode() {
        // The common ordering: the engine reports the prediction finished before
        // the 0.2 Hz roster notices the runtime went idle.
        var tr = EpisodeTracker()
        openEpisode(&tr)
        tr.note(generating: false, backend: "MLX", model: "qwen3.8-27b", at: at(30))
        XCTAssertNil(tr.current, "episode should be closed")
        XCTAssertTrue(receipt(&tr, at: 31))
        XCTAssertEqual(tr.completed.first?.tokens, 229)
    }

    func testReceiptForALongClosedEpisodeIsDroppedNotMisattributed() {
        var tr = EpisodeTracker()
        openEpisode(&tr)
        tr.note(generating: false, backend: "MLX", model: "qwen3.8-27b", at: at(30))
        XCTAssertFalse(receipt(&tr, at: 300))
        XCTAssertNil(tr.completed.first?.tokens,
                     "a stale receipt must not be pinned to an unrelated generation")
    }

    func testAReceiptNeverCreatesAnEpisode() {
        // The stream is instance-wide with no caller identity, so a prediction
        // from another process must not manufacture an episode we know nothing
        // about — it would have no GPU or power envelope behind it.
        var tr = EpisodeTracker()
        XCTAssertFalse(receipt(&tr, at: 5))
        XCTAssertTrue(tr.episodes.isEmpty)
        XCTAssertTrue(tr.completed.isEmpty)
    }

    func testReceiptWithoutATokenCountLeavesTokensNilNotZero() {
        var tr = EpisodeTracker()
        openEpisode(&tr)
        XCTAssertTrue(receipt(&tr, at: 1, tokens: nil))
        XCTAssertNil(tr.current?.tokens)
        XCTAssertEqual(tr.current?.reportedStopReason, "eosFound")
        XCTAssertFalse(tr.current!.joulesPerToken.confidence.isAvailable)
    }

    func testReceiptNeverLowersACountAlreadyObserved() {
        var tr = EpisodeTracker()
        openEpisode(&tr)
        tr.noteTokens(400, prefillEnded: nil)
        XCTAssertTrue(receipt(&tr, at: 1, tokens: 229))
        XCTAssertEqual(tr.current?.tokens, 400)
    }

    // MARK: - The energy accumulator

    func testAccumulatorDeltaIsTheDifferenceAcrossTheEpisode() {
        var tr = EpisodeTracker()
        openEpisode(&tr)
        tr.noteAccumulatedEnergy(1_000_000, at: at(0))
        tr.noteAccumulatedEnergy(1_500_000, at: at(5))
        tr.noteAccumulatedEnergy(2_000_000, at: at(10))
        XCTAssertEqual(tr.current?.accumulatedEnergyDelta, 1_000_000)
    }

    func testAccumulatorGoingBackwardsInvalidatesTheIntervalRatherThanGoingNegative() {
        // A counter reset or wraparound. There is no handling for this anywhere
        // else in the app, and a negative energy is worse than no energy.
        var tr = EpisodeTracker()
        openEpisode(&tr)
        tr.noteAccumulatedEnergy(9_000_000, at: at(0))
        tr.noteAccumulatedEnergy(12, at: at(5))
        XCTAssertTrue(tr.current!.energyAccumInvalid)
        XCTAssertNil(tr.current?.accumulatedEnergyDelta)
        XCTAssertNil(tr.current?.energyUnitRatio)
    }

    func testAccumulatorIsIgnoredWhenAbsent() {
        var tr = EpisodeTracker()
        openEpisode(&tr)
        tr.noteAccumulatedEnergy(nil, at: at(0))
        XCTAssertNil(tr.current?.accumulatedEnergyDelta)
        XCTAssertFalse(tr.current!.energyAccumInvalid)
    }

    func testUnitRatioIsPublishedForCalibrationNotConvertedSilently() {
        // The scale of AccumulatedSystemEnergyConsumed is undocumented, so the
        // app must expose the implied ratio rather than assert joules.
        var tr = EpisodeTracker()
        openEpisode(&tr)
        tr.noteWatts(10, at: at(0))
        tr.noteWatts(10, at: at(10))          // 100 J trapezoidal
        tr.noteAccumulatedEnergy(0, at: at(0))
        tr.noteAccumulatedEnergy(500_000, at: at(10))
        XCTAssertEqual(tr.current!.energyJoules, 100, accuracy: 1e-9)
        XCTAssertEqual(tr.current!.energyUnitRatio!, 5000, accuracy: 1e-6)
        // And the reported energy is still the trapezoidal one, in real joules.
        XCTAssertEqual(tr.current!.energy.value!, 100, accuracy: 1e-9)
    }

    func testUnitRatioIsWithheldWhenThereIsTooLittleEnergyToDivideBy() {
        var tr = EpisodeTracker()
        openEpisode(&tr)
        tr.noteAccumulatedEnergy(0, at: at(0))
        tr.noteAccumulatedEnergy(50, at: at(1))
        XCTAssertNil(tr.current?.energyUnitRatio)
    }

    func testAccumulatorIsNotCarriedAcrossEpisodes() {
        var tr = EpisodeTracker()
        openEpisode(&tr)
        tr.noteAccumulatedEnergy(1_000, at: at(0))
        tr.noteAccumulatedEnergy(2_000, at: at(5))
        tr.note(generating: false, backend: "MLX", model: "m", at: at(6))
        tr.note(generating: true, backend: "MLX", model: "m", at: at(20))
        tr.noteAccumulatedEnergy(9_000, at: at(20))
        tr.noteAccumulatedEnergy(9_500, at: at(25))
        XCTAssertEqual(tr.current?.accumulatedEnergyDelta, 500,
                       "a new episode must start its own integral")
        XCTAssertEqual(tr.completed.first?.accumulatedEnergyDelta, 1_000)
    }
}
