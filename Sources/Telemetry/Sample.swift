import Foundation

// MARK: - Time

/// Monotonic seconds since process start.
///
/// Deliberately NOT `Date`: a wall-clock adjustment mid-session must not warp
/// the timeline. Everything on the shared x-axis is expressed in these.
public struct Instant: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var s: Double
    public init(_ s: Double) { self.s = s }

    private static let epoch = DispatchTime.now().uptimeNanoseconds
    public static func now() -> Instant {
        Instant(Double(DispatchTime.now().uptimeNanoseconds &- epoch) / 1_000_000_000)
    }

    public static func < (a: Instant, b: Instant) -> Bool { a.s < b.s }
    public static func - (a: Instant, b: Instant) -> Double { a.s - b.s }
    public var description: String { String(format: "%.3f", s) }
}

// MARK: - Identity

public enum EngineID: String, Sendable, Hashable, CaseIterable {
    case bionic     // LM Studio rebranded; JIT-spawns a bundled llama-server
    case localai
    case ollama

    public var displayName: String {
        switch self {
        case .bionic:  return "Bionic"
        case .localai: return "LocalAI"
        case .ollama:  return "Ollama"
        }
    }
}

/// Which collector produced a reading. Drives the sample rug and the Hz chips.
public enum SourceKind: String, Sendable, Hashable, CaseIterable {
    case system      // native IOKit/mach, ~10 Hz
    case slots       // llama-server /slots, ~1-2 Hz, serialized behind decode
    case power       // AppleSmartBattery, ~0.25 Hz (underlying refresh is ~4 s)
    case roster      // engine discovery + /props + /api/ps, ~0.2 Hz
}

/// Identifies a specific *run* of a server process.
///
/// Bionic re-spawns llama-server on a new port with a new key; carrying slot
/// counters across that boundary would produce a garbage rate spike, so
/// identity includes the process start time, not just the pid.
public struct EndpointGeneration: Sendable, Hashable {
    public var pid: Int32
    public var startedAt: UInt64      // absolute time of process start
    public var port: UInt16
    public init(pid: Int32, startedAt: UInt64, port: UInt16) {
        self.pid = pid; self.startedAt = startedAt; self.port = port
    }
}

// MARK: - The stream

/// Domain-tagged, never fused.
///
/// The system domain samples at 10 Hz and the inference domain at ~1-2 Hz.
/// A single fused sample type would force a collector to invent values for
/// whichever domain had not produced one — exactly the lie this app exists
/// to avoid. Each case carries its own timestamp.
public enum Sample: Sendable {
    case system(SystemSample)
    case inference(InferenceSample)
    case power(PowerSample)
    case roster(EngineRoster)
    case health(SourceHealth)
}

// MARK: - System domain (~10 Hz)

public enum ThermalState: String, Sendable { case nominal, fair, serious, critical }

/// Discrete kernel pressure level. Rendered as the 3-state enum it is; drawing
/// it as a smooth meter would invent resolution the source does not have.
public enum MemoryPressure: Int, Sendable { case nominal = 1, warning = 2, critical = 4 }

public struct SystemSample: Sendable {
    public var t: Instant

    // GPU — IOAccelerator PerformanceStatistics. nil when the key was absent.
    public var gpuDevice: Double?          // 0...1
    public var gpuRenderer: Double?
    public var gpuTiler: Double?
    public var gpuInUseBytes: UInt64?      // tracks the resident model (~37-39 GiB)
    public var gpuAllocBytes: UInt64?
    public var gpuRecoveryCount: Int       // nonzero = driver reset, invalidates windows

    // Memory — llmctl's formula, file-backed cache deliberately excluded.
    public var memTotal: UInt64
    public var memUsed: UInt64
    public var memWired: UInt64
    public var memCompressed: UInt64
    public var memFileBacked: UInt64       // shown for context, never counted as used
    public var pressure: MemoryPressure

    // Raw cumulative counters — the UI differentiates and detects resets.
    public var compressionsTotal: UInt64
    public var decompressionsTotal: UInt64
    public var pageinsTotal: UInt64

    public var thermal: ThermalState
    public var procs: [ProcSample]

    public init(t: Instant, gpuDevice: Double? = nil, gpuRenderer: Double? = nil,
                gpuTiler: Double? = nil, gpuInUseBytes: UInt64? = nil,
                gpuAllocBytes: UInt64? = nil, gpuRecoveryCount: Int = 0,
                memTotal: UInt64, memUsed: UInt64, memWired: UInt64,
                memCompressed: UInt64, memFileBacked: UInt64,
                pressure: MemoryPressure, compressionsTotal: UInt64 = 0,
                decompressionsTotal: UInt64 = 0, pageinsTotal: UInt64 = 0,
                thermal: ThermalState = .nominal, procs: [ProcSample] = []) {
        self.t = t; self.gpuDevice = gpuDevice; self.gpuRenderer = gpuRenderer
        self.gpuTiler = gpuTiler; self.gpuInUseBytes = gpuInUseBytes
        self.gpuAllocBytes = gpuAllocBytes; self.gpuRecoveryCount = gpuRecoveryCount
        self.memTotal = memTotal; self.memUsed = memUsed; self.memWired = memWired
        self.memCompressed = memCompressed; self.memFileBacked = memFileBacked
        self.pressure = pressure; self.compressionsTotal = compressionsTotal
        self.decompressionsTotal = decompressionsTotal; self.pageinsTotal = pageinsTotal
        self.thermal = thermal; self.procs = procs
    }
}

public struct ProcSample: Sendable, Identifiable {
    public var pid: Int32
    public var startedAt: UInt64
    public var engine: EngineID?
    public var command: String

    /// Fraction of ONE core. Reads ~0.002 during Metal-offloaded generation
    /// because llama.cpp blocks on a command-buffer wait. That is correct,
    /// not a broken reading, and the UI says so.
    public var cpuFraction: Double
    public var cpuNanos: UInt64            // raw cumulative

    public var wired: UInt64               // mlock'd weights, ~= GGUF size
    public var footprint: UInt64           // what the process actually costs
    public var rss: UInt64                 // includes mapped file pages; demoted to hover
    public var diskBytesRead: UInt64       // raw cumulative; spikes on model mmap
    public var energyNanoJoules: UInt64    // raw cumulative, per-process CPU energy

    public var id: Int32 { pid }

    public init(pid: Int32, startedAt: UInt64, engine: EngineID?, command: String,
                cpuFraction: Double, cpuNanos: UInt64, wired: UInt64,
                footprint: UInt64, rss: UInt64, diskBytesRead: UInt64,
                energyNanoJoules: UInt64) {
        self.pid = pid; self.startedAt = startedAt; self.engine = engine
        self.command = command; self.cpuFraction = cpuFraction; self.cpuNanos = cpuNanos
        self.wired = wired; self.footprint = footprint; self.rss = rss
        self.diskBytesRead = diskBytesRead; self.energyNanoJoules = energyNanoJoules
    }
}

// MARK: - Power domain (~0.25 Hz)

public struct PowerSample: Sendable {
    public var t: Instant
    /// When the underlying AppleSmartBattery values last changed.
    /// Distinct from `t` on purpose: the gap is what the "held 2.1 s" badge
    /// renders, and it is the difference between a measurement and a hold.
    public var lastRefreshedAt: Instant

    /// Whole-system watts from Voltage x -InstantAmperage.
    /// `.unavailable` on AC, where amperage reflects charging, not load.
    public var watts: Estimate<Double>
    public var onAC: Bool
    public var batteryFraction: Double?
    /// Battery sensor, NOT SoC die temperature. Labelled as such in the UI.
    public var batteryTempC: Double?

    public init(t: Instant, lastRefreshedAt: Instant, watts: Estimate<Double>,
                onAC: Bool, batteryFraction: Double?, batteryTempC: Double?) {
        self.t = t; self.lastRefreshedAt = lastRefreshedAt; self.watts = watts
        self.onAC = onAC; self.batteryFraction = batteryFraction
        self.batteryTempC = batteryTempC
    }
}

// MARK: - Inference domain (~1-2 Hz)

public enum SlotState: String, Sendable {
    /// Exposes only [id, is_processing, n_ctx, speculative]. Show em-dashes.
    case neverUsed
    /// Exposes counters FROZEN from its last request. Must never render as live.
    case idleWithHistory
    case processing
}

public struct SamplerParams: Sendable, Equatable {
    public var temperature: Double?
    public var topK: Int?
    public var topP: Double?
    public var minP: Double?
    public var typicalP: Double?
    public var repeatPenalty: Double?
    public var repeatLastN: Int?
    public var frequencyPenalty: Double?
    public var presencePenalty: Double?
    public var mirostat: Int?
    public var nPredict: Int?
    public var seed: UInt32?
    public var samplerChain: [String]
    /// Everything else, so the "…30 more" disclosure can be complete.
    public var extra: [String: String]
    public init(temperature: Double? = nil, topK: Int? = nil, topP: Double? = nil,
                minP: Double? = nil, typicalP: Double? = nil, repeatPenalty: Double? = nil,
                repeatLastN: Int? = nil, frequencyPenalty: Double? = nil,
                presencePenalty: Double? = nil, mirostat: Int? = nil,
                nPredict: Int? = nil, seed: UInt32? = nil,
                samplerChain: [String] = [], extra: [String: String] = [:]) {
        self.temperature = temperature; self.topK = topK; self.topP = topP
        self.minP = minP; self.typicalP = typicalP; self.repeatPenalty = repeatPenalty
        self.repeatLastN = repeatLastN; self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty; self.mirostat = mirostat
        self.nPredict = nPredict; self.seed = seed
        self.samplerChain = samplerChain; self.extra = extra
    }
}

/// Context occupancy, with its denominators kept separate and named.
///
/// There is no single honest "% full" here, and pretending otherwise was the
/// first hypothesis this app falsified:
///   * `/slots` and `/props` both report `n_ctx` = the MODEL MAXIMUM (262144).
///   * `--fit-ctx` (16384) is a *target* for llama.cpp's auto-fit, NOT a
///     ceiling — a live slot was observed holding 17460 tokens, i.e. 106% of
///     it, so using it as a denominator yields impossible percentages.
///   * The actually-allocated per-slot window is not exposed by any endpoint.
///
/// So we publish the absolute token count (always true), both ratios with
/// their denominators named, and mark the real window unavailable.
public struct ContextFill: Sendable {
    public var tokens: Int?
    /// --fit-ctx. A fit target. May legitimately be exceeded.
    public var fitTarget: Int?
    /// n_ctx as reported. The model maximum, not the allocation.
    public var modelMaximum: Int
    /// The number the UI would love to show, and cannot.
    public var allocatedWindow: Estimate<Int>

    public var exceededFitTarget: Bool {
        guard let t = tokens, let f = fitTarget else { return false }
        return t > f
    }
    public var fractionOfFitTarget: Double? {
        guard let t = tokens, let f = fitTarget, f > 0 else { return nil }
        return Double(t) / Double(f)
    }
    public var fractionOfModelMaximum: Double? {
        guard let t = tokens, modelMaximum > 0 else { return nil }
        return Double(t) / Double(modelMaximum)
    }

    public init(tokens: Int?, fitTarget: Int?, modelMaximum: Int) {
        self.tokens = tokens
        self.fitTarget = fitTarget
        self.modelMaximum = modelMaximum
        self.allocatedWindow = .unavailable(
            "llama-server exposes no allocated per-slot context: n_ctx is the model maximum and --fit-ctx is a fit target, not a ceiling")
    }
}

public struct SlotSample: Sendable, Identifiable {
    public var id: Int
    /// Classified by the collector. The UI must not re-derive this.
    public var state: SlotState

    /// What /slots reports: the MODEL MAXIMUM (262144), not the launched window.
    public var nCtxReported: Int
    /// From argv --fit-ctx (16384). The denominator that actually matters.
    /// nil means we could not determine it — the UI degrades to .unavailable
    /// rather than silently showing a 16x-wrong percentage.
    public var nCtxFitted: Int?

    public var speculative: Bool
    public var specTypes: String?
    public var idTask: Int?

    // nil means THE FIELD WAS ABSENT. Never substitute 0.
    public var nPromptTokens: Int?           // total context — KEEPS GROWING during decode
    public var nPromptTokensProcessed: Int?  // prefill actually computed — freezes
    public var nPromptTokensCache: Int?      // reused from cache — freezes
    public var nDecoded: Int?                // from next_token[0].n_decoded
    public var nRemain: Int?
    public var hasNextToken: Bool?
    public var sampler: SamplerParams?

    // Derived by SlotStateMachine, which owns the per-slot history.
    public var decodeTokensPerSecond: Estimate<Double>
    public var prefillTokensPerSecond: Estimate<Double>
    public var timeToFirstToken: Estimate<Double>   // carries .interval, not a point
    public var cacheHitRate: Estimate<Double>

    /// Denominators kept separate on purpose — see ContextFill.
    public var context: ContextFill {
        ContextFill(tokens: nPromptTokens, fitTarget: nCtxFitted, modelMaximum: nCtxReported)
    }

    public init(id: Int, state: SlotState, nCtxReported: Int, nCtxFitted: Int?,
                speculative: Bool, specTypes: String? = nil, idTask: Int? = nil,
                nPromptTokens: Int? = nil, nPromptTokensProcessed: Int? = nil,
                nPromptTokensCache: Int? = nil, nDecoded: Int? = nil,
                nRemain: Int? = nil, hasNextToken: Bool? = nil,
                sampler: SamplerParams? = nil,
                decodeTokensPerSecond: Estimate<Double> = .unavailable("no samples yet"),
                prefillTokensPerSecond: Estimate<Double> = .unavailable("no samples yet"),
                timeToFirstToken: Estimate<Double> = .unavailable("no samples yet"),
                cacheHitRate: Estimate<Double> = .unavailable("no samples yet")) {
        self.id = id; self.state = state; self.nCtxReported = nCtxReported
        self.nCtxFitted = nCtxFitted; self.speculative = speculative
        self.specTypes = specTypes; self.idTask = idTask
        self.nPromptTokens = nPromptTokens
        self.nPromptTokensProcessed = nPromptTokensProcessed
        self.nPromptTokensCache = nPromptTokensCache; self.nDecoded = nDecoded
        self.nRemain = nRemain; self.hasNextToken = hasNextToken; self.sampler = sampler
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.timeToFirstToken = timeToFirstToken
        self.cacheHitRate = cacheHitRate
    }
}

public struct InferenceSample: Sendable {
    /// When the poll was ISSUED.
    public var requestedAt: Instant
    /// When the response was PARSED.
    public var t: Instant
    public var engine: EngineID
    public var generation: EndpointGeneration
    public var slots: [SlotSample]
    /// Bodies that needed the control-character repair pass. If the server is
    /// emitting bad JSON, that is itself a fact about the system under study.
    public var malformedRepairs: Int

    /// 100-450 ms in practice. This is a first-class measurement: it is the
    /// server time this app took away from generating.
    public var pollDuration: Double { t - requestedAt }

    public init(requestedAt: Instant, t: Instant, engine: EngineID,
                generation: EndpointGeneration, slots: [SlotSample],
                malformedRepairs: Int = 0) {
        self.requestedAt = requestedAt; self.t = t; self.engine = engine
        self.generation = generation; self.slots = slots
        self.malformedRepairs = malformedRepairs
    }
}

// MARK: - Roster (~0.2 Hz)

public struct RuntimeInfo: Sendable, Identifiable {
    public var engine: EngineID
    public var generation: EndpointGeneration?
    public var endpoint: String            // "127.0.0.1:56388" — never the key
    public var modelName: String?
    public var quantization: String?
    public var paramCount: Int64?
    public var fileBytes: UInt64?
    public var nCtxReported: Int?
    public var nCtxFitted: Int?
    public var totalSlots: Int?
    public var speculativeType: String?
    public var flashAttention: Bool?
    public var loadMode: String?
    public var reachable: Bool
    public var residentBytes: UInt64       // 0 = present but holding nothing
    public var requestsPerMinute: Double?

    public var id: String { engine.rawValue }

    public init(engine: EngineID, generation: EndpointGeneration? = nil,
                endpoint: String, modelName: String? = nil, quantization: String? = nil,
                paramCount: Int64? = nil, fileBytes: UInt64? = nil,
                nCtxReported: Int? = nil, nCtxFitted: Int? = nil,
                totalSlots: Int? = nil, speculativeType: String? = nil,
                flashAttention: Bool? = nil, loadMode: String? = nil,
                reachable: Bool, residentBytes: UInt64 = 0,
                requestsPerMinute: Double? = nil) {
        self.engine = engine; self.generation = generation; self.endpoint = endpoint
        self.modelName = modelName; self.quantization = quantization
        self.paramCount = paramCount; self.fileBytes = fileBytes
        self.nCtxReported = nCtxReported; self.nCtxFitted = nCtxFitted
        self.totalSlots = totalSlots; self.speculativeType = speculativeType
        self.flashAttention = flashAttention; self.loadMode = loadMode
        self.reachable = reachable; self.residentBytes = residentBytes
        self.requestsPerMinute = requestsPerMinute
    }
}

public struct EngineRoster: Sendable {
    public var t: Instant
    public var runtimes: [RuntimeInfo]
    public init(t: Instant, runtimes: [RuntimeInfo]) { self.t = t; self.runtimes = runtimes }
}

// MARK: - Health (every poll attempt, success or failure)

public enum Outcome: Sendable, Equatable {
    case ok
    case timeout
    case refused
    case http(Int)
    case decode(String)
    case other(String)

    public var isOK: Bool { self == .ok }
    public var shortReason: String {
        switch self {
        case .ok:            return "ok"
        case .timeout:       return "timed out"
        case .refused:       return "connection refused"
        case .http(let c):   return "HTTP \(c)"
        case .decode(let m): return "decode: \(m)"
        case .other(let m):  return m
        }
    }
}

/// Emitted on EVERY poll attempt. This single stream powers the sample rug,
/// the measured-Hz chips, the jitter sparkline, the observer-cost figure and
/// the live/held/stale/dark state machine. It is data, not diagnostics.
public struct SourceHealth: Sendable {
    public var source: SourceKind
    public var engine: EngineID?
    public var t: Instant
    public var outcome: Outcome
    public var latency: Double
    /// The measured interval since the previous success — this is what makes
    /// "1.7 Hz ±0.4" a measurement rather than a restatement of the setting.
    public var sincePreviousOK: Double?

    public init(source: SourceKind, engine: EngineID? = nil, t: Instant,
                outcome: Outcome, latency: Double, sincePreviousOK: Double?) {
        self.source = source; self.engine = engine; self.t = t
        self.outcome = outcome; self.latency = latency
        self.sincePreviousOK = sincePreviousOK
    }
}

// MARK: - Self cost

public struct SelfCost: Sendable {
    public var collectorMicrosPerTick: Double
    public var ownCPUFraction: Double
    public var slotPollsLastMinute: Int
    public var serverMillisLastMinute: Double
    public init(collectorMicrosPerTick: Double = 0, ownCPUFraction: Double = 0,
                slotPollsLastMinute: Int = 0, serverMillisLastMinute: Double = 0) {
        self.collectorMicrosPerTick = collectorMicrosPerTick
        self.ownCPUFraction = ownCPUFraction
        self.slotPollsLastMinute = slotPollsLastMinute
        self.serverMillisLastMinute = serverMillisLastMinute
    }
}

// MARK: - Feed

public enum CadenceMode: String, Sendable, CaseIterable {
    case adaptive              // 1 Hz idle -> 10 Hz system, 1 Hz /slots
    case minimumPerturbation   // /slots drops to 0.2 Hz
    case systemOnly            // /slots off entirely; zero server impact
}

public protocol TelemetryFeed: Sendable {
    var samples: AsyncStream<Sample> { get }
    /// The ONLY write the UI performs. Changes THIS APP's polling cadence.
    /// Touches no server state — consistent with observe-only.
    func setCadence(_ mode: CadenceMode) async
    func start() async
    func stop() async
}
