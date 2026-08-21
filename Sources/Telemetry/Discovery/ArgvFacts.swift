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
    public var draftTokens: Int?
    public var promptCacheSize: Int?

    // ---- llama.cpp router mode (Jan 0.8.4+ / llama.cpp b9967+) ----

    /// `--models-preset <ini>`. Its presence is what makes a process a ROUTER
    /// rather than a model server: it holds no weights, exposes no usable
    /// /slots, and spawns one child llama-server per model on demand.
    public var modelsPreset: String?
    /// `--models-max`. How many model instances may be resident at once — the
    /// reason a Jan roster is a list and not a single entry.
    public var modelsMax: Int?
    /// `--alias`. The router's child servers are launched with the model id as
    /// an alias and it is the ONLY place that id appears in argv; the --model
    /// path is a content-addressed `.../<id>/model.gguf`, so the alias is what
    /// the roster and /v1/models agree on.
    public var modelAlias: String?
    /// `--fit off`. Jan sets this deliberately (settings key
    /// `llamacpp_fit_off_v1`), which is what makes --ctx-size exact rather
    /// than a target — see `providesAllocatedContext`.
    public var fitMode: String?
    /// `--cache-ram`, in MiB. -1 means unlimited.
    public var cacheRamMiB: Int?
    /// `--no-cont-batching` negates it. With continuous batching off, the
    /// slots are still N but only one can decode at a time, so a second
    /// concurrent request queues instead of interleaving.
    public var contBatching: Bool?

    /// True for a llama.cpp router process.
    public var isRouter: Bool { modelsPreset != nil || modelsMax != nil }

    /// The per-slot context window, when it can be computed EXACTLY.
    ///
    /// This is the one case where the app can state the allocated window that
    /// `ContextFill` normally has to mark unavailable. It holds only when
    /// auto-fit is off: then `--ctx-size` is the real total allocation and
    /// llama.cpp divides it evenly across `--parallel` slots. VERIFIED against
    /// a live Jan child: `--ctx-size 8192 --parallel 2 --fit off` and /slots
    /// reported `n_ctx: 4096` on both slots, matching the child's own
    /// `n_ctx_slot = 4096` log line. With `--fit on` (the llama.cpp default)
    /// ctx-size is a target the server may not honour, so this stays nil.
    public var allocatedSlotContext: Int? {
        guard fitMode == "off", let c = requestedContext, c > 0 else { return nil }
        let n = parallelSlots ?? 1
        guard n > 0 else { return nil }
        return c / n
    }

    public var modelName: String? {
        modelPath.map { ($0 as NSString).lastPathComponent }
    }

    /// Quantization inferred from the model name, e.g. "Q5_K_M" or "4bit".
    public var quantization: String? {
        guard let n = modelName else { return nil }
        // mlx-lm names carry it as a suffix: ...-Instruct-4bit
        if let m = n.range(of: #"(?<![A-Za-z0-9])\d+bit"#, options: [.regularExpression, .caseInsensitive]) {
            return String(n[m]).lowercased()
        }
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
            case "--models-preset":      f.modelsPreset = value(i)
            case "--models-max":         f.modelsMax = value(i).flatMap(Int.init)
            case "--alias", "-a":        f.modelAlias = value(i)
            case "--fit":                f.fitMode = value(i)
            case "--cache-ram":          f.cacheRamMiB = value(i).flatMap(Int.init)
            case "--cont-batching", "-cb":   f.contBatching = true
            case "--no-cont-batching":       f.contBatching = false
            case "--ctx-size", "-c":     f.requestedContext = value(i).flatMap(Int.init)
            case "--fit-ctx":            f.fittedContext = value(i).flatMap(Int.init)
            case "--parallel", "-np":    f.parallelSlots = value(i).flatMap(Int.init)
            case "--spec-type":          f.speculativeType = value(i)
            // mlx-lm spells speculative decoding differently.
            case "--draft-model":        f.speculativeType = value(i).map { ($0 as NSString).lastPathComponent }
            case "--num-draft-tokens":   f.draftTokens = value(i).flatMap(Int.init)
            case "--decode-concurrency": f.parallelSlots = value(i).flatMap(Int.init)
            case "--prompt-cache-size":  f.promptCacheSize = value(i).flatMap(Int.init)
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
    ///
    /// `env` is consulted because Jan's key is not in argv at all: it mints a
    /// random `LLAMA_API_KEY` per launch and passes it in the environment, and
    /// without it /slots, /props and /metrics all answer 401 — i.e. the entire
    /// inference domain is dark for a running, healthy server.
    public static func apiKey(_ argv: [String], env: [String: String] = [:]) -> String? {
        // llama-server uses --api-key; LocalAI uses --api-keys.
        for flag in ["--api-key", "--api-keys"] {
            if let i = argv.firstIndex(of: flag), i + 1 < argv.count {
                return argv[i + 1]
            }
        }
        // Argv wins: an explicit flag is the operator's intent, while the
        // environment may merely have been inherited.
        for k in ["LLAMA_API_KEY", "LLAMA_ARG_API_KEY"] {
            if let v = env[k], !v.isEmpty { return v }
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
