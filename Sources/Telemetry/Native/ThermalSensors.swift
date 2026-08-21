import Foundation
import IOKit
import IOKit.pwr_mgt

/// Die temperatures and fans, read root-free from the SMC.
///
/// ## Why there is a key map at all
///
/// Neither of the two available paths labels a sensor. `IOHIDEventSystemClient`
/// (the private path other tools use) does return NAMES on this machine, but
/// they are PMU-level — `tdie0` … `tdie10`, `TP0s`, `tcal` — with nothing
/// saying which belong to the GPU. The SMC's own keyspace is unnamed by
/// definition. So the CPU/GPU split had to be MEASURED, not assumed.
///
/// ## How this map was established (Mac14,5, M2 Max, 2026-08-20)
///
/// Three 30–60 s phases — idle, 12-way CPU burn, saturated MLX matmul — with
/// every `flt` key in the `T*` space sampled at 0.5 Hz. Response per prefix:
///
/// | prefix | idle | CPU load | GPU load | verdict |
/// |---|---|---|---|---|
/// | `Tp` (54) | 46–75 | **+40 … +52** | −38 … −10 | CPU performance cores |
/// | `Te` (3)  | 67–76 | +16      | +7.5     | CPU efficiency cores |
/// | `Tg` (16) | 63–71 | +13      | **+17.5** | GPU |
/// | `TB` (3)  | 36    | flat     | flat     | battery pack |
///
/// The `Tp` sign flip is the strongest evidence in the table: those sensors go
/// DOWN by up to 38 °C when the load moves to the GPU, which no shared-die
/// artefact would do.
///
/// ## Prefixes deliberately excluded
///
/// `Tf` (47 keys) responds to both loads and looks tempting, but `Tf06` reads
/// **115 °C at idle** and `Tf00` reads **0.07** — whatever those are, they are
/// not die temperatures, and a group max would be dominated by them forever.
/// `TR`/`Th`/`Ts`/`TP` (67 keys) are plausible and load-responsive but
/// unattributable, so they are visible in the inspector and never in a headline.
public final class ThermalSensors: @unchecked Sendable {

    /// Below this, a die sensor is reporting a POWER-GATED cluster, not a cold
    /// one. MEASURED: `Tp0g` read 113.3 °C during the CPU burn and 23.3 °C
    /// sixty seconds later during the GPU burn, while the GPU sensors sat at
    /// 82 °C. Publishing 23 °C as "CPU temperature" during GPU-bound inference
    /// — which is exactly what local inference IS — would be the same class of
    /// error as rendering a missing measurement as zero.
    public static let parkedFloorC = 25.0
    /// Above this a `flt` reading is not a temperature. 110 °C is already past
    /// anything Apple ships; the bound exists because `Tf06` reads 115.
    public static let plausibleCeilingC = 112.0

    private let smc: SMC
    /// Discovered once. Enumerating 2382 keys costs ~40 ms and the keyspace
    /// cannot change without a reboot, so it must never happen in a tick.
    private var groupKeys: [ThermalDomain: [String]] = [:]
    private var unattributedKeys: [String] = []
    private var fanCount = 0
    private var lastPressure: ThermalState = .nominal
    private var pressureSince = Instant.now()

    public init?(smc: SMC? = nil) {
        guard let s = smc ?? SMC() else { return nil }
        self.smc = s
        discover()
        guard !groupKeys.isEmpty else { return nil }
    }

    private func discover() {
        let all = smc.allKeys()
        for domain in ThermalDomain.allCases {
            let keys = all.filter { k in
                domain.keyPrefixes.contains(where: { k.hasPrefix($0) })
                    && smc.info(k)?.type == "flt "
            }
            // Existence is a property of the KEYSPACE, so nothing here is
            // filtered on what a sensor happens to be reporting right now.
            //
            // MEASURED, twice: filtering on a plausible value at discovery
            // found 45 CPU sensors with the P-cluster warm and 36 a minute
            // later with it gated; relaxing that to "any value >= 0" still
            // found only 36, because a gated sensor does not read 0 — the read
            // FAILS. Either way the process silently lost 18 of 54 sensors for
            // its whole life, and the hotspot it reported was the hottest of
            // whatever it happened to find at launch. Discovery decides what
            // EXISTS; the per-tick classification decides what a reading means.
            groupKeys[domain] = keys.sorted()
        }
        unattributedKeys = all.filter { k in
            k.hasPrefix("T") && smc.info(k)?.type == "flt "
                && !ThermalDomain.allCases.contains(where: { d in
                    d.keyPrefixes.contains(where: { k.hasPrefix($0) }) })
        }.sorted()
        fanCount = smc.readNumber("FNum").map { Int($0) } ?? 0
    }

    /// One tick. Cost is measured and published — this app charges itself rent.
    public func sample(at t: Instant = Instant.now()) -> ThermalSample {
        let t0 = DispatchTime.now().uptimeNanoseconds

        var groups: [SensorGroup] = []
        for domain in ThermalDomain.allCases {
            guard let keys = groupKeys[domain], !keys.isEmpty else { continue }
            var live: [(String, Double)] = []
            var parked: [(String, Double)] = []
            for k in keys {
                guard let v = smc.readNumber(k), v > 0, v < Self.plausibleCeilingC
                else { continue }
                if v < Self.parkedFloorC { parked.append((k, v)) } else { live.append((k, v)) }
            }
            groups.append(SensorGroup(domain: domain, live: live, parked: parked))
        }

        let fans = (0..<fanCount).map { readFan($0) }
        let pressure = PowerSource.thermalState()
        if pressure != lastPressure { lastPressure = pressure; pressureSince = t }

        let micros = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000

        return ThermalSample(
            t: t,
            groups: groups,
            fans: fans,
            pressure: pressure,
            pressureSince: pressureSince,
            speedLimit: Self.cpuSpeedLimit(),
            sampleCostMicros: micros,
            sensorsRead: groups.reduce(0) { $0 + $1.live.count + $1.parked.count })
    }

    /// Fan `n`, as the SMC describes it. `F<n>Md` is the mode byte: 0 = the
    /// SMC's own control loop, 1 = whatever was last written to `F<n>Tg`.
    private func readFan(_ n: Int) -> FanSample {
        let mode = smc.readNumber("F\(n)Md")
        return FanSample(
            index: n,
            actualRPM: smc.readNumber("F\(n)Ac"),
            targetRPM: smc.readNumber("F\(n)Tg"),
            minRPM: smc.readNumber("F\(n)Mn"),
            maxRPM: smc.readNumber("F\(n)Mx"),
            mode: mode.map { $0 >= 0.5 ? FanMode.forced : .auto } ?? .unknown)
    }

    /// Every plausible unattributed sensor, for the Sources inspector.
    /// Off the sampling path: this is a click, not a tick.
    public func unattributed() -> [(key: String, celsius: Double)] {
        unattributedKeys.compactMap { k in
            guard let v = smc.readNumber(k), v > Self.parkedFloorC,
                  v < Self.plausibleCeilingC else { return nil }
            return (k, v)
        }
    }

    public var discoveredCounts: [ThermalDomain: Int] {
        groupKeys.mapValues { $0.count }
    }

    /// The OS's own throttle figure — and on this hardware, its absence.
    ///
    /// MEASURED: `pmset -g therm` reports "No CPU power status has been
    /// recorded" and `IOPMCopyCPUPowerStatus` returns `kIOReturnNotFound` on
    /// Apple Silicon; the Intel-era `CPU_Speed_Limit` key does not exist. So
    /// this is published `.unavailable` with the reason, and the app leans on
    /// thermal PRESSURE, which is real, instead of inventing a percentage.
    static func cpuSpeedLimit() -> Estimate<Double> {
        var dict: Unmanaged<CFDictionary>?
        let kr = IOPMCopyCPUPowerStatus(&dict)
        guard kr == kIOReturnSuccess,
              let d = dict?.takeRetainedValue() as? [String: Any],
              let limit = (d["CPU_Speed_Limit"] as? NSNumber)?.doubleValue
        else {
            return .unavailable("Apple Silicon publishes no CPU_Speed_Limit — IOPMCopyCPUPowerStatus returns kIOReturnNotFound")
        }
        return .high(limit / 100)
    }
}
