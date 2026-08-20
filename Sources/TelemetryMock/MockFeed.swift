import Foundation
import Telemetry

/// A scripted feed so the entire UI can be built and design-reviewed before
/// any collector exists — and so the awkward states (a dark source, a stale
/// slot, an mmap spike, a stalled slot) are reachable on demand instead of
/// only when the real system happens to produce them.
public final class MockFeed: TelemetryFeed, @unchecked Sendable {

    public nonisolated let samples: AsyncStream<Sample>
    private let cont: AsyncStream<Sample>.Continuation
    private var task: Task<Void, Never>?

    public init() {
        var c: AsyncStream<Sample>.Continuation!
        self.samples = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { c = $0 }
        self.cont = c
    }

    public func setCadence(_ mode: CadenceMode) async {}
    public func stop() async { task?.cancel(); cont.finish() }

    public func start() async {
        guard task == nil else { return }
        task = Task.detached { [cont] in
            let t0 = Instant.now()
            var machineTokens = 0
            var idTask = 4_471
            var phaseStart = 0.0
            var i = 0

            while !Task.isCancelled {
                let t = Instant.now()
                let el = t - t0
                // 40 s cycle: 6 s idle, 3 s prefill, 31 s decode.
                let cyc = (el - phaseStart).truncatingRemainder(dividingBy: 40)
                let generating = cyc > 6
                let prefilling = cyc > 6 && cyc < 9
                if cyc < 0.15 { idTask += 1; machineTokens = 0 }

                let gpu = generating ? (prefilling ? 0.99 : 0.86 + 0.12 * sin(el * 3)) : 0.02
                if generating && !prefilling { machineTokens += Int.random(in: 3...6) }

                cont.yield(.system(SystemSample(
                    t: t, gpuDevice: gpu, gpuRenderer: gpu, gpuTiler: gpu * 0.98,
                    gpuInUseBytes: generating ? 40_335_720_448 : 8_000_000_000,
                    gpuAllocBytes: 53_602_697_216, gpuRecoveryCount: 0,
                    memTotal: 68_719_476_736,
                    memUsed: UInt64(58_000_000_000 + Int(2e9 * sin(el))),
                    memWired: 44_300_000_000, memCompressed: 11_600_000_000,
                    memFileBacked: 4_400_000_000,
                    pressure: .warning,
                    compressionsTotal: UInt64(7_800_000 + i * 40),
                    decompressionsTotal: UInt64(3_100_000 + i * 12),
                    pageinsTotal: UInt64(900_000 + i),
                    thermal: generating ? .fair : .nominal,
                    procs: [ProcSample(
                        pid: 49_152, startedAt: 1, engine: .bionic, command: "llama-server",
                        cpuFraction: generating ? 0.003 : 0.0005, cpuNanos: UInt64(i) * 3_000_000,
                        wired: 19_800_000_000, footprint: 23_000_000_000,
                        rss: 40_500_000_000,
                        diskBytesRead: el < 4 ? UInt64(el * 5e9) : 19_800_000_000,
                        energyNanoJoules: UInt64(i) * 80_000_000)])))

                if i % 10 == 0 {
                    cont.yield(.health(SourceHealth(source: .system, t: t, outcome: .ok,
                                                    latency: 0.00003, sincePreviousOK: 0.1)))
                    let slot = SlotSample(
                        id: 1, state: generating ? .processing : .idleWithHistory,
                        nCtxReported: 262_144, nCtxFitted: 16_384,
                        speculative: true, specTypes: "none,draft-mtp", idTask: idTask,
                        nPromptTokens: 14_699 + machineTokens,
                        nPromptTokensProcessed: 1_872, nPromptTokensCache: 12_642,
                        nDecoded: machineTokens, nRemain: -1, hasNextToken: generating,
                        sampler: SamplerParams(temperature: 0.1, topK: 40, topP: 0.95,
                                               minP: 0.05, repeatPenalty: 1.1,
                                               nPredict: -1, seed: 4_294_967_295,
                                               samplerChain: ["penalties", "top_k", "top_p", "min_p", "temp"]),
                        decodeTokensPerSecond: generating && !prefilling
                            ? .init(value: 41 + 4 * sin(el * 2), uncertainty: 2.4,
                                    sampleCount: 9, confidence: .high)
                            : .unavailable("slot is not generating"),
                        prefillTokensPerSecond: generating ? .low(680, n: 2)
                            : .unavailable("prefill not observed"),
                        timeToFirstToken: generating
                            ? .bounded(Interval(lo: 1.2, hi: 2.2))
                            : .unavailable("no first token observed"),
                        cacheHitRate: .high(12_642.0 / 14_514.0))
                    let never = SlotSample(id: 0, state: .neverUsed, nCtxReported: 262_144,
                                           nCtxFitted: 16_384, speculative: true)
                    let stale = SlotSample(
                        id: 2, state: .idleWithHistory, nCtxReported: 262_144,
                        nCtxFitted: 16_384, speculative: true, idTask: 206,
                        nPromptTokens: 9_204, nPromptTokensProcessed: 400,
                        nPromptTokensCache: 8_804, nDecoded: 17)
                    let over = SlotSample(
                        id: 3, state: .idleWithHistory, nCtxReported: 262_144,
                        nCtxFitted: 16_384, speculative: true, idTask: 1_984,
                        nPromptTokens: 17_460, nPromptTokensProcessed: 2_100,
                        nPromptTokensCache: 15_360, nDecoded: 1_474)
                    cont.yield(.inference(InferenceSample(
                        requestedAt: Instant(t.s - 0.21), t: t, engine: .bionic,
                        generation: EndpointGeneration(pid: 49_152, startedAt: 1, port: 56_388),
                        slots: [never, slot, stale, over])))
                    cont.yield(.health(SourceHealth(source: .slots, engine: .bionic, t: t,
                                                    outcome: .ok, latency: 0.21,
                                                    sincePreviousOK: 1.0)))
                    // A deliberately dark source, so the UI's dark state is reachable.
                    cont.yield(.health(SourceHealth(source: .roster, engine: .localai, t: t,
                                                    outcome: .refused, latency: 0.001,
                                                    sincePreviousOK: nil)))
                }

                if i % 40 == 0 {
                    cont.yield(.power(PowerSample(
                        t: t, lastRefreshedAt: Instant(t.s - Double(i % 40) * 0.1),
                        watts: .high(generating ? 51.2 : 14.3), onAC: false,
                        batteryFraction: 0.19, batteryTempC: 31.2)))
                    cont.yield(.roster(EngineRoster(t: t, runtimes: [
                        RuntimeInfo(engine: .bionic,
                                    generation: EndpointGeneration(pid: 49_152, startedAt: 1, port: 56_388),
                                    endpoint: "127.0.0.1:56388",
                                    modelName: "Qwen3.8-27B-Q5_K_M.gguf", quantization: "Q5_K_M",
                                    paramCount: 27_320_697_856, fileBytes: 19_823_058_944,
                                    nCtxReported: 262_144, nCtxFitted: 16_384, totalSlots: 4,
                                    speculativeType: "draft-mtp", flashAttention: true,
                                    loadMode: "mmap+mlock", reachable: true,
                                    residentBytes: 19_800_000_000),
                        RuntimeInfo(engine: .localai, endpoint: "127.0.0.1:8080",
                                    reachable: false, residentBytes: 0),
                        RuntimeInfo(engine: .ollama, endpoint: "127.0.0.1:11434",
                                    modelName: "nomic-embed-text", reachable: true,
                                    residentBytes: 0),
                        // The embedded MLX backend: resident and working, with no
                        // per-token channel. Exercises the absent-with-a-reason
                        // path that used to render as a red error.
                        RuntimeInfo(engine: .bionic, backend: "MLX (embedded)",
                                    busy: generating,
                                    exposesTokenTelemetry: false,
                                    telemetryGap: "no per-token telemetry — per-prediction stats only, via lms log stream",
                                    endpoint: "Bionic IPC (no HTTP port)",
                                    modelName: "qwen/qwen3.8-27b",
                                    quantization: "4bit",
                                    nCtxFitted: 208_384,
                                    reachable: true,
                                    residentBytes: 16_081_678_492),
                    ])))
                }

                // A retrospective receipt, at the END of a generation — the only
                // shape this source ever has. Values are a real capture from
                // qwen/qwen3.8-27b on the embedded MLX engine.
                if i % 200 == 0, i > 0 {
                    cont.yield(.prediction(PredictionSample(
                        t: t, engine: .bionic,
                        modelIdentifier: "qwen/qwen3.8-27b",
                        stopReason: "maxPredictedTokensReached",
                        tokensPerSecond: .high(10.64),
                        timeToFirstToken: .high(53.111),
                        draftAccepted: .unavailable("no draft model in use — speculative counters absent"),
                        totalSeconds: 65.0,
                        promptTokens: 4063,
                        predictedTokens: 127,
                        totalTokens: 4190,
                        source: "lms log stream --stats")))
                    cont.yield(.health(SourceHealth(source: .predictions, engine: .bionic,
                                                    t: t, outcome: .ok, latency: 0,
                                                    sincePreviousOK: 20)))
                }
                i += 1
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}
