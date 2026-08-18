import Foundation

/// Facts extracted from an inference server's command line.
///
/// `effectiveContext` is load-bearing, not decoration: /slots reports the model
/// maximum (262144) while the server was launched with --fit-ctx 16384. Using
/// the reported value as the context-fill denominator understates fill by 16x —
/// showing 6% while the session is minutes from a context shift.
public struct ArgvFacts: Sendable, Equatable {
    public var modelPath: String?
    public var requestedContext: Int?      // -c / --ctx-size
    public var fittedContext: Int?         // --fit-ctx  <- the real denominator
    public var parallelSlots: Int?
    public var speculativeType: String?
    public var flashAttention: Bool?
    public var loadMode: String?
    public var threads: Int?
    public var host: String?
    public var port: UInt16?

    public var modelName: String? {
        modelPath.map { ($0 as NSString).lastPathComponent }
    }

    /// Quantization inferred from the GGUF filename, e.g. "Q5_K_M".
    public var quantization: String? {
        guard let n = modelName else { return nil }
        let stem = (n as NSString).deletingPathExtension
        for part in stem.split(separator: "-").reversed() {
            let p = String(part)
            if p.range(of: #"^(Q\d+|IQ\d+|BF16|F16|F32)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return p.uppercased()
            }
        }
        return nil
    }

    public init() {}

    /// llama-server style: `--flag value`, plus a few bare booleans.
    public static func parse(_ argv: [String]) -> ArgvFacts {
        var f = ArgvFacts()
        var i = 0
        func value(_ at: Int) -> String? {
            let j = at + 1
            guard j < argv.count, !argv[j].hasPrefix("--") else { return nil }
            return argv[j]
        }
        while i < argv.count {
            let a = argv[i]
            switch a {
            case "--model", "-m":        f.modelPath = value(i)
            case "--ctx-size", "-c":     f.requestedContext = value(i).flatMap(Int.init)
            case "--fit-ctx":            f.fittedContext = value(i).flatMap(Int.init)
            case "--parallel", "-np":    f.parallelSlots = value(i).flatMap(Int.init)
            case "--spec-type":          f.speculativeType = value(i)
            case "--load-mode":          f.loadMode = value(i)
            case "--threads", "-t":      f.threads = value(i).flatMap(Int.init)
            case "--host":               f.host = value(i)
            case "--port":               f.port = value(i).flatMap(UInt16.init)
            case "--flash-attn", "-fa":
                // may be bare or take on/off
                f.flashAttention = (value(i).map { $0 != "off" && $0 != "0" }) ?? true
            default: break
            }
            i += 1
        }
        return f
    }

    /// Secrets live here and NOWHERE else. Never copied into a Sample, never
    /// rendered, never logged.
    public static func apiKey(_ argv: [String]) -> String? {
        // llama-server uses --api-key; LocalAI uses --api-keys.
        for flag in ["--api-key", "--api-keys"] {
            if let i = argv.firstIndex(of: flag), i + 1 < argv.count {
                return argv[i + 1]
            }
        }
        return nil
    }
}

/// An API key that cannot be printed by accident.
public struct APIKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var headerValue: String { "Bearer \(raw)" }
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
}
