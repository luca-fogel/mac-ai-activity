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
        let mA      = (dict["InstantAmperage"] as? NSNumber)?.doubleValue
        let onAC    = (dict["ExternalConnected"] as? Bool) ?? false
        let cur     = (dict["CurrentCapacity"] as? NSNumber)?.doubleValue
        let max     = (dict["MaxCapacity"] as? NSNumber)?.doubleValue
        let tempRaw = (dict["Temperature"] as? NSNumber)?.doubleValue

        // Detect the ~4 s refresh so the UI can badge a held value.
        let sig = "\(mV ?? -1)|\(mA ?? 0)|\(cur ?? -1)"
        if sig != lastSignature { lastSignature = sig; lastChange = Instant.now() }

        let watts: Estimate<Double>
        if onAC {
            watts = .unavailable("on AC — battery amperage reflects charging, not load")
        } else if let v = mV, let a = mA, a < 0 {
            // Discharging: amperage is negative. Magnitude is system draw.
            watts = .high(v * -a / 1_000_000)
        } else if mA != nil {
            watts = .unavailable("battery not discharging")
        } else {
            watts = .unavailable("AppleSmartBattery reported no amperage")
        }

        return Stats(
            watts: watts,
            onAC: onAC,
            batteryFraction: (cur != nil && max != nil && max! > 0) ? cur! / max! : nil,
            batteryTempC: tempRaw.map { $0 / 100.0 },
            lastChangedAt: lastChange)
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
