import Foundation
import IOKit

/// The AppleSMC user client: the only channel that reads die temperatures and
/// the only one that can move a fan.
///
/// Reading is root-free — verified on this machine (Mac14,5, macOS 26, SIP on):
/// 2382 keys enumerated and read as a normal user. Writing is NOT, and that
/// asymmetry is the whole reason `aithermald` exists.
///
/// Two encoding traps are baked into this file:
///
///   * `SMCKeyData_t` is a C struct whose fields are read by the kernel at
///     fixed offsets, and the 4-character key is a NUMBER in host order, not a
///     byte string. Storing it big-endian — the intuitive reading of "four
///     character code" — produced `result = 0x84 (key not found)` for `#KEY`,
///     i.e. a working connection that could not see a single key.
///   * The float payload inside `bytes` is little-endian, while the struct's
///     own key/size fields are host-order. They are the same on arm64, but the
///     two are decoded separately here so the distinction survives a reader.
public final class SMC: @unchecked Sendable {

    /// Fixed byte offsets into the 80-byte `SMCKeyData_t`. Addressed by offset
    /// rather than modelled as a Swift struct on purpose: the layout is the ABI,
    /// and a tuple-based mirror hides it behind Swift's own padding rules.
    private enum Off {
        static let key = 0, dataSize = 28, dataType = 32
        static let result = 40, data8 = 42, data32 = 44, bytes = 48
        static let structSize = 80
    }

    private enum Cmd {
        static let readBytes: UInt8 = 5
        static let writeBytes: UInt8 = 6
        static let readIndex: UInt8 = 8
        static let readKeyInfo: UInt8 = 9
    }

    /// The SMC's own result byte. Only the ones this app can actually provoke
    /// are named; the rest travel as `.other` with the raw code visible.
    public enum Result: Equatable, Sendable {
        case ok
        case keyNotFound            // SMC result 0x84
        /// The kernel refused the call before the SMC ever saw it.
        ///
        /// MEASURED as uid 501: a write returns `kIOReturnNotPrivileged`
        /// (0xE00002C1) from `IOConnectCallStructMethod` itself — NOT an SMC
        /// result byte of 0x85, which is what the folklore says. Reads on the
        /// same connection succeed. That kernel-level boundary is the reason
        /// this project has a privileged helper at all.
        case notPrivileged
        case other(UInt8)
        /// Any other IOKit-level failure, carrying the raw kern_return_t.
        case ioKit(Int32)

        init(_ raw: UInt8) {
            switch raw {
            case 0x00: self = .ok
            case 0x84: self = .keyNotFound
            case 0x85: self = .notPrivileged
            default:   self = .other(raw)
            }
        }

        init(kernReturn kr: kern_return_t) {
            self = (kr == kIOReturnNotPrivileged) ? .notPrivileged : .ioKit(kr)
        }

        public var reason: String {
            switch self {
            case .ok:            return "ok"
            case .keyNotFound:   return "key not found"
            case .notPrivileged: return "not privileged — SMC writes require root"
            case .other(let c):  return String(format: "SMC result 0x%02x", c)
            case .ioKit(let k):  return String(format: "IOKit returned 0x%08X", UInt32(bitPattern: k))
            }
        }
    }

    public struct KeyInfo: Sendable, Equatable {
        public var size: UInt32
        /// Four-character type: `flt `, `ui8 `, `ui16`, `ui32`, `fpe2`, `hex_`.
        public var type: String
    }

    private var conn: io_connect_t = 0
    /// Key info is immutable for the life of a boot, and a needless extra
    /// round trip per sensor per tick doubles the cost of the thermal loop.
    private var infoCache: [String: KeyInfo] = [:]
    private let lock = NSLock()

    public init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS, conn != 0
        else { return nil }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    // MARK: - Key coding

    /// A four-character key as the host-order integer the kernel expects.
    /// Shorter strings are left-packed, which is how the SMC itself pads.
    static func fourCC(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for c in s.utf8.prefix(4) { v = (v << 8) | UInt32(c) }
        return v
    }

    static func string(_ v: UInt32) -> String {
        let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                     UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    // MARK: - Primitives

    private func call(_ input: inout [UInt8]) -> (kern_return_t, [UInt8]) {
        var out = [UInt8](repeating: 0, count: Off.structSize)
        var outSize = Off.structSize
        let kr = input.withUnsafeBytes { ip in
            out.withUnsafeMutableBytes { op in
                IOConnectCallStructMethod(conn, 2, ip.baseAddress, Off.structSize,
                                          op.baseAddress, &outSize)
            }
        }
        return (kr, out)
    }

    private func blank() -> [UInt8] { [UInt8](repeating: 0, count: Off.structSize) }

    public func info(_ key: String) -> KeyInfo? {
        lock.lock(); let cached = infoCache[key]; lock.unlock()
        if let cached { return cached }

        var inBuf = blank()
        inBuf.withUnsafeMutableBytes {
            $0.storeBytes(of: Self.fourCC(key), toByteOffset: Off.key, as: UInt32.self)
            $0.storeBytes(of: Cmd.readKeyInfo, toByteOffset: Off.data8, as: UInt8.self)
        }
        let (kr, out) = call(&inBuf)
        guard kr == KERN_SUCCESS, Result(out[Off.result]) == .ok else { return nil }
        let i = out.withUnsafeBytes { b in
            KeyInfo(size: b.load(fromByteOffset: Off.dataSize, as: UInt32.self),
                    type: Self.string(b.load(fromByteOffset: Off.dataType, as: UInt32.self)))
        }
        lock.lock(); infoCache[key] = i; lock.unlock()
        return i
    }

    /// Raw payload plus the type needed to decode it.
    public func read(_ key: String) -> (bytes: [UInt8], info: KeyInfo)? {
        guard let i = info(key), i.size > 0, i.size <= 32 else { return nil }
        var inBuf = blank()
        inBuf.withUnsafeMutableBytes {
            $0.storeBytes(of: Self.fourCC(key), toByteOffset: Off.key, as: UInt32.self)
            $0.storeBytes(of: i.size, toByteOffset: Off.dataSize, as: UInt32.self)
            $0.storeBytes(of: Cmd.readBytes, toByteOffset: Off.data8, as: UInt8.self)
        }
        let (kr, out) = call(&inBuf)
        guard kr == KERN_SUCCESS, Result(out[Off.result]) == .ok else { return nil }
        return (Array(out[Off.bytes ..< (Off.bytes + Int(i.size))]), i)
    }

    /// The one number-shaped accessor. Returns nil for a key whose type this
    /// app has never seen, rather than guessing a layout.
    public func readNumber(_ key: String) -> Double? {
        guard let r = read(key) else { return nil }
        return Self.decode(r.bytes, type: r.info.type)
    }

    /// Pure so every branch is testable without an SMC.
    ///
    /// `flt ` is little-endian IEEE-754 in the payload; the integer types are
    /// big-endian. That is not a typo and it is not symmetric — it is what the
    /// hardware sends, confirmed against known-good values (F0Mx = 6800 rpm,
    /// F0Md = 0).
    public static func decode(_ b: [UInt8], type: String) -> Double? {
        switch type {
        case "flt ":
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[3]) << 24 | UInt32(b[2]) << 16 | UInt32(b[1]) << 8 | UInt32(b[0])
            let f = Float(bitPattern: bits)
            return f.isFinite ? Double(f) : nil
        case "ui8 ", "flag":
            return b.count >= 1 ? Double(b[0]) : nil
        case "ui16":
            return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) : nil
        case "ui32":
            return b.count >= 4 ? Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16
                                         | UInt32(b[2]) << 8 | UInt32(b[3])) : nil
        case "si8 ":
            return b.count >= 1 ? Double(Int8(bitPattern: b[0])) : nil
        case "si16":
            return b.count >= 2 ? Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) : nil
        // Fixed point, 14 integer bits + 2 fractional. Pre-Apple-Silicon fan
        // encoding; kept because the decoder is shared with older hardware and
        // silently reading it as ui16 would report 4x the real rpm.
        case "fpe2":
            return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4.0 : nil
        default:
            return nil
        }
    }

    public static func encodeFloat(_ v: Double) -> [UInt8] {
        let bits = Float(v).bitPattern
        return [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff),
                UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)]
    }

    public static func encodeUInt8(_ v: UInt8) -> [UInt8] { [v] }

    /// Writes a key. Fails with `.notPrivileged` for a non-root caller, which
    /// is the only reason the privileged helper exists.
    ///
    /// This function applies NO policy of its own — no clamping, no allowlist.
    /// That is deliberate: policy lives in one place (`FanGuard`) where it is
    /// testable, and a second half-copy here would be the thing that disagrees.
    @discardableResult
    public func write(_ key: String, bytes: [UInt8]) -> Result {
        guard let i = info(key) else { return .keyNotFound }
        guard bytes.count == Int(i.size) else { return .other(0xFF) }
        var inBuf = blank()
        inBuf.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: Self.fourCC(key), toByteOffset: Off.key, as: UInt32.self)
            raw.storeBytes(of: i.size, toByteOffset: Off.dataSize, as: UInt32.self)
            raw.storeBytes(of: Cmd.writeBytes, toByteOffset: Off.data8, as: UInt8.self)
            for (n, b) in bytes.enumerated() {
                raw.storeBytes(of: b, toByteOffset: Off.bytes + n, as: UInt8.self)
            }
        }
        let (kr, out) = call(&inBuf)
        guard kr == KERN_SUCCESS else { return Result(kernReturn: kr) }
        return Result(out[Off.result])
    }

    // MARK: - Enumeration

    public func keyCount() -> Int? {
        readNumber("#KEY").map(Int.init)
    }

    public func key(at index: Int) -> String? {
        var inBuf = blank()
        inBuf.withUnsafeMutableBytes {
            $0.storeBytes(of: Cmd.readIndex, toByteOffset: Off.data8, as: UInt8.self)
            $0.storeBytes(of: UInt32(index), toByteOffset: Off.data32, as: UInt32.self)
        }
        let (kr, out) = call(&inBuf)
        guard kr == KERN_SUCCESS, Result(out[Off.result]) == .ok else { return nil }
        return out.withUnsafeBytes {
            Self.string($0.load(fromByteOffset: Off.key, as: UInt32.self))
        }
    }

    /// Every key the SMC admits to. ~2400 of them, so this is a discovery-time
    /// call, never part of a sampling tick.
    public func allKeys() -> [String] {
        guard let n = keyCount() else { return [] }
        return (0..<n).compactMap { key(at: $0) }
    }
}
