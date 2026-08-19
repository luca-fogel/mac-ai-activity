import Foundation

/// Per-request telemetry for mlx-lm, read from its log.
///
/// mlx-lm's HTTP server has no /slots and no /metrics — the only endpoints are
/// /health and /v1/models. But at INFO level it logs prompt-processing progress
/// and prompt-cache state, and at DEBUG it logs the response body including
/// `usage`. Tailing that is observe-only and gives prefill progress, cache
/// reuse and token counts — the same quantities /slots provides for llama.cpp,
/// just from a different source.
///
/// Requires the server to be started with its output redirected to
/// `~/.local/state/mlx-lm/server.log` (see tools/mlx-serve.sh).
public final class MLXLogTailer: @unchecked Sendable {

    public struct State: Sendable {
        public var promptProcessed: Int?
        public var promptTotal: Int?
        public var completionTokens: Int?
        public var cachedTokens: Int?
        public var cacheSequences: Int?
        public var cacheGB: Double?
        public var lastActivityAt: Instant?
        /// True while prompt-processing lines are still arriving.
        public var prefilling: Bool = false
        public var requestsSeen: Int = 0
    }

    public static let defaultPath = (
        "~/.local/state/mlx-lm/server.log" as NSString).expandingTildeInPath

    private let path: String
    private var offset: UInt64 = 0
    private var carry = ""
    private var state = State()

    public init(path: String = MLXLogTailer.defaultPath) {
        self.path = path
        // Start at the end: we report live behaviour, not history.
        if let a = try? FileManager.default.attributesOfItem(atPath: path),
           let size = a[.size] as? UInt64 { offset = size }
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// Reads whatever is new. Cheap: a seek plus a short read, no re-parsing.
    public func poll(now: Instant) -> State {
        guard let fh = FileHandle(forReadingAtPath: path) else { return state }
        defer { try? fh.close() }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let size = attrs?[.size] as? UInt64 else { return state }
        if size < offset { offset = 0; carry = "" }   // rotated or truncated
        guard size > offset else {
            // No new lines: prefill is over once the log goes quiet.
            if let last = state.lastActivityAt, now - last > 2 { state.prefilling = false }
            return state
        }

        try? fh.seek(toOffset: offset)
        let data = (try? fh.readToEnd()) ?? Data()
        offset = size

        let text = carry + String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        carry = lines.popLast() ?? ""          // keep the partial line

        for line in lines { ingest(line, now: now) }
        return state
    }

    private func ingest(_ line: String, now: Instant) {
        if let r = line.range(of: #"Prompt processing progress:\s*(\d+)/(\d+)"#,
                              options: .regularExpression) {
            let nums = line[r].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if nums.count >= 2 {
                state.promptProcessed = nums[0]
                state.promptTotal = nums[1]
                state.prefilling = nums[0] < nums[1]
                state.lastActivityAt = now
                state.completionTokens = nil     // new request: clear the old count
            }
            return
        }
        if let r = line.range(of: #"Prompt Cache:\s*(\d+) sequences,\s*([\d.]+) GB"#,
                              options: .regularExpression) {
            let f = line[r]
            let ints = f.split(whereSeparator: { !$0.isNumber && $0 != "." }).map(String.init)
            state.cacheSequences = ints.first.flatMap { Int($0) }
            state.cacheGB = ints.count > 1 ? Double(ints[1]) : nil
            state.lastActivityAt = now
            return
        }
        if let v = Self.jsonInt(line, key: "completion_tokens") {
            state.completionTokens = v
            state.prefilling = false
            state.requestsSeen += 1
            state.lastActivityAt = now
            return
        }
        if let v = Self.jsonInt(line, key: "cached_tokens") {
            state.cachedTokens = v; state.lastActivityAt = now; return
        }
        if let v = Self.jsonInt(line, key: "prompt_tokens"), state.promptTotal == nil {
            state.promptTotal = v; state.lastActivityAt = now
        }
    }

    /// The log pretty-prints the response body, so keys sit on their own lines.
    static func jsonInt(_ line: String, key: String) -> Int? {
        guard let r = line.range(of: "\"\(key)\"") else { return nil }
        let rest = line[r.upperBound...]
        let digits = rest.drop { !$0.isNumber }.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}
