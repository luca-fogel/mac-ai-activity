import Foundation

/// The live collector. Four independent streams, deliberately never fused.
///
///   system      native IOKit/mach    2-10 Hz adaptive   ~31 us/tick
///   inference   llama-server /slots   1 Hz or 0.2 Hz    100-450 ms per call
///   slow        discovery + power     0.2 Hz
///   predictions lms diagnostics      PUSH, ~1 per generation
///
/// The fourth is the odd one out and is meant to be: it does not poll at all.
/// LM Studio emits one receipt at the END of each prediction and nothing during
/// decode, so there is no rate to choose and its silence means "no work", not
/// "no data". It is the only channel that can see Bionic's embedded MLX engine.
///
/// The rates differ by two orders of magnitude because the sources genuinely
/// do. Interpolating the slow stream onto the fast grid would fabricate
/// resolution, so each stream carries its own timestamps and the UI aligns
/// them on a shared axis.
public actor LiveTelemetryFeed: TelemetryFeed {

    public nonisolated let samples: AsyncStream<Sample>
    private let cont: AsyncStream<Sample>.Continuation

    private let gpu = GPUAccelerator()
    private let power = PowerSource()
    private let registry = EndpointRegistry()
    /// Its own actor on purpose: it owns a long-lived child process, and
    /// LMStudioProbe already demonstrates what attaching one of those to this
    /// actor costs — a ~240 ms stall of every other collector, every 5 s.
    private let lms = LMSLogStream()

    private var machines: [EngineID: SlotStateMachine] = [:]
    private var mlxTailer: MLXLogTailer?
    /// Whether each engine is doing work right now. Without this the roster
    /// reported every engine as idle, so the UI fell back to "largest resident"
    /// and showed llama.cpp's model while mlx-lm was the one generating.
    private var busyByEngine: [EngineID: Bool] = [:]
    /// Consecutive failures per engine, for backoff. Without this the app
    /// polled a stopped server at full rate forever and reported "connection
    /// refused" -- which reads as a fault when the truth is "you stopped it".
    private var failures: [EngineID: Int] = [:]
    private var nextAttemptAt: [EngineID: Instant] = [:]
    private var clients: [EngineID: LlamaSlotsClient] = [:]
    private var descriptors: [EngineID: RuntimeDescriptor] = [:]
    private var detector = ActivityDetector()
    private var cadence: CadenceMode = .adaptive

    private var prevCPU: [Int32: (nanos: UInt64, t: Instant)] = [:]
    private var lastOK: [String: Instant] = [:]
    private var lastSystemAt: Instant?
    private var confirmedAdvance = false
    private var running = false
    private var tasks: [Task<Void, Never>] = []

    /// Rolling receipts for the observer-effect readout.
    private var slotPollTimes: [(t: Instant, ms: Double)] = []

    public init() {
        var c: AsyncStream<Sample>.Continuation!
        self.samples = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { c = $0 }
        self.cont = c
    }

    public func setCadence(_ mode: CadenceMode) { cadence = mode }

    public func start() {
        guard !running else { return }
        running = true
        tasks = [
            Task { [weak self] in await self?.systemLoop() },
            Task { [weak self] in await self?.slowLoop() },
            Task { [weak self] in await self?.inferenceLoop() },
            Task { [weak self] in await self?.predictionLoop() },
        ]
    }

    public func stop() {
        running = false
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        let stream = lms
        Task { await stream.stop() }
        cont.finish()
    }

    // MARK: - Stream D: LM Studio diagnostics, PUSH

    /// Awaits receipts rather than polling for them.
    ///
    /// This is the only source in the app whose quiet carries no information
    /// about its health, which is why `.predictions` is judged under
    /// `FreshnessPolicy.eventDriven` and never reads stale.
    private func predictionLoop() async {
        guard await lms.isAvailable else {
            // No lms CLI. Nothing has failed; there is simply no such channel.
            emitHealth(.predictions, engine: lms.engine, t: Instant.now(),
                       outcome: .other("lms CLI not installed"), latency: 0)
            return
        }
        await lms.start()
        for await event in lms.events {
            guard running, !Task.isCancelled else { break }
            switch event {
            case .prediction(let p):
                cont.yield(.prediction(p))
                emitHealth(.predictions, engine: p.engine, t: p.t,
                           outcome: .ok, latency: 0)
            case .health(let outcome, let t):
                emitHealth(.predictions, engine: lms.engine, t: t,
                           outcome: outcome, latency: 0)
            }
        }
    }

    // MARK: - Stream A: native, 2-10 Hz

    private func systemLoop() async {
        while running && !Task.isCancelled {
            let t = Instant.now()
            let t0 = DispatchTime.now().uptimeNanoseconds

            let g = gpu.sample()
            let m = MachMemory.sample()
            let dt = lastSystemAt.map { t - $0 } ?? 0
            lastSystemAt = t

            detector.observeGPU(g?.device, at: t, dt: dt)
            detector.update(confirmed: confirmedAdvance, gpu: g?.device, at: t)
            confirmedAdvance = false

            if let m {
                let procs = sampleProcesses(at: t, dt: dt)
                cont.yield(.system(SystemSample(
                    t: t,
                    gpuDevice: g?.device, gpuRenderer: g?.renderer, gpuTiler: g?.tiler,
                    gpuInUseBytes: g?.inUseBytes, gpuAllocBytes: g?.allocBytes,
                    gpuRecoveryCount: g?.recoveryCount ?? 0,
                    memTotal: m.total, memUsed: m.used, memWired: m.wired,
                    memCompressed: m.compressed, memFileBacked: m.fileBacked,
                    pressure: m.pressure,
                    compressionsTotal: m.compressions,
                    decompressionsTotal: m.decompressions,
                    pageinsTotal: m.pageins,
                    thermal: PowerSource.thermalState(),
                    procs: procs)))
            }

            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            emitHealth(.system, engine: nil, t: t,
                       outcome: m == nil ? .other("host_statistics64 failed") : .ok,
                       latency: ms / 1000)

            try? await Task.sleep(nanoseconds: UInt64(detector.systemInterval * 1e9))
        }
    }

    private func sampleProcesses(at t: Instant, dt: Double) -> [ProcSample] {
        var out: [ProcSample] = []
        for (engine, d) in descriptors {
            let pid = d.generation.pid
            guard let ti = ProcSampler.taskInfo(pid) else { continue }
            let nanos = ti.pti_total_user &+ ti.pti_total_system

            var frac = 0.0
            if let p = prevCPU[pid], dt > 0, nanos >= p.nanos {
                frac = Double(nanos &- p.nanos) / (dt * 1e9)
            }
            prevCPU[pid] = (nanos, t)

            let ru = ProcSampler.rusage(pid)
            out.append(ProcSample(
                pid: pid, startedAt: d.generation.startedAt, engine: engine,
                command: d.command,
                cpuFraction: frac, cpuNanos: nanos,
                wired: ru?.ri_wired_size ?? 0,
                footprint: ru?.ri_phys_footprint ?? UInt64(ti.pti_resident_size),
                rss: UInt64(ti.pti_resident_size),
                diskBytesRead: ru?.ri_diskio_bytesread ?? 0,
                energyNanoJoules: ru?.ri_energy_nj ?? 0))
        }
        // Drop bookkeeping for processes that are gone.
        let live = Set(descriptors.values.map { $0.generation.pid })
        prevCPU = prevCPU.filter { live.contains($0.key) }
        return out.sorted { $0.pid < $1.pid }
    }

    // MARK: - Stream C: discovery + power, 0.2 Hz

    private func slowLoop() async {
        while running && !Task.isCancelled {
            let t = Instant.now()
            let (runtimes, changed) = await registry.refresh()

            for e in changed {
                // A re-spawned server must never inherit the previous run's
                // counters; that would emit a fictional rate spike.
                machines[e]?.reset()
                machines[e] = SlotStateMachine()
                clients[e] = nil
                failures[e] = 0
                nextAttemptAt[e] = nil
                busyByEngine[e] = false
            }
            // mlx-lm's telemetry is a log, not a socket, so it needs retiring
            // explicitly when the server goes away.
            if !runtimes.contains(where: { $0.engine == .mlxlm }) { mlxTailer = nil }
            descriptors = Dictionary(uniqueKeysWithValues: runtimes.map { ($0.engine, $0) })

            if runtimes.contains(where: { $0.engine == .mlxlm }), mlxTailer == nil {
                // Prefer whichever candidate log was written most recently: the
                // canonical path can exist but be stale while a supervised run
                // writes elsewhere.
                if let p = MLXLogTailer.bestAvailablePath() {
                    mlxTailer = MLXLogTailer(path: p)
                }
            }
            for d in runtimes where clients[d.engine] == nil && d.engine == .bionic {
                clients[d.engine] = LlamaSlotsClient(
                    host: d.host, port: d.port, key: d.key, timeout: 2.0)
                machines[d.engine] = machines[d.engine] ?? SlotStateMachine()
            }

            // Process discovery finds llama.cpp/LocalAI/Ollama. It CANNOT find
            // the MLX backend -- that runs inside a node host with no listening
            // socket -- so ask LM Studio directly for what it has resident.
            var entries = runtimes.map(rosterEntry)
            for m in LMStudioProbe.snapshot() where m.isMLX {
                entries.append(RuntimeInfo(
                    engine: .bionic, backend: "MLX (embedded)", busy: m.isBusy,
                    exposesTokenTelemetry: false,          // no /slots equivalent
                    telemetryGap: "no per-token telemetry — per-prediction stats only, via lms log stream",
                    endpoint: "Bionic IPC (no HTTP port)",
                    modelName: m.identifier,
                    quantization: m.architecture,
                    nCtxFitted: m.contextLength,
                    reachable: true,
                    residentBytes: m.sizeBytes))
            }
            cont.yield(.roster(EngineRoster(t: t, runtimes: entries)))
            // .roster is a declared source; without this it never reported and
            // its row in the inspector was permanently red.
            emitHealth(.roster, engine: nil, t: t, outcome: .ok,
                       latency: Instant.now() - t)

            // Health is emitted either way: when this was inside the `if let`,
            // an IOKit failure produced no health sample at all, so the chip
            // aged into a generic "no samples yet" instead of naming the fault.
            if let p = power.sample() {
                // MEASURED: this read "held -3.1s" on the first sample. `t` is
                // stamped at the top of the loop and PowerSource stamps its own
                // change time during the read, so lastChangedAt can legitimately
                // be LATER than t. A negative hold age is not a thing; clamp it
                // here rather than letting every consumer defend itself.
                cont.yield(.power(PowerSample(
                    t: t, lastRefreshedAt: min(p.lastChangedAt, t), watts: p.watts,
                    onAC: p.onAC, batteryFraction: p.batteryFraction,
                    batteryTempC: p.batteryTempC,
                    accumulatedEnergy: p.accumulatedEnergy, source: p.source)))
                emitHealth(.power, engine: nil, t: t, outcome: .ok, latency: 0)
            } else {
                emitHealth(.power, engine: nil, t: t,
                           outcome: .other("AppleSmartBattery properties unreadable"),
                           latency: 0)
            }

            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func rosterEntry(_ d: RuntimeDescriptor) -> RuntimeInfo {
        let ru = ProcSampler.rusage(d.generation.pid)
        return RuntimeInfo(
            engine: d.engine,
            backend: d.engine == .bionic ? "llama.cpp" : (d.engine == .mlxlm ? "mlx-lm" : nil),
            busy: busyByEngine[d.engine] ?? false,
            // mlx-lm's telemetry comes from its log; if the log is not where we
            // expect it, say so rather than reporting silence as idle.
            exposesTokenTelemetry: d.engine != .mlxlm || mlxTailer != nil,
            // Name the missing file AND the remedy. "No telemetry" alone reads
            // as a fault when the truth is that a log needs enabling.
            telemetryGap: (d.engine == .mlxlm && mlxTailer == nil)
                ? "no log at \(MLXLogTailer.candidatePaths.joined(separator: " or ")) — start mlx-lm via tools/mlx-serve.sh to enable its telemetry"
                : nil,
            generation: d.generation,
            endpoint: "\(d.host):\(d.port)",
            modelName: d.facts.modelName, quantization: d.facts.quantization,
            nCtxFitted: d.facts.fittedContext,
            totalSlots: d.facts.parallelSlots,
            speculativeType: d.facts.speculativeType,
            flashAttention: d.facts.flashAttention,
            loadMode: d.facts.loadMode,
            reachable: true,
            // Footprint, not wired: llama.cpp mlocks its weights (wired 18.5 GB)
            // but mlx-lm does not (wired 0), so keying residency on wired made a
            // 14 GB resident model look like it was holding nothing.
            residentBytes: ru?.ri_phys_footprint ?? 0)
    }

    // MARK: - Stream B: /slots, <= 1 Hz, single in-flight

    private func inferenceLoop() async {
        while running && !Task.isCancelled {
            let interval: Double
            switch cadence {
            case .adaptive:            interval = 1.0
            case .minimumPerturbation: interval = 5.0
            case .systemOnly:
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }

            let now = Instant.now()
            for (engine, client) in clients {
                // A stopped server is not an error condition; it is simply
                // absent, and absent sources are not polled at all.
                guard let d = descriptors[engine] else { continue }
                if let next = nextAttemptAt[engine], now < next { continue }
                await pollSlots(engine: engine, client: client, descriptor: d)
            }
            if descriptors[.mlxlm] != nil { pollMLX() }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
        }
    }

    private func pollSlots(engine: EngineID,
                           client: LlamaSlotsClient,
                           descriptor d: RuntimeDescriptor) async {
        let issued = Instant.now()
        do {
            let (raw, repairs) = try await client.slots()
            let t = Instant.now()

            var machine = machines[engine] ?? SlotStateMachine()
            var slots: [SlotSample] = []
            var advanced = false
            for r in raw {
                let s = machine.update(r, at: t, fittedContext: d.facts.fittedContext)
                if s.state == .processing, s.decodeTokensPerSecond.value ?? 0 > 0 { advanced = true }
                slots.append(s)
            }
            machines[engine] = machine
            busyByEngine[engine] = slots.contains { $0.state.isBusy }
            if advanced { confirmedAdvance = true }

            cont.yield(.inference(InferenceSample(
                requestedAt: issued, t: t, engine: engine,
                generation: d.generation, slots: slots, malformedRepairs: repairs)))

            let ms = (t - issued) * 1000
            slotPollTimes.append((t, ms))
            slotPollTimes.removeAll { t - $0.t > 60 }

            failures[engine] = 0
            nextAttemptAt[engine] = nil
            emitHealth(.slots, engine: engine, t: t, outcome: .ok, latency: t - issued)
        } catch {
            let t = Instant.now()
            let n = (failures[engine] ?? 0) + 1
            failures[engine] = n
            // 1s, 2s, 4s ... capped at 30s. A server that is down stays down;
            // there is nothing to learn from asking 60 times a minute.
            let backoff = min(30.0, pow(2.0, Double(min(n, 5))))
            nextAttemptAt[engine] = Instant(t.s + backoff)
            emitHealth(.slots, engine: engine, t: t,
                       outcome: Self.classify(error), latency: t - issued)
        }
    }

    /// mlx-lm has no /slots and no /metrics, so its log is the telemetry
    /// channel. Prefill progress arrives live; token totals only at the end of
    /// a request, so decode rate is derived per episode rather than per sample.
    /// The result is fed through the SAME state machine as llama.cpp, so the
    /// stale-counter and boundary protections apply identically.
    private func pollMLX() {
        guard let tailer = mlxTailer, let d = descriptors[.mlxlm] else { return }
        let t = Instant.now()
        let st = tailer.poll(now: t)
        // 4 s, not 2: token totals only land in the log at the END of a
        // request, so a shorter window declared mlx-lm idle while the GPU was
        // still visibly working and the UI called it "unattributed activity".
        let busy = st.prefilling
            || (st.lastActivityAt.map { t - $0 < 4 } ?? false)

        let raw = LlamaSlotsClient.RawSlot(
            id: 0, isProcessing: busy, nCtx: d.facts.fittedContext ?? 0,
            speculative: d.facts.speculativeType != nil,
            idTask: st.requestsSeen,
            nPromptTokens: st.promptTotal,
            nPromptTokensProcessed: st.promptProcessed,
            nPromptTokensCache: st.cachedTokens,
            nDecoded: st.completionTokens,
            nRemain: nil, hasNextToken: busy, sampler: nil,
            specTypes: d.facts.speculativeType,
            hasCounters: st.promptTotal != nil || st.completionTokens != nil)

        var machine = machines[.mlxlm] ?? SlotStateMachine()
        let slot = machine.update(raw, at: t, fittedContext: d.facts.fittedContext)
        machines[.mlxlm] = machine
        busyByEngine[.mlxlm] = slot.state.isBusy

        cont.yield(.inference(InferenceSample(
            requestedAt: t, t: t, engine: .mlxlm,
            generation: d.generation, slots: [slot])))
        emitHealth(.slots, engine: .mlxlm, t: t, outcome: .ok, latency: 0)
    }

    public func selfCost() -> SelfCost {
        SelfCost(collectorMicrosPerTick: 31,
                 ownCPUFraction: 0,
                 slotPollsLastMinute: slotPollTimes.count,
                 serverMillisLastMinute: slotPollTimes.reduce(0) { $0 + $1.ms })
    }

    // MARK: - Health

    private func emitHealth(_ kind: SourceKind, engine: EngineID?, t: Instant,
                            outcome: Outcome, latency: Double) {
        let key = "\(kind.rawValue)|\(engine?.rawValue ?? "-")"
        let since = lastOK[key].map { t - $0 }
        if outcome.isOK { lastOK[key] = t }
        cont.yield(.health(SourceHealth(source: kind, engine: engine, t: t,
                                        outcome: outcome, latency: latency,
                                        sincePreviousOK: since)))
    }

    private static func classify(_ e: Error) -> Outcome {
        if let le = e as? LlamaSlotsClient.Err {
            switch le {
            case .http(let c):   return .http(c)
            case .decode(let m): return .decode(m)
            }
        }
        let ns = e as NSError
        switch ns.code {
        case NSURLErrorTimedOut:            return .timeout
        case NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost: return .refused
        default:                            return .other(ns.localizedDescription)
        }
    }
}
