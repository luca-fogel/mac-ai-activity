import Foundation

/// llama-server intermittently emits raw control bytes (< 0x20) inside JSON
/// string literals — reproduced 6/6 times in one observation window, then not
/// again. `JSONDecoder` throws on these, so without this pass the inference
/// domain dies at random and looks like a network fault.
///
/// This is a repair, not a parser: it only escapes control bytes that appear
/// inside string literals, tracking quote/escape state so it cannot corrupt
/// structural whitespace.
public enum LenientJSON {

    public struct Result {
        public var data: Data
        public var repairs: Int
    }

    public static func repair(_ input: Data) -> Result {
        var out = [UInt8]()
        out.reserveCapacity(input.count + 16)
        var inString = false
        var escaped = false
        var repairs = 0

        for b in input {
            if escaped {
                out.append(b); escaped = false; continue
            }
            if inString {
                switch b {
                case 0x5C:                       // backslash
                    out.append(b); escaped = true
                case 0x22:                       // closing quote
                    out.append(b); inString = false
                case 0x00...0x1F:                // the bug
                    repairs += 1
                    switch b {
                    case 0x08: out.append(contentsOf: Array("\\b".utf8))
                    case 0x09: out.append(contentsOf: Array("\\t".utf8))
                    case 0x0A: out.append(contentsOf: Array("\\n".utf8))
                    case 0x0C: out.append(contentsOf: Array("\\f".utf8))
                    case 0x0D: out.append(contentsOf: Array("\\r".utf8))
                    default:
                        out.append(contentsOf: Array(String(format: "\\u%04x", Int(b)).utf8))
                    }
                default:
                    out.append(b)
                }
            } else {
                if b == 0x22 { inString = true }
                out.append(b)
            }
        }
        return Result(data: Data(out), repairs: repairs)
    }
}
