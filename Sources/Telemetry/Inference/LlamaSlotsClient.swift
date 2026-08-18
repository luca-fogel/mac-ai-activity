import Foundation

/// Reads llama-server's /slots and /props.
///
/// /metrics is NOT usable here: Bionic does not pass --metrics, so it returns
/// HTTP 501 and /props reports `endpoint_metrics: false`. /slots is therefore
/// the only per-request telemetry source — and it costs 100-450 ms per call
/// because it is serialized behind the decode loop, which is why the caller
/// must never poll it faster than ~1 Hz and must enforce a single in-flight
/// request.
public actor LlamaSlotsClient {

    public struct RawSlot: Sendable {
        public var id: Int
        public var isProcessing: Bool
        public var nCtx: Int
        public var speculative: Bool
        public var idTask: Int?
        public var nPromptTokens: Int?
        public var nPromptTokensProcessed: Int?
        public var nPromptTokensCache: Int?
        public var nDecoded: Int?
        public var nRemain: Int?
        public var hasNextToken: Bool?
        public var sampler: SamplerParams?
        public var specTypes: String?
        /// True when the payload carried token counters at all. A slot that has
        /// never run a request exposes only [id, is_processing, n_ctx,
        /// speculative] — we must be able to tell that apart from a slot whose
        /// counters are merely frozen.
        public var hasCounters: Bool
    }

    public struct Props: Sendable {
        public var modelPath: String?
        public var nCtx: Int?
        public var totalSlots: Int?
        public var endpointMetrics: Bool
    }

    private let session: URLSession
    private let base: URL
    private let key: APIKey?

    public init(host: String, port: UInt16, key: APIKey?, timeout: TimeInterval) {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 1      // never queue polls on a busy server
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: c)
        self.base = URL(string: "http://\(host):\(port)")!
        self.key = key
    }

    private func get(_ path: String) async throws -> (Data, Int) {
        var r = URLRequest(url: base.appendingPathComponent(path))
        if let k = key { r.setValue(k.headerValue, forHTTPHeaderField: "Authorization") }
        r.httpMethod = "GET"
        let (d, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (d, code)
    }

    public func health() async throws -> Bool {
        let (_, code) = try await get("health")
        return code == 200
    }

    public func props() async throws -> Props {
        let (raw, code) = try await get("props")
        guard code == 200 else { throw Err.http(code) }
        let fixed = LenientJSON.repair(raw)
        guard let o = try JSONSerialization.jsonObject(with: fixed.data) as? [String: Any]
        else { throw Err.decode("props not an object") }
        let dgs = o["default_generation_settings"] as? [String: Any]
        return Props(
            modelPath: o["model_path"] as? String ?? o["model"] as? String,
            nCtx: (dgs?["n_ctx"] as? Int) ?? (o["n_ctx"] as? Int),
            totalSlots: o["total_slots"] as? Int,
            endpointMetrics: (o["endpoint_metrics"] as? Bool) ?? false)
    }

    public func slots() async throws -> (slots: [RawSlot], repairs: Int) {
        let (raw, code) = try await get("slots")
        guard code == 200 else { throw Err.http(code) }
        let fixed = LenientJSON.repair(raw)
        guard let arr = try JSONSerialization.jsonObject(with: fixed.data) as? [[String: Any]]
        else { throw Err.decode("slots not an array") }
        return (arr.map(Self.parseSlot), fixed.repairs)
    }

    static func parseSlot(_ o: [String: Any]) -> RawSlot {
        // n_decoded is NESTED at next_token[0].n_decoded, not top level.
        var nDecoded: Int?, nRemain: Int?, hasNext: Bool?
        if let nt = o["next_token"] as? [[String: Any]], let f = nt.first {
            nDecoded = f["n_decoded"] as? Int
            nRemain  = f["n_remain"] as? Int
            hasNext  = f["has_next_token"] as? Bool
        } else if let nt = o["next_token"] as? [String: Any] {
            nDecoded = nt["n_decoded"] as? Int
            nRemain  = nt["n_remain"] as? Int
            hasNext  = nt["has_next_token"] as? Bool
        }
        let params = o["params"] as? [String: Any]
        return RawSlot(
            id: o["id"] as? Int ?? -1,
            isProcessing: o["is_processing"] as? Bool ?? false,
            nCtx: o["n_ctx"] as? Int ?? 0,
            speculative: o["speculative"] as? Bool ?? false,
            idTask: o["id_task"] as? Int,
            nPromptTokens: o["n_prompt_tokens"] as? Int,
            nPromptTokensProcessed: o["n_prompt_tokens_processed"] as? Int,
            nPromptTokensCache: o["n_prompt_tokens_cache"] as? Int,
            nDecoded: nDecoded,
            nRemain: nRemain,
            hasNextToken: hasNext,
            sampler: params.map(Self.parseSampler),
            specTypes: params?["speculative.types"] as? String,
            hasCounters: o["n_prompt_tokens"] != nil || o["id_task"] != nil)
    }

    static func parseSampler(_ p: [String: Any]) -> SamplerParams {
        func d(_ k: String) -> Double? { (p[k] as? NSNumber)?.doubleValue }
        func i(_ k: String) -> Int? { (p[k] as? NSNumber)?.intValue }
        let handled: Set<String> = ["temperature", "top_k", "top_p", "min_p", "typical_p",
            "repeat_penalty", "repeat_last_n", "frequency_penalty", "presence_penalty",
            "mirostat", "n_predict", "seed", "samplers"]
        var extra: [String: String] = [:]
        for (k, v) in p where !handled.contains(k) { extra[k] = String(describing: v) }
        return SamplerParams(
            temperature: d("temperature"), topK: i("top_k"), topP: d("top_p"),
            minP: d("min_p"), typicalP: d("typical_p"), repeatPenalty: d("repeat_penalty"),
            repeatLastN: i("repeat_last_n"), frequencyPenalty: d("frequency_penalty"),
            presencePenalty: d("presence_penalty"), mirostat: i("mirostat"),
            nPredict: i("n_predict"),
            seed: (p["seed"] as? NSNumber)?.uint32Value,
            samplerChain: (p["samplers"] as? [String]) ?? [],
            extra: extra)
    }

    public enum Err: Error, Sendable {
        case http(Int)
        case decode(String)
    }
}
