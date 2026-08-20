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
