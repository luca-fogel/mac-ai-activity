import Foundation

/// Reads LM Studio / Bionic's own view of what is loaded.
///
/// This exists because the MLX backend is invisible to process-based discovery:
/// it runs inside a `node` host as a child of Bionic (observed pid 67042,
/// 2.78 GB RSS), exposes NO listening socket, and speaks Bionic's internal IPC
/// rather than HTTP. There is no /slots, no /props, no port to find.
///
/// So for MLX we can learn *that* a model is resident and generating, and its
/// size and context, but nothing per-token. That asymmetry is reported honestly
/// rather than papered over.
public enum LMStudioProbe {

    public struct Entry: Sendable {
        public var identifier: String
        public var sizeBytes: UInt64
        public var contextLength: Int?
        public var architecture: String?
        /// "gguf" (llama.cpp) or "safetensors" (MLX).
        public var format: String?
        public var status: String?          // "idle" | "generating" | ...

        public var isMLX: Bool { format?.lowercased() == "safetensors" }

        /// States that mean the engine is doing work. LM Studio distinguishes
        /// prompt processing from decoding, and both are work.
        private static let workingStates: Set<String> = [
            "generating", "processingprompt", "processing", "prompt_processing",
        ]

        /// Doing work of any kind, prefill included.
        ///
         /// MEASURED against the live engine: a 4063-token prompt spent
        /// **53.1 s** in `processingPrompt` before a single token was decoded,
        /// against ~12 s of decoding. Matching only "generating" therefore
        /// reported the engine as IDLE for most of the work — and the UI then
        /// called the resulting GPU load "unattributed activity", which is the
        /// exact failure mode this probe was written to remove.
        public var isBusy: Bool {
            guard let s = status?.lowercased(), !s.isEmpty else { return false }
            if Self.workingStates.contains(s) { return true }
            // The status vocabulary is undocumented and has been seen in more
            // than one spelling, so anything not explicitly idle counts as work.
            // Under-reporting busy is the worse error of the two: it hides real
            // activity, whereas over-reporting it is caught downstream by the
            // unattributed-activity check.
            return !s.contains("idle") && !s.contains("loaded")
        }

        /// Decoding specifically, as distinct from prefilling. Kept separate
        /// because the phase boundary is the most interesting thing about MLX:
        /// prefill dominates, and the two regimes look nothing alike.
        public var isDecoding: Bool { status?.lowercased() == "generating" }
        public var isPrefilling: Bool {
            guard let s = status?.lowercased() else { return false }
            return s == "processingprompt" || s == "prompt_processing"
        }

        /// Deprecated spelling, retained so no call site silently changes
        /// meaning: it now answers the question callers actually meant.
        public var isGenerating: Bool { isBusy }
    }

    /// ~240 ms: it spawns a Node CLI. Slow-loop only (0.2 Hz), never interactive.
    public static let defaultCLI =
        ("~/.lmstudio/bin/lms" as NSString).expandingTildeInPath

    /// `cli` is injectable so the absent-CLI path can be exercised in a test;
    /// production always uses the default.
    public static func snapshot(cli: String = LMStudioProbe.defaultCLI,
                                timeout: TimeInterval = 3) -> [Entry] {
        guard FileManager.default.isExecutableFile(atPath: cli) else { return [] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["ps", "--json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }

        // The `timeout:` parameter used to be declared and ignored, leaving two
        // unbounded blocking calls running INSIDE the LiveTelemetryFeed actor —
        // so a hung `lms` would stall every other collector indefinitely, not
        // just this one. A watchdog bounds it at the documented cost.
        let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        deadline.cancel()
        guard p.terminationStatus == 0 else { return [] }

        let obj = try? JSONSerialization.jsonObject(with: data)
        let arr = (obj as? [[String: Any]])
            ?? ((obj as? [String: Any])?["models"] as? [[String: Any]])
            ?? []
        return arr.compactMap { m in
            guard let id = m["identifier"] as? String else { return nil }
            return Entry(
                identifier: id,
                sizeBytes: (m["sizeBytes"] as? NSNumber)?.uint64Value ?? 0,
                contextLength: (m["contextLength"] as? NSNumber)?.intValue,
                architecture: m["architecture"] as? String,
                format: m["format"] as? String,
                status: m["status"] as? String)
        }
    }
}
