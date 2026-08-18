import Foundation
import Darwin

/// Reads another process's argv via sysctl(KERN_PROCARGS2).
///
/// This is the ONLY reliable way to find Bionic's llama-server: it re-spawns
/// per session on a fresh ephemeral port with a fresh API key, and neither
/// appears in any config file. `~/.lmstudio/.internal/http-server-config.json`
/// says port 1234; the server is actually somewhere else entirely.
public enum ProcArgs {

    public struct Info: Sendable {
        public var executable: String
        public var argv: [String]
    }

    private static let argMax: Int = {
        var v: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &v, &sz, nil, 0) == 0 else { return 1 << 20 }
        return Int(v)
    }()

    /// Reuses one buffer across calls — allocating KERN_ARGMAX (1 MB) per call
    /// would dominate the cost of discovery.
    nonisolated(unsafe) private static var buf = [UInt8](repeating: 0, count: argMax)
    nonisolated(unsafe) private static let lock = NSLock()

    public static func read(_ pid: Int32) -> Info? {
        lock.lock(); defer { lock.unlock() }

        var len = buf.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            sysctl(&mib, 3, raw.baseAddress, &len, nil, 0) == 0
        }
        guard ok, len > MemoryLayout<Int32>.size else { return nil }

        var argc: Int32 = 0
        _ = withUnsafeMutableBytes(of: &argc) { dst in
            buf.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[0..<4]))
            }
        }
        guard argc > 0 else { return nil }

        var i = MemoryLayout<Int32>.size
        func nextCString() -> String? {
            guard i < len else { return nil }
            let start = i
            while i < len && buf[i] != 0 { i += 1 }
            guard i <= len else { return nil }
            let s = String(decoding: buf[start..<i], as: UTF8.self)
            i += 1
            return s
        }

        let exec = nextCString() ?? ""
        // MANDATORY: the kernel pads with NULs between exec_path and argv[0].
        // Without this skip, argv[0] parses as "" and every flag shifts by one.
        while i < len && buf[i] == 0 { i += 1 }

        var argv: [String] = []
        argv.reserveCapacity(Int(argc))
        for _ in 0..<Int(argc) {
            guard let s = nextCString() else { break }
            argv.append(s)
        }
        return Info(executable: exec, argv: argv)
    }
}
