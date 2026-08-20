import XCTest
@testable import Telemetry

/// The arithmetic that once put 1.8e16 W on screen.
///
/// `InstantAmperage` and `PowerTelemetryData.SystemLoad` are both SIGNED values
/// published as unsigned. Read naively they come back as ~1.8e19 rather than a
/// small negative number.
final class PowerSignTests: XCTestCase {

    func testPositiveValuesPassThroughUnchanged() {
        XCTAssertEqual(PowerSource.signedFromUnsigned(0), 0)
        XCTAssertEqual(PowerSource.signedFromUnsigned(12_581), 12_581)
        XCTAssertEqual(PowerSource.signedFromUnsigned(UInt64.max / 2), Double(UInt64.max / 2))
    }

    func testWrappedValuesReadAsTheNegativeTheyAre() {
        // Two's complement: all-ones is -1.
        XCTAssertEqual(PowerSource.signedFromUnsigned(UInt64.max), -1)
        XCTAssertEqual(PowerSource.signedFromUnsigned(UInt64.max - 999), -1000)
        // A realistic discharge current of -3200 mA.
        XCTAssertEqual(PowerSource.signedFromUnsigned(UInt64.max - 3199), -3200)
    }

    func testTheObservedChargingValueReadsAsNegativeNotAstronomical() {
        // OBSERVED: -25.65 W of net flow INTO the battery, i.e. -25650 mW.
        let raw = UInt64(bitPattern: Int64(-25_650))
        let v = PowerSource.signedFromUnsigned(raw)
        XCTAssertEqual(v, -25_650)
        XCTAssertLessThan(abs(v), 1e6, "this is the 1.8e19 misread: \(v)")
    }

    func testTheBoundaryDoesNotOverflow() {
        // `UInt64.max - u + 1` would overflow at u == 0, which the midpoint
        // comparison excludes. Assert the two values either side of the split.
        let mid = UInt64.max / 2
        XCTAssertGreaterThan(PowerSource.signedFromUnsigned(mid), 0)
        XCTAssertLessThan(PowerSource.signedFromUnsigned(mid + 1), 0)
        XCTAssertTrue(PowerSource.signedFromUnsigned(mid + 1).isFinite)
    }

    func testRoundTripsAgainstInt64ForRepresentativeValues() {
        for expected: Int64 in [-100_000, -25_650, -3_200, -1, 0, 1, 12_570, 199_999] {
            let raw = UInt64(bitPattern: expected)
            XCTAssertEqual(PowerSource.signedFromUnsigned(raw), Double(expected),
                           "round trip failed for \(expected)")
        }
    }
}

/// The four-way cascade. Every branch corresponds to a distinct physical
/// situation, and three of the four must refuse to publish a number.
final class PowerCascadeTests: XCTestCase {

    private func derive(systemLoadmW: Double? = nil, mV: Double? = nil,
                        mA: Double? = nil, onAC: Bool = false,
                        charging: Bool = false) -> (Estimate<Double>, String?) {
        PowerSource.deriveWatts(systemLoadmW: systemLoadmW, milliVolts: mV,
                                milliAmps: mA, onAC: onAC, isCharging: charging)
    }

    func testSystemLoadIsPreferredWhenPositiveAndPlausible() {
        // VERIFIED against V x I: 12.581 W vs 12.57 W.
        let (w, src) = derive(systemLoadmW: 12_581)
        XCTAssertEqual(w.value!, 12.581, accuracy: 1e-9)
        XCTAssertEqual(w.confidence, .high)
        XCTAssertEqual(src, "PowerTelemetryData.SystemLoad")
    }

    func testAnImplausiblySystemLoadIsRejectedRatherThanRendered() {
        // The 1.8e16 W reading. The 200 W ceiling exists solely because of it.
        let (w, src) = derive(systemLoadmW: 1.8e19, onAC: true)
        XCTAssertNil(w.value)
        XCTAssertNil(src)
        XCTAssertFalse(w.confidence.isAvailable)
    }

    func testChargingRefusesANumberAndSaysWhy() {
        // SystemLoad goes negative while charging: it becomes net flow INTO the
        // battery, not system load. Treating it as draw was the original bug.
        let (w, src) = derive(systemLoadmW: -25_650, mV: 12_000, mA: 3_000,
                              onAC: true, charging: true)
        XCTAssertNil(w.value)
        XCTAssertNil(src)
        XCTAssertEqual(w.confidence.reason,
                       "charging — SystemLoad reports net battery flow, not system draw")
    }

    func testChargingIsCheckedBeforeVoltageTimesAmperage() {
        // Ordering matters: on a charging machine neither figure is system draw,
        // so V x I must not be reached even when both values are present.
        let (w, _) = derive(mV: 12_000, mA: -3_000, onAC: false, charging: true)
        XCTAssertNil(w.value, "V x I must not be used while charging")
    }

    func testVoltageTimesAmperageOnBatteryDischarge() {
        // 12.0 V x 3.2 A = 38.4 W, from mV x mA / 1e6.
        let (w, src) = derive(mV: 12_000, mA: -3_200)
        XCTAssertEqual(w.value!, 38.4, accuracy: 1e-9)
        XCTAssertEqual(src, "Voltage x InstantAmperage")
    }

    func testPositiveAmperageOnBatteryIsNotTreatedAsDraw() {
        // Discharge is negative. A positive reading is not a draw figure.
        let (w, _) = derive(mV: 12_000, mA: 3_200, onAC: false)
        XCTAssertNil(w.value)
    }

    func testOnACWithNoSystemLoadGivesTheACSpecificReason() {
        let (w, src) = derive(mV: 12_000, mA: 3_000, onAC: true)
        XCTAssertNil(w.value)
        XCTAssertNil(src)
        XCTAssertEqual(w.confidence.reason,
                       "on AC and SystemLoad unavailable — battery amperage reflects charging, not load")
    }

    func testNothingUsableGivesItsOwnDistinctReason() {
        let (w, _) = derive()
        XCTAssertNil(w.value)
        // Distinct from the AC reason: the user should be able to tell "you are
        // plugged in" from "this Mac reported nothing".
        XCTAssertEqual(w.confidence.reason,
                       "AppleSmartBattery reported no usable power telemetry")
    }

    func testEveryUnavailableBranchCarriesADifferentExplanation() {
        let reasons = [
            derive(systemLoadmW: -1, charging: true).0.confidence.reason,
            derive(mV: 12_000, mA: 3_000, onAC: true).0.confidence.reason,
            derive().0.confidence.reason,
        ].compactMap { $0 }
        XCTAssertEqual(Set(reasons).count, 3, "reasons must not be interchangeable")
        XCTAssertTrue(reasons.allSatisfy { !$0.isEmpty })
    }

    func testAZeroSystemLoadIsNotAcceptedAsAMeasurement() {
        // 0 W is not a plausible whole-system draw; it means the key was unset.
        let (w, _) = derive(systemLoadmW: 0, onAC: true)
        XCTAssertNil(w.value)
    }
}
