import XCTest
@testable import Telemetry
import IOKit

/// The sensing half: decoding, and the rules that decide what a reading means.
///
/// Every case here corresponds to a way this feature could put a confident
/// wrong number on screen — a 12 °C CPU during a GPU-bound generation, a
/// 115 °C "die sensor" that is not one, a fan rpm read 4x too high.
final class ThermalSensingTests: XCTestCase {

    // MARK: - Key coding: the trap that cost the first working build

    func testFourCCIsHostOrderNumberNotAByteString() {
        // '#KEY' = 0x234B4559. Storing this BIG-endian is what produced
        // "result 0x84, key not found" from a perfectly open connection.
        XCTAssertEqual(SMC.fourCC("#KEY"), 0x234B4559)
        XCTAssertEqual(SMC.string(0x234B4559), "#KEY")
        XCTAssertEqual(SMC.string(SMC.fourCC("F0Tg")), "F0Tg")
    }

    func testShortKeysAreLeftPackedTheWayTheSMCPadsThem() {
        XCTAssertEqual(SMC.fourCC("Tg"), 0x5467)
    }

    // MARK: - Payload decoding

    func testFloatPayloadIsLittleEndianWhileIntegersAreBig() {
        // 6800.0f = 0x45D48000. The SMC sends the float LSB-first.
        let bytes: [UInt8] = [0x00, 0x80, 0xD4, 0x45]
        XCTAssertEqual(SMC.decode(bytes, type: "flt ")!, 6800, accuracy: 0.001)
        // ui16 of the same bytes, big-endian, is a completely different number:
        // reading one as the other is a silent 100x error.
        XCTAssertEqual(SMC.decode([0x00, 0x80], type: "ui16"), 128)
    }

    func testFpe2IsFixedPointAndNotAPlainInteger() {
        // 0x2000 = 8192 raw; as fpe2 it is 2048 rpm. Decoding this as ui16
        // reports four times the real fan speed.
        XCTAssertEqual(SMC.decode([0x20, 0x00], type: "fpe2"), 2048)
    }

    func testSignedAndUnsignedSmallTypes() {
        XCTAssertEqual(SMC.decode([0xFF], type: "si8 "), -1)
        XCTAssertEqual(SMC.decode([0xFF], type: "ui8 "), 255)
        XCTAssertEqual(SMC.decode([0xFF, 0xFF], type: "si16"), -1)
    }

    func testUnknownTypeIsNilRatherThanAGuessedLayout() {
        XCTAssertNil(SMC.decode([0x01, 0x02, 0x03, 0x04], type: "hex_"))
        XCTAssertNil(SMC.decode([0x01, 0x02, 0x03, 0x04], type: "ch8*"))
    }

    func testTruncatedPayloadIsNilRatherThanPartiallyDecoded() {
        XCTAssertNil(SMC.decode([0x00, 0x80], type: "flt "))
        XCTAssertNil(SMC.decode([], type: "ui8 "))
    }

    func testNonFiniteFloatIsRefused() {
        // 0x7F800000 = +infinity. A sensor reporting this must not become an
        // infinite temperature at the top of a chart's y-domain.
        XCTAssertNil(SMC.decode([0x00, 0x00, 0x80, 0x7F], type: "flt "))
    }

    func testFloatEncodeRoundTripsThroughTheDecoder() {
        for rpm in [2317.0, 4200.0, 6800.0] {
            XCTAssertEqual(SMC.decode(SMC.encodeFloat(rpm), type: "flt ")!, rpm, accuracy: 0.01)
        }
    }

    /// The privilege boundary is at the KERNEL, not in an SMC result byte.
    /// `telemetry-probe --smc` asserts the live behaviour; this pins the mapping.
    func testKernelLevelRefusalIsReportedAsNotPrivileged() {
        XCTAssertEqual(SMC.Result(kernReturn: kIOReturnNotPrivileged), .notPrivileged)
        XCTAssertEqual(SMC.Result(kernReturn: kIOReturnNoDevice), .ioKit(kIOReturnNoDevice))
        XCTAssertEqual(SMC.Result(0x84), .keyNotFound)
        XCTAssertTrue(SMC.Result(kernReturn: kIOReturnNotPrivileged).reason.contains("root"))
    }

    // MARK: - Groups: a hotspot is a max, and gated is not cold

    func testHottestIsAMaxNotAMean() {
        let g = SensorGroup(domain: .cpuPerformance,
                            live: [("Tp01", 50), ("Tp02", 95), ("Tp03", 52)],
                            parked: [])
        XCTAssertEqual(g.hottest.value!, 95, accuracy: 0.001)
        // 65.7 would be the mean. Throttling is decided by the hot spot.
        XCTAssertEqual(g.mean!, 65.666, accuracy: 0.01)
    }

    func testClusterScatterTravelsAsUncertaintyRatherThanBeingSmoothed() {
        let g = SensorGroup(domain: .gpu, live: [("Tg0", 60), ("Tg1", 80)], parked: [])
        XCTAssertEqual(g.hottest.uncertainty!, 10, accuracy: 0.001)
        XCTAssertEqual(g.hottest.sampleCount, 2)
    }

    /// The measured trap: during GPU-bound inference the P-cluster is gated off
    /// and reads 12–23 °C. Publishing that as "CPU temperature" makes the
    /// headline FALL as the machine heats up.
    func testAnAllParkedClusterIsUnavailableWithAReasonNotAColdNumber() {
        let g = SensorGroup(domain: .cpuPerformance, live: [],
                            parked: [("Tp01", 12.7), ("Tp02", 23.3)])
        XCTAssertNil(g.hottest.value)
        XCTAssertEqual(g.hottest.confidence.isAvailable, false)
        XCTAssertTrue(g.hottest.confidence.reason!.contains("power-gated"))
        XCTAssertNil(g.mean)
    }

    func testAGroupWithNoSensorsAtAllSaysSoDifferently() {
        let g = SensorGroup(domain: .gpu, live: [], parked: [])
        XCTAssertEqual(g.hottest.confidence.reason, "no readable sensor")
    }

    // MARK: - Hotspot selection

    private func sample(_ groups: [SensorGroup],
                        fans: [FanSample] = [],
                        pressure: ThermalState = .nominal) -> ThermalSample {
        ThermalSample(t: Instant(1), groups: groups, fans: fans, pressure: pressure,
                      pressureSince: Instant(0),
                      speedLimit: .unavailable("n/a"),
                      sampleCostMicros: 13_100, sensorsRead: 67)
    }

    func testHotspotIgnoresTheBatteryEvenWhenItIsTheHottestThingReadable() {
        let s = sample([
            SensorGroup(domain: .gpu, live: [("Tg0", 70)], parked: []),
            SensorGroup(domain: .battery, live: [("TB0T", 99)], parked: []),
        ])
        XCTAssertEqual(s.hotspot?.domain, .gpu)
        XCTAssertEqual(s.hotspot?.estimate.value, 70)
    }

    func testHotspotFollowsTheWorkloadFromCPUToGPU() {
        // CPU burn: P-cluster wins.
        let cpuBurn = sample([
            SensorGroup(domain: .cpuPerformance, live: [("Tp0A", 113)], parked: []),
            SensorGroup(domain: .gpu, live: [("Tg0X", 85)], parked: []),
        ])
        XCTAssertEqual(cpuBurn.hotspot?.domain, .cpuPerformance)

        // GPU burn, P-cluster gated: the GPU wins and the CPU is reported parked
        // rather than quoted at 23 °C.
        let gpuBurn = sample([
            SensorGroup(domain: .cpuPerformance, live: [], parked: [("Tp0A", 23)]),
            SensorGroup(domain: .gpu, live: [("Tg0X", 82)], parked: []),
        ])
        XCTAssertEqual(gpuBurn.hotspot?.domain, .gpu)
        XCTAssertEqual(gpuBurn.parkedDomains, [.cpuPerformance])
    }

    func testHotspotIsNilWhenEveryDieGroupIsUnreadable() {
        let s = sample([SensorGroup(domain: .battery, live: [("TB0T", 33)], parked: [])])
        XCTAssertNil(s.hotspot)
    }

    // MARK: - Fans

    func testDutyFractionNeedsAllThreeNumbersOrItIsNotAMeasurement() {
        let ok = FanSample(index: 0, actualRPM: 4558, targetRPM: 4558,
                           minRPM: 2317, maxRPM: 6800, mode: .auto)
        XCTAssertEqual(ok.dutyFraction!, 0.5, accuracy: 0.01)

        let noMax = FanSample(index: 0, actualRPM: 4558, targetRPM: nil,
                              minRPM: 2317, maxRPM: nil, mode: .auto)
        XCTAssertNil(noMax.dutyFraction)
    }

    func testStoppedFanIsZeroNotMissing() {
        // MEASURED: both fans sit at 0 rpm when the machine is cool, which is
        // BELOW the 2317 rpm minimum the SMC accepts as a forced target.
        let f = FanSample(index: 0, actualRPM: 0, targetRPM: 0,
                          minRPM: 2317, maxRPM: 6800, mode: .auto)
        XCTAssertEqual(f.actualRPM, 0)
        XCTAssertEqual(f.dutyFraction!, 0, accuracy: 0.0001)
    }

    func testTrackingToleranceAllowsSpinUpButNotAStuckFan() {
        let spinning = FanSample(index: 0, actualRPM: 4100, targetRPM: 4200,
                                 minRPM: 2317, maxRPM: 6800, mode: .forced)
        XCTAssertTrue(spinning.isTracking)
        let stuck = FanSample(index: 0, actualRPM: 2317, targetRPM: 5200,
                              minRPM: 2317, maxRPM: 6800, mode: .forced)
        XCTAssertFalse(stuck.isTracking)
    }

    func testThermalStateSeverityIsRankedNotAlphabetical() {
        // Alphabetically "critical" < "fair", which would make "worst seen"
        // silently wrong in the episode tracker.
        XCTAssertTrue(ThermalState.critical.severity > ThermalState.fair.severity)
        XCTAssertTrue(ThermalState.serious.severity > ThermalState.fair.severity)
        XCTAssertTrue(ThermalState.fair.severity > ThermalState.nominal.severity)
    }
}

/// The control half. These are the tests that let a thermal cutout be verified
/// without overheating a laptop to find out.
final class FanGuardTests: XCTestCase {

    private let limits = FanGuard.Limits(minRPM: 2317, maxRPM: 6800)

    // MARK: - Clamping is never silent

    func testRequestBelowHardwareMinimumIsRaisedAndSaidOutLoud() {
        let (rpm, note) = FanGuard.clamp(800, to: limits)
        XCTAssertEqual(rpm, 2317)
        XCTAssertNotNil(note)
        XCTAssertTrue(note!.contains("2317"))
    }

    func testRequestAboveHardwareMaximumIsCapped() {
        let (rpm, note) = FanGuard.clamp(12_000, to: limits)
        XCTAssertEqual(rpm, 6800)
        XCTAssertNotNil(note)
    }

    func testInRangeRequestPassesWithNoNote() {
        let (rpm, note) = FanGuard.clamp(4200, to: limits)
        XCTAssertEqual(rpm, 4200)
        XCTAssertNil(note)
    }

    func testNaNBecomesTheMinimumRatherThanAnUndefinedWrite() {
        let (rpm, note) = FanGuard.clamp(.nan, to: limits)
        XCTAssertEqual(rpm, 2317)
        XCTAssertNotNil(note)
    }

    func testDegenerateHardwareRangeRefusesToDriveTheFan() {
        let (rpm, note) = FanGuard.clamp(4000, to: FanGuard.Limits(minRPM: 3000, maxRPM: 3000))
        XCTAssertEqual(rpm, 3000)
        XCTAssertEqual(note, "hardware reported no usable rpm range")
    }

    // MARK: - Leases

    func testLeaseIsClampedAtBothEndsAndDefaulted() {
        XCTAssertEqual(FanGuard.clampLease(nil), 15)
        XCTAssertEqual(FanGuard.clampLease(0), FanGuard.minLeaseSeconds)
        XCTAssertEqual(FanGuard.clampLease(86_400), FanGuard.maxLeaseSeconds)
        XCTAssertEqual(FanGuard.clampLease(.nan), FanGuard.minLeaseSeconds)
        XCTAssertEqual(FanGuard.clampLease(20), 20)
    }

    // MARK: - The deadman

    private func conditions(hot: Double?, pressure: ThermalState = .nominal,
                            lease: Double?, now: Double = 100,
                            stuck: Double? = nil,
                            tripUntil: Double? = nil,
                            trip: GuardTrip? = nil) -> FanGuard.Conditions {
        FanGuard.Conditions(hotspotC: hot, pressure: pressure,
                            leaseExpiresAt: lease, now: now,
                            fanStuckSince: stuck, tripUntil: tripUntil, currentTrip: trip)
    }

    func testNothingHeldMeansNothingToDo() {
        XCTAssertEqual(FanGuard.evaluate(conditions(hot: 99, lease: nil)), .idle)
    }

    func testHoldsWhileCoolAndRenewed() {
        XCTAssertEqual(FanGuard.evaluate(conditions(hot: 70, lease: 130)), .hold)
    }

    /// The ordering that matters most: a hot machine is released even though
    /// the client is healthy and the lease is valid.
    func testOverTemperatureOutranksAPerfectlyValidLease() {
        let d = FanGuard.evaluate(conditions(hot: 95, lease: 130))
        XCTAssertEqual(d, .release(.overTemperature))
    }

    func testSeriousOSPressureReleasesEvenWithACoolSensorReading() {
        // The kernel knows things the die sensors do not, so its judgement is
        // allowed to override a comfortable-looking number.
        let d = FanGuard.evaluate(conditions(hot: 61, pressure: .serious, lease: 130))
        XCTAssertEqual(d, .release(.thermalPressure))
    }

    func testExpiredLeaseReleases() {
        XCTAssertEqual(FanGuard.evaluate(conditions(hot: 60, lease: 99)),
                       .release(.leaseExpired))
    }

    func testSpinUpIsToleratedButASustainedlyStuckFanIsNot() {
        XCTAssertEqual(FanGuard.evaluate(conditions(hot: 60, lease: 130, stuck: 95)), .hold)
        XCTAssertEqual(FanGuard.evaluate(conditions(hot: 60, lease: 130, stuck: 80)),
                       .release(.fanNotTracking))
    }

    func testAnUnreadableHotspotDoesNotByItselfReleaseControl() {
        // A missing temperature is not a hot temperature. The lease still bounds
        // the exposure, which is the whole point of having one.
        XCTAssertEqual(FanGuard.evaluate(conditions(hot: nil, lease: 130)), .hold)
    }

    // MARK: - Re-admission is a separate decision from release

    func testTripLocksOutNewRequestsUntilTheCooldownPasses() {
        let c = conditions(hot: 60, lease: nil, tripUntil: 140, trip: .overTemperature)
        let a = FanGuard.admits(c)
        XCTAssertFalse(a.allowed)
        XCTAssertTrue(a.reason!.contains("40s"))
    }

    func testNearCeilingIsRefusedEvenWithNoTripOnRecord() {
        // Hysteresis: admitting at 94 °C when release is at 95 °C would produce
        // a flapping cutout rather than a safety mechanism.
        let a = FanGuard.admits(conditions(hot: 91, lease: nil))
        XCTAssertFalse(a.allowed)
        XCTAssertTrue(a.reason!.contains("within"))
    }

    func testCoolAndUntrippedIsAdmitted() {
        let a = FanGuard.admits(conditions(hot: 62, lease: nil))
        XCTAssertTrue(a.allowed)
        XCTAssertNil(a.reason)
    }

    func testSeriousPressureRefusesNewControlWithItsOwnReason() {
        let a = FanGuard.admits(conditions(hot: 55, pressure: .critical, lease: nil))
        XCTAssertFalse(a.allowed)
        XCTAssertTrue(a.reason!.contains("critical"))
    }
}

/// Policy evaluation: what the app ASKS for, before the helper polices it.
final class CoolingPolicyTests: XCTestCase {

    private func input(_ hot: Double?, generating: Bool,
                       lastGen: Double? = nil, now: Double = 100) -> CoolingInput {
        CoolingInput(hotspotC: hot, generating: generating,
                     lastGeneratingAt: lastGen.map(Instant.init),
                     now: Instant(now))
    }

    func testAutomaticAsksForNothing() {
        XCTAssertNil(CoolingPolicy.system.desiredRPM(input(90, generating: true)))
    }

    func testFixedIgnoresTemperatureEntirely() {
        XCTAssertEqual(CoolingPolicy.fixed(rpm: 3000).desiredRPM(input(40, generating: false)), 3000)
    }

    func testCurveIsPiecewiseLinearAndFlatOutsideItsKnees() {
        let c = CoolingCurve(quietBelowC: 55, fullAboveC: 85, minRPM: 2400, maxRPM: 6000)
        XCTAssertEqual(c.rpm(forHotspot: 40)!, 2400, accuracy: 0.01)
        XCTAssertEqual(c.rpm(forHotspot: 55)!, 2400, accuracy: 0.01)
        XCTAssertEqual(c.rpm(forHotspot: 70)!, 4200, accuracy: 0.01)
        XCTAssertEqual(c.rpm(forHotspot: 85)!, 6000, accuracy: 0.01)
        XCTAssertEqual(c.rpm(forHotspot: 120)!, 6000, accuracy: 0.01)
    }

    /// The one place a missing measurement could silently become a fan speed.
    func testCurveWithNoReadableTemperatureYieldsNothingRatherThanADefault() {
        XCTAssertNil(CoolingCurve().rpm(forHotspot: nil))
        XCTAssertNil(CoolingPolicy.curve(CoolingCurve()).desiredRPM(input(nil, generating: true)))
    }

    func testDegenerateCurveGoesToMaximumRatherThanDividingByZero() {
        let c = CoolingCurve(quietBelowC: 80, fullAboveC: 80, minRPM: 2400, maxRPM: 6000)
        XCTAssertEqual(c.rpm(forHotspot: 60)!, 6000, accuracy: 0.01)
    }

    // MARK: - Boost

    func testBoostAppliesTheMomentWorkStartsNotWhenTheDieIsHot() {
        let p = CoolingPolicy.boostWhileGenerating(
            BoostSettings(generatingRPM: 4200, trailingSeconds: 20, idleRPM: nil, curve: nil))
        // Cold die, work just started: the fan is asked for anyway. This is the
        // entire reason the feature exists.
        XCTAssertEqual(p.desiredRPM(input(45, generating: true)), 4200)
    }

    func testBoostTrailsOffAfterWorkStopsAndThenReleases() {
        let p = CoolingPolicy.boostWhileGenerating(
            BoostSettings(generatingRPM: 4200, trailingSeconds: 20, idleRPM: nil, curve: nil))
        XCTAssertEqual(p.desiredRPM(input(60, generating: false, lastGen: 90, now: 100)), 4200)
        XCTAssertNil(p.desiredRPM(input(60, generating: false, lastGen: 70, now: 100)))
    }

    func testBoostIsAFloorSoAHotCurveStillWins() {
        let p = CoolingPolicy.boostWhileGenerating(
            BoostSettings(generatingRPM: 3000, trailingSeconds: 20, idleRPM: nil,
                          curve: CoolingCurve(quietBelowC: 55, fullAboveC: 85,
                                              minRPM: 2400, maxRPM: 6000)))
        // Curve wants 6000 at 90 °C; a comfort-chosen boost must not cap it.
        XCTAssertEqual(p.desiredRPM(input(90, generating: true))!, 6000, accuracy: 0.01)
    }

    func testBoostWithAnIdleFloorHoldsThatFloorWhenQuiet() {
        let p = CoolingPolicy.boostWhileGenerating(
            BoostSettings(generatingRPM: 4200, trailingSeconds: 5, idleRPM: 2600, curve: nil))
        XCTAssertEqual(p.desiredRPM(input(50, generating: false, lastGen: 10, now: 100)), 2600)
    }

    func testPolicyIsForcingReflectsWhetherAnythingWillBeWritten() {
        XCTAssertFalse(CoolingPolicy.system.isForcing)
        XCTAssertTrue(CoolingPolicy.fixed(rpm: 3000).isForcing)
    }
}

/// The thermal envelope attached to a generation.
final class EpisodeThermalTests: XCTestCase {

    private func trackerWithOpenEpisode() -> EpisodeTracker {
        var t = EpisodeTracker()
        t.note(generating: true, backend: "llama.cpp", model: "qwen", at: Instant(0))
        return t
    }

    func testPeakAndRiseAreRecordedAcrossTicks() {
        var t = trackerWithOpenEpisode()
        t.noteThermal(hotspotC: 60, domain: .gpu, fanRPM: 2400, fansForced: false,
                      pressure: .nominal, at: Instant(1))
        t.noteThermal(hotspotC: 88, domain: .gpu, fanRPM: 5200, fansForced: false,
                      pressure: .fair, at: Instant(2))
        t.noteThermal(hotspotC: 81, domain: .gpu, fanRPM: 5100, fansForced: false,
                      pressure: .nominal, at: Instant(3))
        let e = t.current!
        XCTAssertEqual(e.peakHotspotC!, 88, accuracy: 0.001)
        XCTAssertEqual(e.startHotspotC!, 60, accuracy: 0.001)
        XCTAssertEqual(e.hotspotRiseC!, 28, accuracy: 0.001)
        XCTAssertEqual(e.peakFanRPM!, 5200, accuracy: 0.001)
        XCTAssertEqual(e.worstPressure, .fair)
        XCTAssertEqual(e.thermalSamples, 3)
    }

    func testASingleTickGivesAPeakButNoRise() {
        // A generation shorter than two thermal ticks has no rise to report,
        // and inventing one from a single sample would be a fabrication.
        var t = trackerWithOpenEpisode()
        t.noteThermal(hotspotC: 72, domain: .cpuPerformance, fanRPM: nil,
                      fansForced: false, pressure: .nominal, at: Instant(1))
        XCTAssertEqual(t.current!.peakHotspotC!, 72, accuracy: 0.001)
        XCTAssertNil(t.current!.hotspotRiseC)
    }

    func testAnUnreadableHotspotDoesNotCountAsAThermalSample() {
        var t = trackerWithOpenEpisode()
        t.noteThermal(hotspotC: nil, domain: nil, fanRPM: 3000, fansForced: false,
                      pressure: .nominal, at: Instant(1))
        XCTAssertEqual(t.current!.thermalSamples, 0)
        XCTAssertNil(t.current!.peakHotspotC)
        // The fan reading is still real and still recorded.
        XCTAssertEqual(t.current!.peakFanRPM!, 3000, accuracy: 0.001)
    }

    func testForcedFansAreStickyForTheWholeEpisode() {
        // One tick with the fans held taints the run's comparability, so the
        // flag must not clear when control is handed back mid-generation.
        var t = trackerWithOpenEpisode()
        t.noteThermal(hotspotC: 70, domain: .gpu, fanRPM: 4200, fansForced: true,
                      pressure: .nominal, at: Instant(1))
        t.noteThermal(hotspotC: 71, domain: .gpu, fanRPM: 4200, fansForced: false,
                      pressure: .nominal, at: Instant(2))
        XCTAssertTrue(t.current!.fansForced)
    }

    func testWorstPressureUsesSeverityNotOrderOfArrival() {
        var t = trackerWithOpenEpisode()
        t.noteThermal(hotspotC: 90, domain: .gpu, fanRPM: nil, fansForced: false,
                      pressure: .critical, at: Instant(1))
        t.noteThermal(hotspotC: 70, domain: .gpu, fanRPM: nil, fansForced: false,
                      pressure: .nominal, at: Instant(2))
        XCTAssertEqual(t.current!.worstPressure, .critical)
    }

    func testThermalTicksWithNoOpenEpisodeAreDropped() {
        var t = EpisodeTracker()
        t.noteThermal(hotspotC: 80, domain: .gpu, fanRPM: 4000, fansForced: true,
                      pressure: .fair, at: Instant(1))
        XCTAssertNil(t.current)
        XCTAssertTrue(t.completed.isEmpty)
    }
}

/// The wire between two processes, one of which runs as root.
///
/// Pinned by tests because a silent encoding mismatch here does not fail
/// loudly — it fails as fans that quietly never move.
final class CoolingProtocolTests: XCTestCase {

    func testIntKeyedTargetsSurviveTheRoundTrip() throws {
        // Swift encodes Int-keyed dictionaries as JSON objects with stringified
        // keys, but that is a language detail this protocol depends on, so it
        // is asserted rather than assumed.
        let req = CoolingRequest(op: .set, targets: [0: 4200, 1: 4200.5],
                                 leaseSeconds: 15)
        let data = try JSONEncoder().encode(req)
        let back = try JSONDecoder().decode(CoolingRequest.self, from: data)
        XCTAssertEqual(back.targets?[0], 4200)
        XCTAssertEqual(back.targets?[1], 4200.5)
        XCTAssertEqual(back.op, .set)
        XCTAssertEqual(back.version, Cooling.protocolVersion)
        XCTAssertEqual(back.leaseSeconds, 15)
    }

    func testStatusRoundTripsIncludingLimitsAndTrip() throws {
        let s = CoolingStatus(helperVersion: "1.0", forcing: true,
                              targets: [0: 4200, 1: 4200],
                              leaseRemaining: 11.5,
                              lastClamp: "fan 0: 800 rpm is below the hardware minimum 2317",
                              trip: .overTemperature, tripUntil: 42,
                              hardCeilingC: 95,
                              limits: [0: [2317, 6800], 1: [2317, 6800]],
                              hotspotC: 88.5)
        let back = try JSONDecoder().decode(CoolingStatus.self,
                                            from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.limits[1], [2317, 6800])
        XCTAssertEqual(back.trip, .overTemperature)
    }

    func testResponseCarriesEitherAnErrorOrAStatusAndSaysWhich() throws {
        let refused = CoolingResponse(ok: false, error: "hotspot 92 °C is within 5 °C of the ceiling")
        let back = try JSONDecoder().decode(CoolingResponse.self,
                                            from: JSONEncoder().encode(refused))
        XCTAssertFalse(back.ok)
        XCTAssertNil(back.status)
        XCTAssertNotNil(back.error)
    }

    func testEveryTripHasAnExplanationFitToShowAUser() {
        for t in [GuardTrip.overTemperature, .thermalPressure, .leaseExpired,
                  .helperExiting, .fanNotTracking] {
            XCTAssertFalse(t.explanation.isEmpty)
            // Each one has to say what happened to the fans, because that is
            // the question a user has when a banner appears.
            XCTAssertTrue(t.explanation.contains("automatic"), "\(t): \(t.explanation)")
        }
    }
}
