import Foundation
import IOKit
import IOKit.ps

/// Whole-system power, root-free, from AppleSmartBattery.
///
/// `powermetrics` needs sudo, but Voltage x -InstantAmperage off the battery
/// controller does not — and it is the whole-system draw, which is what
/// joules-per-token needs.
///
/// Two honesty constraints are baked in:
///   * The underlying values refresh only every ~4 s. `lastRefreshedAt` is
///     reported separately from the sample time so the UI can render a held
///     value as held rather than drawing a fake-smooth line.
///   * On AC, amperage reflects CHARGING current, not system load, so V x I is
///     meaningless. We return .unavailable with the reason rather than a number.
public final class PowerSource: @unchecked Sendable {

    public struct Stats: Sendable {
        public var watts: Estimate<Double>
        public var onAC: Bool
        public var batteryFraction: Double?
        public var batteryTempC: Double?
        public var lastChangedAt: Instant
        /// Monotonic energy accumulator (raw units). Differencing this gives a
        /// true integral over an interval, which beats sampling a slow-refresh
        /// wattage and multiplying by dt.
        public var accumulatedEnergy: UInt64?
        /// How the wattage was obtained, so the UI can be specific.
        public var source: String?
    }

    private var service: io_service_t = 0
    private var lastSignature: String = ""
    private var lastChange = Instant.now()

    public init() { open() }
    deinit { if service != 0 { IOObjectRelease(service) } }

    private func open() {
        if service != 0 { IOObjectRelease(service); service = 0 }
        service = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("AppleSmartBattery"))
    }

    public func sample() -> Stats? {
        guard service != 0 else { open(); return nil }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
                == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            open(); return nil
        }

        let mV      = (dict["Voltage"] as? NSNumber)?.doubleValue
        let mA      = (dict["InstantAmperage"] as? NSNumber)
            .map { Self.signedFromUnsigned($0.uint64Value) }
        let onAC    = (dict["ExternalConnected"] as? Bool) ?? false

        // PowerTelemetryData.SystemLoad is a SIGNED net power figure in mW,
        // published as unsigned. On battery it equals system draw (verified
        // against V x I: 12.581 W vs 12.57 W). While CHARGING it goes negative
        // (observed -25.65 W) because it becomes net flow into the battery, NOT
        // system load. So it is only usable when positive and plausible --
        // treating it as draw on AC was wrong and produced a 1.8e16 W reading.
        let telem = dict["PowerTelemetryData"] as? [String: Any]
        let systemLoadmW = (telem?["SystemLoad"] as? NSNumber)
            .map { Self.signedFromUnsigned($0.uint64Value) }
        let isCharging = (dict["IsCharging"] as? Bool) ?? false
        let accEnergy = (telem?["AccumulatedSystemEnergyConsumed"] as? NSNumber)?.uint64Value
        let cur     = (dict["CurrentCapacity"] as? NSNumber)?.doubleValue
        let max     = (dict["MaxCapacity"] as? NSNumber)?.doubleValue
        let tempRaw = (dict["Temperature"] as? NSNumber)?.doubleValue

        // Detect the ~4 s refresh so the UI can badge a held value.
        let sig = "\(mV ?? -1)|\(mA ?? 0)|\(cur ?? -1)|\(systemLoadmW ?? -1)|\(accEnergy ?? 0)"
        if sig != lastSignature { lastSignature = sig; lastChange = Instant.now() }

        let (watts, source) = Self.deriveWatts(systemLoadmW: systemLoadmW,
                                               milliVolts: mV,
                                               milliAmps: mA,
                                               onAC: onAC,
                                               isCharging: isCharging)

        return Stats(
            watts: watts,
            onAC: onAC,
            batteryFraction: (cur != nil && max != nil && max! > 0) ? cur! / max! : nil,
            batteryTempC: tempRaw.map { $0 / 100.0 },
            lastChangedAt: lastChange,
            accumulatedEnergy: accEnergy,
            source: source)
    }

    /// Reinterprets an IOKit value that is SIGNED but published as unsigned.
    ///
    /// Both `InstantAmperage` and `PowerTelemetryData.SystemLoad` do this.
    /// Reading them naively yields 1.8e19 instead of a small negative number,
    /// which is how a 1.8e16 W reading once reached the screen. Extracted from
    /// `sample()` so the boundary behaviour is testable without IOKit.
    static func signedFromUnsigned(_ u: UInt64) -> Double {
        // The midpoint split is the two's-complement sign bit. `UInt64.max - u`
        // cannot overflow inside this branch, and the `+ 1` is safe because
        // u == 0 is excluded by the comparison.
        u > (UInt64.max / 2) ? -Double(UInt64.max - u + 1) : Double(u)
    }

    /// The four-way cascade, pure so every branch can be exercised.
    ///
    /// Order matters and is not arbitrary: SystemLoad is preferred when it is
    /// positive and plausible, charging is checked BEFORE V x I because on a
    /// charging machine neither figure means system draw, and the two remaining
    /// branches exist to give a specific reason rather than a shared one.
    static func deriveWatts(systemLoadmW: Double?,
                            milliVolts: Double?,
                            milliAmps: Double?,
                            onAC: Bool,
                            isCharging: Bool) -> (Estimate<Double>, String?) {
        // 200 W ceiling: a plausibility bound, not a spec. It exists because a
        // misread of this key produced 1.8e16 W.
        if let mw = systemLoadmW, mw > 0, mw < 200_000 {
            return (.high(mw / 1000), "PowerTelemetryData.SystemLoad")
        }
        if isCharging {
            return (.unavailable("charging — SystemLoad reports net battery flow, not system draw"), nil)
        }
        if !onAC, let v = milliVolts, let a = milliAmps, a < 0 {
            return (.high(v * -a / 1_000_000), "Voltage x InstantAmperage")
        }
        if onAC {
            return (.unavailable("on AC and SystemLoad unavailable — battery amperage reflects charging, not load"), nil)
        }
        return (.unavailable("AppleSmartBattery reported no usable power telemetry"), nil)
    }

    /// Cheaper and more authoritative than parsing the battery dict for AC.
    public static func isOnAC() -> Bool {
        guard let t = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue()
        else { return true }
        return (t as String) != kIOPSBatteryPowerValue
    }

    public static func thermalState() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}
