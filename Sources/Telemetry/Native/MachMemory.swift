import Foundation
import Darwin

/// System memory, using the formula from `llmctl` (an earlier CLI of mine).
///
/// The correction that matters: file-backed page cache is NOT counted as used.
/// A 20-46 GB GGUF sitting in the page cache is reclaimable, and counting it
/// would make every loaded model look like memory pressure. `llmctl`'s
/// `sysmem()` encodes this and we preserve its semantics exactly.
public enum MachMemory {

    public static let pageSize: UInt64 = {
        var s: vm_size_t = 0
        host_page_size(mach_host_self(), &s)
        return UInt64(s)
    }()

    public static let physical: UInt64 = {
        var v: UInt64 = 0
        var sz = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &v, &sz, nil, 0)
        return v
    }()

    public struct Stats: Sendable {
        public var total, used, available, wired, compressed, fileBacked, anonymous: UInt64
        public var compressions, decompressions, pageins: UInt64
        public var pressure: MemoryPressure
    }

    /// ~1.4 us measured. Safe at 10 Hz.
    public static func sample() -> Stats? {
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var st = vm_statistics64_data_t()
        let kr = withUnsafeMutablePointer(to: &st) { p -> kern_return_t in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let ps = pageSize
        let anon     = UInt64(st.internal_page_count)   * ps
        let purge    = UInt64(st.purgeable_count)       * ps
        let wired    = UInt64(st.wire_count)            * ps
        let comp     = UInt64(st.compressor_page_count) * ps
        let external = UInt64(st.external_page_count)   * ps

        // llmctl's formula. Note the saturating subtract: purgeable can
        // momentarily exceed anonymous between the two field reads.
        let used = min(physical, (anon &- min(anon, purge)) &+ wired &+ comp)

        var lvl: Int32 = 0
        var lsz = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &lvl, &lsz, nil, 0)

        return Stats(
            total: physical, used: used, available: physical &- min(physical, used),
            wired: wired, compressed: comp, fileBacked: external, anonymous: anon,
            compressions: st.compressions, decompressions: st.decompressions,
            pageins: st.pageins,
            pressure: MemoryPressure(rawValue: Int(lvl)) ?? .nominal)
    }
}
