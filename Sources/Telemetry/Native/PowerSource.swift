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
        let mA      = (dict["InstantAmperage"] as? NSNumber).map { n -> Double in
            // The key is published as an unsigned 64-bit value; discharge is
            // negative and wraps. Reinterpret rather than reading 1.8e19.
            let u = n.uint64Value
            return u > (UInt64.max / 2) ? -Double(UInt64.max - u + 1) : Double(u)
        }
        let onAC    = (dict["ExternalConnected"] as? Bool) ?? false

        // PowerTelemetryData.SystemLoad is a SIGNED net power figure in mW,
        // published as unsigned. On battery it equals system draw (verified
        // against V x I: 12.581 W vs 12.57 W). While CHARGING it goes negative
        // (observed -25.65 W) because it becomes net flow into the battery, NOT
        // system load. So it is only usable when positive and plausible --
        // treating it as draw on AC was wrong and produced a 1.8e16 W reading.
        let telem = dict["PowerTelemetryData"] as? [String: Any]
        let systemLoadmW = (telem?["SystemLoad"] as? NSNumber).map { n -> Double in
            let u = n.uint64Value
            return u > (UInt64.max / 2) ? -Double(UInt64.max - u + 1) : Double(u)
        }
        let isCharging = (dict["IsCharging"] as? Bool) ?? false
        let accEnergy = (telem?["AccumulatedSystemEnergyConsumed"] as? NSNumber)?.uint64Value
        let cur     = (dict["CurrentCapacity"] as? NSNumber)?.doubleValue
        let max     = (dict["MaxCapacity"] as? NSNumber)?.doubleValue
        let tempRaw = (dict["Temperature"] as? NSNumber)?.doubleValue

        // Detect the ~4 s refresh so the UI can badge a held value.
        let sig = "\(mV ?? -1)|\(mA ?? 0)|\(cur ?? -1)|\(systemLoadmW ?? -1)|\(accEnergy ?? 0)"
        if sig != lastSignature { lastSignature = sig; lastChange = Instant.now() }

        let watts: Estimate<Double>
        var source: String?
        if let mw = systemLoadmW, mw > 0, mw < 200_000 {
            watts = .high(mw / 1000)
            source = "PowerTelemetryData.SystemLoad"
        } else if isCharging {
            watts = .unavailable("charging — SystemLoad reports net battery flow, not system draw")
        } else if !onAC, let v = mV, let a = mA, a < 0 {
            watts = .high(v * -a / 1_000_000)
            source = "Voltage x InstantAmperage"
        } else if onAC {
            watts = .unavailable("on AC and SystemLoad unavailable — battery amperage reflects charging, not load")
        } else {
            watts = .unavailable("AppleSmartBattery reported no usable power telemetry")
        }

        return Stats(
            watts: watts,
            onAC: onAC,
            batteryFraction: (cur != nil && max != nil && max! > 0) ? cur! / max! : nil,
            batteryTempC: tempRaw.map { $0 / 100.0 },
            lastChangedAt: lastChange,
            accumulatedEnergy: accEnergy,
            source: source)
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
