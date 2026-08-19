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
        public var isGenerating: Bool { status?.lowercased() == "generating" }
    }

    /// ~240 ms: it spawns a Node CLI. Slow-loop only (0.2 Hz), never interactive.
    public static func snapshot(timeout: TimeInterval = 3) -> [Entry] {
        let cli = ("~/.lmstudio/bin/lms" as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: cli) else { return [] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["ps", "--json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
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
