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
    /// Also its own thread, for the same reason and with a measured number
    /// behind it: an SMC sweep blocks for ~13 ms, which inside this actor
    /// would be a 13 ms hole in the 10 Hz system loop once a second.
    public nonisolated let thermal = ThermalProbe()

    private var machines: [EngineID: SlotStateMachine] = [:]
    /// Jan runs several model servers at once, each numbering its slots from 0,
    /// so its state machines are keyed by instance pid rather than by engine.
    /// Keying on the alias instead would carry a track across an unload/reload
    /// of the same model — a re-spawned server with reset counters, which is
    /// exactly the case a state machine must be torn down for.
    private var janMachines: [Int32: SlotStateMachine] = [:]
    private var janClients: [Int32: LlamaSlotsClient] = [:]
    private var janRouter: JanRouterClient?
    private var janRouterPort: UInt16?
    private var janCatalogue: [JanRouterClient.CatalogEntry] = []
    private var janLog: JanLogStream?
    private var janState: [UInt16: JanLogStream.InstanceState] = [:]
    /// Jan's instance processes, for the system sampler. The router owns the
    /// port but holds no weights: MEASURED, the router's footprint was 45 MB
    /// while its 4B-model child held 3.0 GB, so sampling only the descriptor's
    /// pid reports ~1.5% of what Jan is holding.
    private var janProcs: [(pid: Int32, startedAt: UInt64, label: String)] = []
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

    public nonisolated var cooling: CoolingController? { thermal.cooling }

    public func start() {
        guard !running else { return }
        running = true
        tasks = [
            Task { [weak self] in await self?.systemLoop() },
            Task { [weak self] in await self?.slowLoop() },
            Task { [weak self] in await self?.inferenceLoop() },
            Task { [weak self] in await self?.predictionLoop() },
            Task { [weak self] in await self?.thermalLoop() },
        ]
    }

    public func stop() {
        running = false
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        let stream = lms
        Task { await stream.stop() }
        // Releases any fan lease on the way out. The helper would time it out
        // in 15 s regardless, which is what makes this a courtesy and not a
        // safety mechanism.
        thermal.stop()
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

    // MARK: - Stream E: SMC thermal + cooling, 1 Hz, own thread

    /// Pumps the thermal thread's stream into the shared one.
    ///
    /// The probe is `absent`, not `dark`, when the SMC will not open: a machine
    /// whose sensors we cannot read has not failed, and a red chip there would
    /// be the same lie as reporting a stopped server as an error.
    private func thermalLoop() async {
        guard thermal.isAvailable else {
            emitHealth(.thermal, engine: nil, t: Instant.now(),
                       outcome: .other("AppleSMC exposed no readable die sensors"),
                       latency: 0)
            return
        }
        thermal.start()
        for await s in thermal.samples {
            guard running, !Task.isCancelled else { break }
            cont.yield(.thermal(s))
            emitHealth(.thermal, engine: nil, t: s.t, outcome: .ok,
                       latency: s.sampleCostMicros / 1e6)
        }
    }

    /// Tells the thermal thread whether work is in flight.
    ///
    /// This is what makes a boost policy pre-emptive rather than reactive: a
    /// fan told to spin at the START of a generation is at speed by the time
    /// the die is hot, which a temperature curve can never manage.
    private func refreshGenerating() {
        thermal.setGenerating(busyByEngine.values.contains(true))
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
        var targets: [(pid: Int32, startedAt: UInt64, engine: EngineID, label: String)] =
            descriptors.map { ($0.value.generation.pid, $0.value.generation.startedAt,
                              $0.key, $0.value.command) }
        // Jan's model instances, which are where all of its memory actually is.
        targets.append(contentsOf: janProcs.map {
            ($0.pid, $0.startedAt, EngineID.jan, $0.label) })

        for target in targets {
            let pid = target.pid
            guard let ti = ProcSampler.taskInfo(pid) else { continue }
            let nanos = ti.pti_total_user &+ ti.pti_total_system

            var frac = 0.0
            if let p = prevCPU[pid], dt > 0, nanos >= p.nanos {
                frac = Double(nanos &- p.nanos) / (dt * 1e9)
            }
            prevCPU[pid] = (nanos, t)

            let ru = ProcSampler.rusage(pid)
            out.append(ProcSample(
                pid: pid, startedAt: target.startedAt, engine: target.engine,
                command: target.label,
                cpuFraction: frac, cpuNanos: nanos,
                wired: ru?.ri_wired_size ?? 0,
                footprint: ru?.ri_phys_footprint ?? UInt64(ti.pti_resident_size),
                rss: UInt64(ti.pti_resident_size),
                diskBytesRead: ru?.ri_diskio_bytesread ?? 0,
                energyNanoJoules: ru?.ri_energy_nj ?? 0))
        }
        // Drop bookkeeping for processes that are gone.
        let live = Set(targets.map { $0.pid })
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
                if e == .jan {
                    // A new router means new instances on new ports with a new
                    // key. Nothing from the previous one survives.
                    janMachines.removeAll(); janClients.removeAll()
                    janRouter = nil; janRouterPort = nil; janCatalogue = []
                    janState.removeAll()
                }
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

            let topology = await registry.janTopology()
            await refreshJan(topology, at: t)

            // Process discovery finds llama.cpp/LocalAI/Ollama. It CANNOT find
            // the MLX backend -- that runs inside a node host with no listening
            // socket -- so ask LM Studio directly for what it has resident.
            // The generic descriptor row for Jan is replaced, not kept: the
            // process that owns the port is the router, and describing it with
            // the same fields as a model server would report a runtime holding
            // a nil model in a 0-token context.
            var entries = runtimes.filter { $0.engine != .jan }.map(rosterEntry)
            entries.append(contentsOf: janRosterEntries(topology))
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
            // The embedded MLX engine is visible ONLY here, so a generation
            // running on it would otherwise never reach the boost policy.
            if entries.contains(where: { $0.busy && !$0.exposesTokenTelemetry }) {
                thermal.setGenerating(true)
            } else {
                refreshGenerating()
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

    // MARK: - Jan: router-and-instances

    /// Keeps the Jan clients in step with the topology, and reads the router's
    /// catalogue.
    ///
    /// The catalogue is the ONLY thing asked of the router, because it is the
    /// only question that is free of side effects: `/v1/models` takes no model
    /// name and no key. `/props?model=` and `/slots?model=` would both name a
    /// model, and naming an unloaded model makes the router LOAD it — see
    /// `JanTopology.loadHazard`. An observer that can cause a 3 GB read is not
    /// an observer.
    private func refreshJan(_ topology: JanTopology?, at t: Instant) async {
        guard let topology else {
            janRouter = nil; janRouterPort = nil; janCatalogue = []
            janClients.removeAll(); janMachines.removeAll(); janState.removeAll()
            janProcs = []
            janLog = nil
            busyByEngine[.jan] = false
            return
        }

        janProcs = topology.instances.map {
            ($0.pid, $0.startedAt, "llama-server (\($0.alias))")
        }

        if janRouter == nil || janRouterPort != topology.routerPort {
            janRouter = JanRouterClient(host: topology.routerHost,
                                        port: topology.routerPort)
            janRouterPort = topology.routerPort
        }

        // The log is Jan's real telemetry channel; see JanLogStream.
        if janLog == nil, FileManager.default.fileExists(atPath: JanLogStream.defaultPath) {
            janLog = JanLogStream()
        }

        // Instances come and go as the router loads and unloads models, so the
        // client set is rebuilt against the live pids and anything not in it is
        // dropped along with its derived state.
        let live = Set(topology.instances.map { $0.pid })
        janClients = janClients.filter { live.contains($0.key) }
        janMachines = janMachines.filter { live.contains($0.key) }
        for i in topology.instances where janClients[i.pid] == nil {
            janClients[i.pid] = LlamaSlotsClient(
                host: i.host, port: i.port, key: topology.key, timeout: 2.0)
            janMachines[i.pid] = SlotStateMachine()
        }

        if let router = janRouter {
            do {
                janCatalogue = try await router.catalogue()
                emitHealth(.roster, engine: .jan, t: t, outcome: .ok,
                           latency: Instant.now() - t)
            } catch {
                janCatalogue = []
                emitHealth(.roster, engine: .jan, t: t,
                           outcome: Self.classify(error), latency: Instant.now() - t)
            }
        }
    }

    /// One roster row per Jan instance, plus one per model the router knows
    /// about but has not loaded.
    ///
    /// The unloaded rows matter: with `--models-max 2` Jan will load a model on
    /// demand and evict another, so "what could be running" is part of reading
    /// what Jan is doing. They are marked unreachable and holding nothing,
    /// which is exactly true — there is no process behind them.
    private func janRosterEntries(_ topology: JanTopology?) -> [RuntimeInfo] {
        guard let topology else { return [] }
        var out: [RuntimeInfo] = []
        var named: Set<String> = []

        // The router itself. It holds no weights, so it is described as what it
        // is rather than as a model server -- and it is listed even with no
        // model loaded, because otherwise a running, healthy Jan with an idle
        // router would be indistinguishable from Jan not running at all.
        out.append(RuntimeInfo(
            engine: .jan,
            backend: "llama.cpp router",
            busy: false,
            exposesTokenTelemetry: false,
            telemetryGap: JanTopology.routerRowNote,
            generation: EndpointGeneration(pid: topology.routerPID,
                                           startedAt: topology.routerStartedAt,
                                           port: topology.routerPort),
            endpoint: "\(topology.routerHost):\(topology.routerPort)",
            modelName: nil,
            totalSlots: topology.facts.modelsMax,
            reachable: true,
            residentBytes: ProcSampler.rusage(topology.routerPID)?.ri_phys_footprint ?? 0))

        for i in topology.instances {
            named.insert(i.alias)
            let ru = ProcSampler.rusage(i.pid)
            let st = janState[i.port]
            let meta = st?.meta
            out.append(RuntimeInfo(
                engine: .jan,
                backend: i.isEmbedding ? "llama.cpp (embeddings)" : "llama.cpp",
                busy: st?.decoding ?? false,
                // The log gives strictly more than /slots does, at no cost to
                // the decode loop -- but only if it is actually there.
                exposesTokenTelemetry: janLog != nil,
                telemetryGap: janLog == nil
                    ? "no log at \(JanLogStream.defaultPath) — token rates fall back to polling each instance's /slots"
                    : JanTopology.metricsGap,
                generation: EndpointGeneration(pid: i.pid, startedAt: i.startedAt,
                                               port: i.port),
                endpoint: "\(i.host):\(i.port)",
                modelName: i.alias,
                // llama.cpp's own ftype, when the child has announced itself.
                // Strictly better than the filename guess: every Jan model is
                // stored as `<id>/model.gguf`, so there is no quantization in
                // the path at all.
                quantization: meta?.ftype ?? i.facts.quantization,
                paramCount: meta?.nParams,
                fileBytes: meta?.sizeBytes,
                // n_ctx_train is the model maximum; n_ctx is what was allocated.
                nCtxReported: meta?.nCtxTrain,
                nCtxFitted: i.facts.allocatedSlotContext ?? meta?.nCtx,
                totalSlots: i.facts.parallelSlots,
                speculativeType: i.facts.speculativeType,
                flashAttention: i.facts.flashAttention,
                loadMode: i.facts.loadMode,
                reachable: true,
                residentBytes: ru?.ri_phys_footprint ?? 0))
        }

        for c in janCatalogue where !named.contains(c.id) {
            out.append(RuntimeInfo(
                engine: .jan,
                backend: c.isEmbedding ? "llama.cpp (embeddings)" : "llama.cpp",
                busy: false,
                exposesTokenTelemetry: false,
                telemetryGap: "not loaded — the router will start it on demand, and this app will not ask it to",
                endpoint: "—",
                modelName: c.id,
                quantization: c.facts.quantization,
                nCtxFitted: c.facts.allocatedSlotContext,
                totalSlots: c.facts.parallelSlots,
                reachable: false,
                residentBytes: 0))
        }
        return out
    }

    /// Reads Jan's log, and polls instance /slots only for what the log cannot
    /// say.
    ///
    /// Order matters. The log is free and richer, so it goes first and sets the
    /// busy state; /slots is then polled for the two things the log genuinely
    /// does not carry — live context occupancy and the sampler settings in
    /// force — and only against instances that are actually working. An idle
    /// instance is not polled at all, which is what keeps the cost of watching
    /// an idle Jan at zero.
    private func pollJan(_ topology: JanTopology) async {
        let t = Instant.now()

        if let log = janLog {
            let snap = log.poll(now: t)
            for (port, st) in snap.instances { janState[port] = st }
            for r in snap.receipts { cont.yield(.prediction(Self.prediction(from: r, at: t))) }
            if !snap.receipts.isEmpty {
                emitHealth(.predictions, engine: .jan, t: t, outcome: .ok, latency: 0)
            }
        }

        // ONE sample per tick, carrying every instance's slots.
        //
        // Not one sample per instance: the consumer keys the inference domain
        // by engine, so two Jan instances decoding at once would overwrite each
        // other and the UI would flip between two models' slots at the poll
        // rate. Merging is safe precisely because each SlotSample now names its
        // instance, so nothing is fused -- the slots stay individually
        // attributed, and their state machines stay per-instance so no counter
        // ever crosses between models.
        let issued = Instant.now()
        var slots: [SlotSample] = []
        var repairs = 0
        var advanced = false
        var anyBusy = false
        var polled = false
        var failure: Error?

        for i in topology.generativeInstances {
            let st = janState[i.port]
            let decoding = st?.decoding ?? false
            if decoding { anyBusy = true }
            // Poll a slot only while there is a request in it. Between
            // generations /slots serves the previous request's frozen counters,
            // which the state machine would have to discard anyway -- and not
            // polling an idle Jan at all is what keeps the cost of watching one
            // at zero.
            guard decoding, let client = janClients[i.pid] else { continue }
            do {
                let (raw, r) = try await client.slots()
                let t = Instant.now()
                polled = true
                repairs += r
                var machine = janMachines[i.pid] ?? SlotStateMachine()
                for rawSlot in raw {
                    let s = machine.update(
                        rawSlot, at: t,
                        fittedContext: i.facts.allocatedSlotContext,
                        // Under Jan this is a KNOWN quantity, not a caveat: the
                        // child was launched with --fit off, so --ctx-size is a
                        // real allocation split across --parallel slots, and
                        // the n_ctx in this very payload equals it.
                        allocatedContext: i.facts.allocatedSlotContext,
                        // The model's own trained ceiling, which only Jan says.
                        trainableContext: st?.meta?.nCtxTrain,
                        instance: i.alias)
                    if s.state == .processing,
                       s.decodeTokensPerSecond.value ?? 0 > 0 { advanced = true }
                    slots.append(s)
                }
                janMachines[i.pid] = machine
            } catch {
                failure = error
            }
        }

        busyByEngine[.jan] = anyBusy
        refreshGenerating()
        if advanced { confirmedAdvance = true }

        if polled {
            let t = Instant.now()
            cont.yield(.inference(InferenceSample(
                requestedAt: issued, t: t, engine: .jan,
                // The ROUTER's generation, not an instance's. The router is
                // Jan's stable identity: instances are spawned and evicted as
                // models load, so keying the domain to one of them would
                // declare a new endpoint generation -- and tear down all
                // derived state -- every time a model swapped.
                generation: EndpointGeneration(pid: topology.routerPID,
                                               startedAt: topology.routerStartedAt,
                                               port: topology.routerPort),
                slots: slots, malformedRepairs: repairs)))
            slotPollTimes.append((t, (t - issued) * 1000))
            slotPollTimes.removeAll { t - $0.t > 60 }
            emitHealth(.slots, engine: .jan, t: t, outcome: .ok, latency: t - issued)
        } else if let failure {
            let t = Instant.now()
            emitHealth(.slots, engine: .jan, t: t,
                       outcome: Self.classify(failure), latency: t - issued)
        }
    }

    /// Turns a log receipt into the app's existing prediction-receipt type.
    ///
    /// These are `.high` confidence where LM Studio's are not, and for a
    /// concrete reason: every number is a clock reading llama.cpp took itself
    /// and printed. In particular the TTFT is the true prefill duration, not
    /// the poll-interval bracket `/slots` forces this app to publish
    /// everywhere else.
    private static func prediction(from r: JanLogStream.Receipt,
                                   at t: Instant) -> PredictionSample {
        PredictionSample(
            t: t, engine: .jan,
            modelIdentifier: r.alias ?? "unknown",
            // llama.cpp's log does not name a finish reason. `truncated` is the
            // one thing it does say about how the request ended, and inventing
            // "eosFound" from its absence would be a guess.
            stopReason: (r.truncated == true) ? "contextTruncated" : "reported by llama.cpp",
            tokensPerSecond: r.decodeTokensPerSecond.map { .high($0) }
                ?? .unavailable("no eval-time line in the log for this request"),
            timeToFirstToken: r.timeToFirstToken.map { .high($0) }
                ?? .unavailable("no prompt-eval line in the log for this request"),
            draftAccepted: .unavailable("speculative decoding is not configured by Jan"),
            totalSeconds: r.totalMillis.map { $0 / 1000 },
            promptTokens: r.promptTokens,
            predictedTokens: r.decodedTokens,
            totalTokens: r.totalTokens,
            source: "Jan app.log (llama.cpp print_timing)")
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
            if let topology = await registry.janTopology() { await pollJan(topology) }
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
            refreshGenerating()
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
        refreshGenerating()

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
