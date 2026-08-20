import Foundation
import Telemetry

// Line-buffer: this is meant to be piped or watched, and libc block-buffers a
// non-TTY stdout by default, which makes a live tool appear dead.
setvbuf(stdout, nil, _IOLBF, 0)

/// `aienergy` — what a local generation cost, in joules per token.
///
/// This exists because LM Studio already shows tok/s and TTFT, and shows them
/// well. The one question it cannot answer is energy: it has no power data at
/// all. So this tool does exactly the part that is not already covered, and
/// nothing else.
///
/// How it works: `lms log stream --json --stats` pushes a receipt when a
/// prediction FINISHES, including `totalTimeSec`. That gives the generation's
/// window exactly — in retrospect — so wattage sampled continuously in the
/// background can be integrated over precisely that interval. Retrospective is
/// not a limitation here; it is what makes the window exact.

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    aienergy — energy per token for local model generations

    USAGE
      aienergy watch            follow generations as they finish (default)
      aienergy status           one-shot: what is loaded, power, idle floor
      aienergy --json           emit NDJSON instead of a table
      aienergy --help

    Reads whole-system wattage from AppleSmartBattery (root-free) and
    prediction stats from `lms log stream`. Nothing is written anywhere and no
    generation is ever initiated by this tool.

    NOTES
      * Wattage is unavailable on AC: battery amperage reflects charging
        current, not system load. Unplug to measure energy.
      * Stats arrive when a prediction ENDS, so a row appears after the
        generation, not during it.
      * Prompt and completion text are never read.
    """)
    exit(0)
}

if args.contains("--help") || args.contains("-h") { usage() }
let asJSON = args.contains("--json")
let command = args.first { !$0.hasPrefix("-") } ?? "watch"

// MARK: - Shared sampling

/// Samples power in the background at the rate the source actually refreshes.
///
/// 1 Hz, not the GUI's 0.2 Hz: the underlying values change every ~4 s, and
/// oversampling costs nothing measurable while tightening the interpolation at
/// the window endpoints.
actor Sampler {
    private let power = PowerSource()
    private(set) var trace = PowerTrace()
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func tick() {
        guard let s = power.sample() else { return }
        trace.note(s.watts.value, at: Instant.now())
    }

    /// Takes a reading right now.
    ///
     /// Called the moment a receipt arrives, because the generation ended at
    /// that instant while our last scheduled sample was up to one interval
    /// earlier. MEASURED: without this, every window failed its coverage check
    /// with "power trace ends 0.5s before this generation finished" and no
    /// energy was ever reported. Closing the window with a real measurement is
    /// the honest fix; extrapolating past the last sample would not be.
    func sampleNow() {
        guard let s = power.sample() else { return }
        trace.note(s.watts.value, at: Instant.now())
    }

    func stop() { task?.cancel(); task = nil }

    func energy(from: Instant, to: Instant) -> Estimate<Double> {
        trace.energy(from: from, to: to)
    }
    func mean(from: Instant, to: Instant) -> Double? { trace.meanWatts(from: from, to: to) }
    func markBusy(from: Instant, to: Instant) { trace.markBusy(from: from, to: to) }
    var floor: Estimate<Double> { trace.idleFloor }
    var latest: PowerTrace.Reading? { trace.latest }
    var readings: Int { trace.count }
    var currentSample: PowerSource.Stats? { power.sample() }
}

let sampler = Sampler()

/// Reachable from the SIGINT handler so the child gets terminated on ^C.
/// nonisolated(unsafe): written once before the handler can run, then only read.
nonisolated(unsafe) var activeStream: LMSLogStream?

func fmt(_ v: Double?, _ spec: String) -> String {
    guard let v else { return "—" }
    return String(format: spec, v)
}

/// Right-pads to a column width, counting characters rather than bytes so an
/// em-dash does not shift the column.
func pad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
}
func lpad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
}

// MARK: - status

if command == "status" {
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let loaded = LMStudioProbe.snapshot()
        print("MODELS RESIDENT")
        if loaded.isEmpty {
            print("  none — `lms load <model>` or use the LM Studio GUI")
        }
        for m in loaded {
            let gb = Double(m.sizeBytes) / 1_073_741_824
            print("  \(m.identifier)")
            print("    \(m.isMLX ? "MLX" : "llama.cpp") · \(String(format: "%.2f GB", gb))"
                  + " · ctx \(m.contextLength.map(String.init) ?? "?")"
                  + " · \(m.isBusy ? "working" : "idle")")
        }

        let stats = await sampler.currentSample
        print("\nPOWER")
        if let w = stats?.watts.value {
            print("  \(String(format: "%.1f W", w))  (\(stats?.source ?? "unknown source"))")
        } else {
            print("  unavailable — \(stats?.watts.confidence.reason ?? "no reading")")
            print("  energy per token needs battery power; unplug to measure it.")
        }
        if let t = stats?.batteryTempC {
            print("  battery \(String(format: "%.1f °C", t)) · sensor, not SoC")
        }
        print("  thermal \(PowerSource.thermalState().rawValue)")

        let stream = LMSLogStream()
        print("\nTELEMETRY")
        print("  lms \(await stream.isAvailable ? "found" : "NOT FOUND") at \(LMSLogStream.defaultCLI)")
        print("  \(LMSLogStream.arguments.joined(separator: " "))")
        sem.signal()
    }
    sem.wait()
    exit(0)
}

guard command == "watch" else {
    FileHandle.standardError.write("unknown command '\(command)' — try --help\n".data(using: .utf8)!)
    exit(2)
}

// MARK: - watch

let sem = DispatchSemaphore(value: 0)

Task.detached {
    await sampler.start()

    let stream = LMSLogStream()
    activeStream = stream
    guard await stream.isAvailable else {
        FileHandle.standardError.write(
            "lms not found at \(LMSLogStream.defaultCLI) — is LM Studio installed?\n"
                .data(using: .utf8)!)
        exit(1)
    }

    if !asJSON {
        // A header, then one row per generation. No redraw, no cursor games:
        // scrollback IS the history, and it survives being piped to a file.
        print(pad("MODEL", 22) + lpad("TOK", 6) + lpad("TOK/S", 8)
              + lpad("TTFT", 9) + lpad("W avg", 8) + lpad("J/TOK", 9) + "  NOTE")
        FileHandle.standardError.write("watching for generations — ^C to stop\n".data(using: .utf8)!)
    }

    await stream.start()

    for await event in stream.events {
        guard case .prediction(let p) = event else { continue }

        // The receipt's own duration defines the window. `t` is when the receipt
        // was parsed, i.e. the end; totalTimeSec reaches back to the start.
        var energy: Estimate<Double> = .unavailable("no duration reported")
        var meanW: Double?
        // Close the window with a reading taken now, before integrating.
        await sampler.sampleNow()
        // NOT p.totalSeconds — see PredictionSample.observedDuration; the
        // engine's own field reported 0.002 s for a 2.2 s generation.
        if let dur = p.observedDuration.value, dur > 0 {
            let from = Instant(p.t.s - dur)
            energy = await sampler.energy(from: from, to: p.t)
            meanW = await sampler.mean(from: from, to: p.t)
            await sampler.markBusy(from: from, to: p.t)
        }

        // J/token: the whole point. Only when BOTH inputs are real.
        var jpt: Double?
        if let e = energy.value, let n = p.predictedTokens, n > 0 { jpt = e / Double(n) }

        if asJSON {
            // Deliberately hand-rolled: no prompt or completion field can exist
            // by accident, because none is ever populated.
            var o: [String: Any] = [
                "model": p.modelIdentifier,
                "stop_reason": p.stopReason,
                "source": p.source,
            ]
            o["predicted_tokens"] = p.predictedTokens
            o["prompt_tokens"] = p.promptTokens
            o["tokens_per_second"] = p.tokensPerSecond.value
            o["ttft_seconds"] = p.timeToFirstToken.value
            o["total_seconds_reported"] = p.totalSeconds
            o["duration_seconds"] = p.observedDuration.value
            o["duration_basis"] = p.observedDuration.confidence == .high
                ? "engine totalTimeSec" : "ttft + tokens/rate"
            o["joules"] = energy.value
            o["mean_watts"] = meanW
            o["joules_per_token"] = jpt
            if energy.value == nil { o["energy_unavailable"] = energy.confidence.reason }
            if let d = await sampler.floor.value { o["idle_watts_floor"] = d }
            if let data = try? JSONSerialization.data(withJSONObject: o),
               let s = String(data: data, encoding: .utf8) { print(s) }
        } else {
            var note = ""
            if energy.value == nil { note = energy.confidence.reason ?? "" }
            else if let f = await sampler.floor.value, let m = meanW, m - f > 0.1 {
                note = String(format: "+%.1f W over idle", m - f)
            }
            let model = p.modelIdentifier.count > 21
                ? String(p.modelIdentifier.suffix(21)) : p.modelIdentifier
            print(pad(model, 22)
                  + lpad(p.predictedTokens.map(String.init) ?? "—", 6)
                  + lpad(fmt(p.tokensPerSecond.value, "%.1f"), 8)
                  + lpad(fmt(p.timeToFirstToken.value, "%.2fs"), 9)
                  + lpad(fmt(meanW, "%.1f"), 8)
                  + lpad(fmt(jpt, "%.3f"), 9)
                  + "  " + note)
        }
    }
    sem.signal()
}

// SIGINT via a source rather than a handler: the default disposition would kill
// us before LMSLogStream can terminate its child.
//
// The queue is NOT `.main`, and that is the whole point. MEASURED: on `.main`
// the handler never ran at all, because the main thread blocks in `sem.wait()`
// below and so never services the main queue — and since SIGINT is SIG_IGN'd
// for the source to work, ^C became a no-op and the tool could not be stopped.
// It looked like a leaked child process; the child was simply still legitimately
// running, because nothing had asked it to stop.
//
// SIG_IGN is installed BEFORE the source is resumed, so there is no window in
// which the default terminate-immediately disposition is still in force.
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
sigint.setEventHandler {
    Task {
        await sampler.stop()
        // Stopping the stream is what SIGTERMs the child. Exiting without it
        // left `lms log stream` running until its watchdog noticed — and it
        // holds a subscription to every prompt on the machine, so "eventually"
        // is not good enough.
        await activeStream?.stop()
        if !asJSON, let f = await sampler.floor.value {
            print(String(format: "\nidle floor %.1f W over %d readings", f, await sampler.readings))
        }
        exit(0)
    }
}
sigint.resume()

sem.wait()
