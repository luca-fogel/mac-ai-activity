import Foundation
import Darwin

/// Per-process sampling via libproc.
///
/// Everything here works unprivileged for same-uid targets — including the
/// 37 GB llama-server owned by another login session. It returns EPERM for
/// other users' and system daemons' pids, so the scan filters by uid first:
/// that both avoids error noise and cuts the scan cost.
public enum ProcSampler {

    /// Cheap identity from the all-pids scan. No start time: getting one costs
    /// a second syscall, so it is fetched only for pids we actually care about.
    public struct Brief: Sendable {
        public var pid: Int32
        public var comm: String        // truncated to 16 chars by the kernel
        public var uid: uid_t
    }

    /// ~18 us for the list + ~1.2 ms for 774 short-info calls. 1 Hz, not 10.
    public static func scan() -> [Brief] {
        let cap = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard cap > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(cap) / MemoryLayout<pid_t>.size + 16)
        let n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                              Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        let count = Int(n) / MemoryLayout<pid_t>.size
        let me = getuid()

        var out: [Brief] = []
        out.reserveCapacity(16)
        var bsi = proc_bsdshortinfo()
        let sz = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        for i in 0..<count where pids[i] > 0 {
            guard proc_pidinfo(pids[i], PROC_PIDT_SHORTBSDINFO, 0, &bsi, sz) == sz else { continue }
            guard bsi.pbsi_uid == me else { continue }   // skip what we cannot read anyway
            let comm = withUnsafeBytes(of: &bsi.pbsi_comm) { raw -> String in
                let b = raw.bindMemory(to: CChar.self)
                return String(cString: b.baseAddress!)
            }
            out.append(Brief(pid: pids[i], comm: comm, uid: bsi.pbsi_uid))
        }
        return out
    }

    /// Process start time, used with the pid to form a reuse-safe identity.
    public static func startedAt(_ pid: Int32) -> UInt64? {
        var bi = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sz) == sz else { return nil }
        return UInt64(bi.pbi_start_tvsec) * 1_000_000 + UInt64(bi.pbi_start_tvusec)
    }

    /// Cheap enough for 10 Hz over a handful of tracked pids.
    public static func taskInfo(_ pid: Int32) -> proc_taskinfo? {
        var ti = proc_taskinfo()
        let sz = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sz) == sz else { return nil }
        return ti
    }

    /// Richer, 1 Hz. V6 is `rusage_info_current` on this SDK and is the only
    /// flavor carrying ri_energy_nj (per-process CPU energy, unprivileged).
    public static func rusage(_ pid: Int32) -> rusage_info_v6? {
        var ri = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &ri) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return rc == 0 ? ri : nil
    }
}
