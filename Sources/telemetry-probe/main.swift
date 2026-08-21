import Foundation
import Telemetry

// Headless verification harness. No UI, no window server, no SwiftUI.
// Exists so the collection layer stays honest and its cost budget is a
// regression test rather than a claim.

func gib(_ b: UInt64) -> String { String(format: "%7.2f GiB", Double(b) / 1_073_741_824) }
// Line-buffer stdout: this tool is almost always run into a pipe or a file,
// where libc block-buffers by default and nothing appears until exit — which
// makes a live telemetry probe useless.
setvbuf(stdout, nil, _IOLBF, 0)

let args = Set(CommandLine.arguments.dropFirst())

let gpu = GPUAccelerator()
_ = gpu.sample(); _ = MachMemory.sample()   // warm caches

if args.contains("--cost") {
    var tGPU = 0.0, tMem = 0.0
    let n = 500
    for _ in 0..<n {
        var t0 = DispatchTime.now().uptimeNanoseconds
        _ = gpu.sample()
        tGPU += Double(DispatchTime.now().uptimeNanoseconds - t0)
        t0 = DispatchTime.now().uptimeNanoseconds
        _ = MachMemory.sample()
        tMem += Double(DispatchTime.now().uptimeNanoseconds - t0)
    }
    let gpuUs = tGPU / Double(n) / 1000, memUs = tMem / Double(n) / 1000
    print(String(format: "GPUAccelerator.sample()  %8.1f us   (budget 400)", gpuUs))
    print(String(format: "MachMemory.sample()      %8.2f us   (budget  50)", memUs))
    let tickUs = gpuUs + memUs
    print(String(format: "combined tick            %8.1f us  -> %.3f%% of one core at 10 Hz",
                 tickUs, tickUs * 10 / 10_000))
    if gpuUs > 400 || memUs > 50 {
        print("FAIL: cost regression"); exit(1)
    }
    print("PASS")
    exit(0)
}

// Proves the prediction stream on its own, health included, without the rest
// of the collector in the way. This is the only source in the app that owns a
// child process, so it gets its own harness.
if args.contains("--predictions") {
    let stream = LMSLogStream()
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        print("cli        \(LMSLogStream.defaultCLI)")
        print("available  \(await stream.isAvailable)")
        print("argv       lms \(LMSLogStream.arguments.joined(separator: " "))")
        print("waiting for predictions — drive a generation in LM Studio\n")
        await stream.start()
        for await e in stream.events {
            switch e {
            case .health(let outcome, let t):
                print("HEALTH \(t)  \(outcome.shortReason)")
            case .prediction(let p):
                let tps = p.tokensPerSecond.value.map { String(format: "%.2f tok/s", $0) }
                    ?? "— (\(p.tokensPerSecond.confidence.reason ?? "?"))"
                let ttft = p.timeToFirstToken.value.map { String(format: "%.3f s", $0) } ?? "—"
                print("PRED   \(p.modelIdentifier) [\(p.stopReason)]  \(tps)  TTFT \(ttft)  "
                      + "prompt \(p.promptTokens.map(String.init) ?? "—") "
                      + "predicted \(p.predictedTokens.map(String.init) ?? "—")")
                print("       lines \(await stream.linesSeen)  malformed \(await stream.malformedLines)")
            }
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// Proves the whole Jan path against a live Jan: three-tier discovery, the
// environment-borne API key, the auth-free catalogue, and the log stream that
// replaces polling. Prints what is measurable and what is not, and never sends
// a request that could make the router load a model.
if args.contains("--jan") {
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let registry = EndpointRegistry()
        _ = await registry.refresh()
        guard let top = await registry.janTopology() else {
            print("Jan's llama.cpp engine is not running (no router process found).")
            print("A running Jan.app with no engine started is expected to print this.")
            sem.signal(); return
        }

        print("ROUTER   pid \(top.routerPID)  \(top.routerHost):\(top.routerPort)"
              + "  models-max \(top.facts.modelsMax.map(String.init) ?? "—")")
        print("KEY      \(top.key == nil ? "NOT FOUND — /slots and /props will 401" : "found in router env (\(top.key!))")")
        print("HAZARD   \(JanTopology.loadHazard)")
        print("METRICS  \(JanTopology.metricsGap)")

        let router = JanRouterClient(host: top.routerHost, port: top.routerPort)
        do {
            print("HEALTH   \(try await router.health() ? "ok" : "not ok")   (unauthenticated)")
            for c in try await router.catalogue() {
                print("CATALOG  \(c.id)  \(c.residency.rawValue)"
                      + "  ctx/slot \(c.facts.allocatedSlotContext.map(String.init) ?? "—")"
                      + (c.isEmbedding ? "  [embeddings]" : ""))
            }
        } catch { print("CATALOG  failed: \(error)") }

        for i in top.instances {
            let ru = ProcSampler.rusage(i.pid)
            print("INSTANCE \(i.alias)  pid \(i.pid)  port \(i.port)"
                  + "  slots \(i.facts.parallelSlots.map(String.init) ?? "—")"
                  + "  ctx/slot \(i.facts.allocatedSlotContext.map(String.init) ?? "—")"
                  + "  footprint \(gib(ru?.ri_phys_footprint ?? 0))"
                  + (i.isEmbedding ? "  [embeddings]" : ""))
        }
        if top.instances.isEmpty { print("INSTANCE (none loaded — the router is idle)") }

        let log = JanLogStream()
        guard log.exists else {
            print("LOG      missing at \(log.path) — no push telemetry")
            sem.signal(); return
        }
        print("LOG      \(log.path)")
        print("\nwatching — drive a generation in Jan (Ctrl-C to stop)\n")
        while true {
            let snap = log.poll(now: Instant.now())
            for (port, st) in snap.instances.sorted(by: { $0.key < $1.key }) where st.decoding {
                print(String(format: "LIVE  %-24@ port %d slot %@  n_decoded %@  tg %@  tg_3s %@",
                    st.alias ?? "?", Int(port),
                    st.slotID.map(String.init) ?? "—",
                    st.nDecoded.map(String.init) ?? "—",
                    st.tokensPerSecond.map { String(format: "%.2f", $0) } ?? "—",
                    st.tokensPerSecond3s.map { String(format: "%.2f", $0) } ?? "—"))
            }
            for (port, st) in snap.instances.sorted(by: { $0.key < $1.key }) {
                if let p = st.loadProgress {
                    print(String(format: "LOAD  %-24@ port %d  %.0f%%",
                                 st.alias ?? "?", Int(port), p * 100))
                }
            }
            for r in snap.receipts {
                print("RCPT  \(r.alias ?? "?")  slot \(r.slotID.map(String.init) ?? "—")")
                print(String(format: "        prefill %@ tok in %@ ms  (%@ tok/s)  -> TTFT %@ s EXACT",
                    r.promptTokens.map(String.init) ?? "—",
                    r.promptMillis.map { String(format: "%.2f", $0) } ?? "—",
                    r.promptTokensPerSecond.map { String(format: "%.2f", $0) } ?? "—",
                    r.timeToFirstToken.map { String(format: "%.4f", $0) } ?? "—"))
                print(String(format: "        decode  %@ tok in %@ ms  (%@ tok/s)  ctx %@  truncated %@  graphs reused %@",
                    r.decodedTokens.map(String.init) ?? "—",
                    r.decodeMillis.map { String(format: "%.2f", $0) } ?? "—",
                    r.decodeTokensPerSecond.map { String(format: "%.2f", $0) } ?? "—",
                    r.contextTokens.map(String.init) ?? "—",
                    r.truncated.map(String.init) ?? "—",
                    r.graphsReused.map(String.init) ?? "—"))
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
    sem.wait()
    exit(0)
}

if args.contains("--live") {
    let feed = LiveTelemetryFeed()
    let sem = DispatchSemaphore(value: 0)
    // Task.detached: top-level code is @MainActor in Swift 6, so a plain Task
    // would inherit main-actor isolation and never run while sem.wait() blocks
    // the main thread.
    Task.detached {
        await feed.start()
        var nSys = 0, nInf = 0, nPred = 0
        for await sample in feed.samples {
            switch sample {
            case .system(let s):
                nSys += 1
                if nSys % 20 == 0 {
                    print(String(format: "SYS  gpu %5.1f%%  used %5.2f GiB  wired %5.2f  press %@  procs %d",
                        (s.gpuDevice ?? 0) * 100, Double(s.memUsed)/1073741824,
                        Double(s.memWired)/1073741824, "\(s.pressure)", s.procs.count))
                    for p in s.procs {
                        print(String(format: "     %-14@ pid %-6d cpu %5.2f%%  wired %5.2f GiB  footprint %5.2f GiB",
                            p.engine?.displayName ?? "?", p.pid, p.cpuFraction * 100,
                            Double(p.wired)/1073741824, Double(p.footprint)/1073741824))
                    }
                }
            case .inference(let s):
                nInf += 1
                print(String(format: "INF  %@ poll %6.1f ms  repairs %d", s.engine.displayName, s.pollDuration * 1000, s.malformedRepairs))
                for sl in s.slots {
                    let ctx = sl.nPromptTokens.map { npt -> String in
                        // When the window is known exactly there is one ratio,
                        // and calling n_ctx the "reported max" would be wrong:
                        // under a router child with auto-fit off it IS the
                        // allocation.
                        if let w = sl.context.allocatedWindow.value {
                            let trainable = sl.nCtxTrainable.map { " · model trained for \($0)" } ?? ""
                            return String(format: "%d/%d = %.1f%% of the allocated window%@",
                                          npt, w, Double(npt)/Double(w)*100, trainable)
                        }
                        if let fit = sl.nCtxFitted { return String(format: "%d/%d = %.1f%% of fitted (%.1f%% of reported max)", npt, fit, Double(npt)/Double(fit)*100, Double(npt)/Double(sl.nCtxReported)*100) }
                        return "\(npt)/? — fitted window unknown"
                    } ?? "—"
                    let rate = sl.decodeTokensPerSecond.value.map { String(format: "%.2f tok/s", $0) }
                             ?? "— (\(sl.decodeTokensPerSecond.confidence.reason ?? "?"))"
                    let cache = sl.cacheHitRate.value.map { String(format: "%.1f%%", $0*100) }
                              ?? "—"
                    print("     slot \(sl.id) [\(sl.state)] task \(sl.idTask.map(String.init) ?? "—")  decode \(rate)  cache \(cache)")
                    if sl.state != .neverUsed { print("       ctx \(ctx)   nDecoded \(sl.nDecoded.map(String.init) ?? "—")  spec \(sl.speculative)") }
                }
            case .power(let p):
                let w = p.watts.value.map { String(format: "%.2f W", $0) } ?? "— (\(p.watts.confidence.reason ?? "?"))"
                print(String(format: "PWR  %@   held %.1fs   batt %.0f%%  %.1f C", w, p.t - p.lastRefreshedAt, (p.batteryFraction ?? 0)*100, p.batteryTempC ?? 0))
            case .prediction(let pr):
                nPred += 1
                let tps = pr.tokensPerSecond.value.map { String(format: "%.2f tok/s", $0) }
                    ?? "— (\(pr.tokensPerSecond.confidence.reason ?? "?"))"
                let ttft = pr.timeToFirstToken.value.map { String(format: "%.3f s", $0) }
                    ?? "— (\(pr.timeToFirstToken.confidence.reason ?? "?"))"
                let spec = pr.draftAccepted.value.map { String(format: "%.1f%%", $0 * 100) }
                    ?? "— (\(pr.draftAccepted.confidence.reason ?? "?"))"
                print("PRED \(pr.modelIdentifier)  [\(pr.stopReason)]  via \(pr.source)")
                print(String(format: "       %@ avg   TTFT %@   prompt %@  predicted %@  total %@ s",
                             tps, ttft,
                             pr.promptTokens.map(String.init) ?? "—",
                             pr.predictedTokens.map(String.init) ?? "—",
                             pr.totalSeconds.map { String(format: "%.1f", $0) } ?? "—"))
                print("       speculative accept \(spec)   RETROSPECTIVE — not a live rate")

            case .roster(let r):
                print("ROS  " + r.runtimes.map { "\($0.engine.displayName)@\($0.endpoint)\($0.modelName.map { m in " [\(m)]" } ?? "")" }.joined(separator: "  "))
            case .thermal(let th):
                let hot = th.hotspot.map { String(format: "%@ %.1f C", $0.domain.displayName, $0.estimate.value ?? -1) } ?? "—"
                let fans = th.fans.map { String(format: "%.0f rpm[%@]", $0.actualRPM ?? -1, $0.mode.rawValue) }
                    .joined(separator: " ")
                let ctl = th.control.map { $0.forcing ? "FORCED \($0.targets.sorted { $0.key < $1.key }.map { String(format: "%.0f", $0.value) }.joined(separator: "/"))" : "auto" } ?? "no helper"
                print(String(format: "THRM hotspot %@  fans %@  %@  press %@  sweep %.1f ms/%d sensors",
                             hot, fans, ctl, th.pressure.rawValue, th.sampleCostMicros / 1000, th.sensorsRead))
            case .health(let h):
                if !h.outcome.isOK {
                    print("HLTH \(h.source.rawValue)\(h.engine.map { "/\($0.rawValue)" } ?? "") -> \(h.outcome.shortReason)")
                }
            }
        }
        sem.signal()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 22) {
        Task { await feed.stop() }
    }
    _ = sem.wait(timeout: .now() + 30)
    exit(0)
}

/// Verifies the thermal collector AND its two costs, which differ by 14x.
///
/// The distinction is the whole reason the thermal sweep is allowed to read
/// every sensor every second: it is 13 ms of BLOCKED time and under 1 ms of
/// CPU, so it is cheap for the machine and expensive only for the thread it
/// runs on — which is why that thread is its own.
if args.contains("--thermal") {
    guard let sensors = ThermalSensors() else {
        print("no readable SMC die sensors"); exit(1)
    }
    print("discovered: " + ThermalDomain.allCases.map {
        "\($0.displayName) \(sensors.discoveredCounts[$0] ?? 0)"
    }.joined(separator: "  "))

    // Cost, measured both ways.
    _ = sensors.sample()
    let n = 20
    var wall = 0.0
    let c0 = ProcessInfo.processInfo.systemUptime
    var cpu0 = rusage()
    getrusage(RUSAGE_SELF, &cpu0)
    for _ in 0..<n {
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = sensors.sample()
        wall += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }
    var cpu1 = rusage()
    getrusage(RUSAGE_SELF, &cpu1)
    func secs(_ r: rusage) -> Double {
        Double(r.ru_utime.tv_sec) + Double(r.ru_utime.tv_usec) / 1e6
            + Double(r.ru_stime.tv_sec) + Double(r.ru_stime.tv_usec) / 1e6
    }
    let cpuMs = (secs(cpu1) - secs(cpu0)) / Double(n) * 1000
    _ = c0
    print(String(format: "sweep: %.1f ms wall, %.2f ms CPU per tick -> %.3f%% of one core at 1 Hz",
                 wall / Double(n), cpuMs, cpuMs / 10))
    if cpuMs > 3 { print("FAIL: thermal sweep over CPU budget (3 ms)"); exit(1) }

    for k in 0..<10 {
        let s = sensors.sample()
        var line = String(format: "%2d  ", k)
        for g in s.groups {
            let v = g.hottest.value.map { String(format: "%5.1f", $0) } ?? "  — "
            line += String(format: "%@ %@%@  ", g.domain.displayName, v,
                           g.parked.isEmpty ? "" : " (\(g.parked.count) parked)")
        }
        line += s.fans.map { String(format: "| fan%d %.0f/%.0f %@", $0.index,
                                    $0.actualRPM ?? -1, $0.targetRPM ?? -1, $0.mode.rawValue) }
            .joined(separator: " ")
        print(line)
        Thread.sleep(forTimeInterval: 1.0)
    }

    let c = CoolingClient()
    print("\nhelper installed: \(c.isInstalled)")
    if c.isInstalled {
        do {
            let st = try c.status()
            print("helper v\(st.helperVersion) forcing=\(st.forcing) ceiling \(Int(st.hardCeilingC)) C "
                  + "limits \(st.limits.sorted { $0.key < $1.key }.map { "fan\($0.key) \(Int($0.value[0]))-\(Int($0.value[1]))" }.joined(separator: " "))")
        } catch {
            print("helper unreachable: \(CoolingController.describe(error))")
        }
    } else {
        print("(read-only — install with tools/install-cooling-helper.sh to enable control)")
    }
    print("PASS")
    exit(0)
}

/// Documents the privilege boundary by walking into it.
///
/// Reads are expected to work as a normal user; the write is a NO-OP — it
/// writes back the value `F0Md` already holds — purely to observe which result
/// byte the SMC returns to an unprivileged caller. That code is the entire
/// reason `aithermald` exists, so it is asserted rather than assumed.
if args.contains("--smc") {
    guard let smc = SMC() else { print("cannot open AppleSMC"); exit(1) }
    let keys = smc.allKeys()
    print("AppleSMC open · \(keys.count) keys enumerated as uid \(getuid())")
    for k in ["#KEY", "FNum", "F0Md", "F0Ac", "F0Mn", "F0Mx", "Tg0X"] {
        let info = smc.info(k)
        let v = smc.readNumber(k)
        print(String(format: "  %-5@ %-5@ %@", k, info?.type ?? "—",
                     v.map { String(format: "%.2f", $0) } ?? "unreadable"))
    }
    guard let mode = smc.readNumber("F0Md") else { print("F0Md unreadable"); exit(1) }
    print(String(format: "\nno-op write: F0Md <- %.0f (the value it already holds)", mode))
    let r = smc.write("F0Md", bytes: SMC.encodeUInt8(UInt8(mode)))
    print("  result: \(r) — \(r.reason)")
    if getuid() == 0 {
        guard r == .ok else { print("FAIL: root write refused"); exit(1) }
    } else {
        guard r == .notPrivileged else {
            print("UNEXPECTED: an unprivileged write was not refused with 0x85."); exit(1)
        }
    }
    print("PASS")
    exit(0)
}

if args.contains("--power") {
    let ps = PowerSource()
    print("thermal      \(PowerSource.thermalState())    onAC(IOPS) \(PowerSource.isOnAC())")
    for k in 0..<12 {
        guard let p = ps.sample() else { print("nil"); break }
        let age = Instant.now() - p.lastChangedAt
        let w = p.watts.value.map { String(format: "%6.2f W", $0) }
              ?? "     —  (\(p.watts.confidence.reason ?? "?"))"
        print(String(format: "%2d  %@   held %5.2fs   batt %5.1f%%  %5.2f C",
                     k, w, age, (p.batteryFraction ?? 0) * 100, p.batteryTempC ?? 0))
        Thread.sleep(forTimeInterval: 1.0)
    }
    exit(0)
}

if args.contains("--discover") {
    // Uses the REAL EndpointRegistry, not a parallel list, so this verifies the
    // code path the app actually runs.
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let reg = EndpointRegistry()
        let t0 = DispatchTime.now().uptimeNanoseconds
        let (runtimes, _) = await reg.refresh()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        print(String(format: "discovery took %.2f ms; found %d runtime(s)\n", ms, runtimes.count))
        for d in runtimes {
            print("\u{2500}\u{2500} \(d.engine.displayName)  pid \(d.generation.pid)  comm=\(d.command)")
            print("   endpoint    \(d.host):\(d.port)\(d.portDisagreement ? "  (argv disagreed; socket wins)" : "")")
            print("   model       \(d.facts.modelName ?? "—")   quant \(d.facts.quantization ?? "—")")
            print("   ctx         requested \(d.facts.requestedContext.map(String.init) ?? "—")  fitted \(d.facts.fittedContext.map(String.init) ?? "—")")
            print("   parallel    \(d.facts.parallelSlots.map(String.init) ?? "—")   spec \(d.facts.speculativeType ?? "—")   apiKey \(d.key != nil)")
            if let ru = ProcSampler.rusage(d.generation.pid) {
                print(String(format: "   memory      footprint %.2f GiB   wired %.2f GiB",
                             Double(ru.ri_phys_footprint)/1073741824, Double(ru.ri_wired_size)/1073741824))
            }
            print("")
        }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 20)
    exit(0)
}

guard let g = gpu.sample(), let m = MachMemory.sample() else {
    print("collector returned nil"); exit(1)
}
func pct(_ v: Double?) -> String { v.map { String(format: "%5.1f%%", $0 * 100) } ?? "    — " }
print("GPU   device \(pct(g.device))  renderer \(pct(g.renderer))  tiler \(pct(g.tiler))")
print("      in use \(gib(g.inUseBytes ?? 0))   alloc \(gib(g.allocBytes ?? 0))   recovery \(g.recoveryCount)")
print("MEM   total  \(gib(m.total))   used  \(gib(m.used))   avail \(gib(m.available))")
print("      wired  \(gib(m.wired))   comp  \(gib(m.compressed))   cache \(gib(m.fileBacked))")
print("      pressure \(m.pressure)   compressions \(m.compressions)")
