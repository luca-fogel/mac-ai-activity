import Foundation
import IOKit

/// GPU stats from IOAccelerator (AGXAcceleratorG14X on M2 Max), unprivileged.
///
/// Two decisions carry the whole 10 Hz budget:
///   1. Cache the io_service_t for the process lifetime. Re-matching per tick
///      is the dominant cost.
///   2. Read ONLY the "PerformanceStatistics" key. Serialising the whole
///      property dict drags in SurfaceList / IOReportLegend and costs 3.3-4.4 ms
///      instead of ~212 us. Shelling `ioreg` costs ~22 ms — 100x worse.
public final class GPUAccelerator: @unchecked Sendable {

    public struct Stats: Sendable {
        public var device: Double?         // 0...1
        public var renderer: Double?
        public var tiler: Double?
        public var inUseBytes: UInt64?     // tracks the resident model
        public var allocBytes: UInt64?
        public var recoveryCount: Int      // nonzero = driver reset
    }

    private var service: io_service_t = 0

    public init() { open() }
    deinit { if service != 0 { IOObjectRelease(service) } }

    private func open() {
        if service != 0 { IOObjectRelease(service); service = 0 }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        service = IOIteratorNext(it)
    }

    public func sample() -> Stats? {
        guard service != 0 else { open(); return nil }
        guard let cf = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
              let ps = cf.takeRetainedValue() as? [String: Any] else {
            open()   // the accelerator may have been re-registered; re-match once
            return nil
        }
        func pct(_ k: String) -> Double? {
            guard let v = ps[k] as? Int else { return nil }
            return Double(v) / 100.0
        }
        return Stats(
            device: pct("Device Utilization %"),
            renderer: pct("Renderer Utilization %"),
            tiler: pct("Tiler Utilization %"),
            inUseBytes: (ps["In use system memory"] as? NSNumber)?.uint64Value,
            allocBytes: (ps["Alloc system memory"] as? NSNumber)?.uint64Value,
            recoveryCount: (ps["recoveryCount"] as? Int) ?? 0)
    }
}
