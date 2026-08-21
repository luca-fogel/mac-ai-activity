import Foundation

/// Reads the llama.cpp router's model catalogue.
///
/// This is the one Jan endpoint that is both unauthenticated and free of side
/// effects, and it is therefore the only one this app asks the router directly.
/// MEASURED against a live Jan 0.8.4 router:
///
///   GET /health      → 200  {"status":"ok"}                    no key needed
///   GET /v1/models   → 200  full catalogue + per-model status  no key needed
///   GET /props       → 401  without the key; 200 with it, `"role":"router"`
///   GET /slots       → 401  without the key; 400 with it (needs ?model=)
///   GET /metrics     → 401  without the key; 501 with it (no --metrics)
///
/// `/v1/models` is richer than a model list: each entry carries a `status`
/// object holding the CURRENT residency (`loaded` / `unloaded`) and the exact
/// argv the router would launch — or did launch — that model with. So the
/// catalogue answers "what could run, what is running, and with what settings"
/// without touching a single model.
///
/// Crucially it takes no `?model=` parameter, so unlike /props and /slots it
/// cannot trigger an on-demand load. See `JanTopology.loadHazard`.
public actor JanRouterClient {

    /// A model as the router understands it — which is not the same as a model
    /// that is running. `residency == .unloaded` entries have no process, no
    /// port and no slots, and must be rendered as available rather than idle.
    public struct CatalogEntry: Sendable {
        public enum Residency: String, Sendable {
            case loaded, unloaded, loading, unknown
        }
        public var id: String
        public var residency: Residency
        /// Parsed from the argv the router associates with this model. Present
        /// even when the model is unloaded, which is how the app can state a
        /// context window for a model that has never run.
        public var facts: ArgvFacts
        public var isEmbedding: Bool
    }

    private let session: URLSession
    private let base: URL

    public init(host: String, port: UInt16, timeout: TimeInterval = 2.0) {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 1
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: c)
        self.base = URL(string: "http://\(host):\(port)")!
    }

    /// The catalogue. No key, no model name, no side effects.
    public func catalogue() async throws -> [CatalogEntry] {
        var r = URLRequest(url: base.appendingPathComponent("v1/models"))
        r.httpMethod = "GET"
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LlamaSlotsClient.Err.http(code) }

        let fixed = LenientJSON.repair(data)
        guard let o = try JSONSerialization.jsonObject(with: fixed.data) as? [String: Any],
              let arr = o["data"] as? [[String: Any]]
        else { throw LlamaSlotsClient.Err.decode("v1/models has no data array") }

        return arr.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let status = m["status"] as? [String: Any]
            let argv = (status?["args"] as? [String]) ?? []
            let facts = ArgvFacts.parse(argv)
            return CatalogEntry(
                id: id,
                residency: CatalogEntry.Residency(
                    rawValue: (status?["value"] as? String) ?? "") ?? .unknown,
                facts: facts,
                isEmbedding: argv.contains("--embeddings"))
        }
    }

    /// Liveness only. Unauthenticated, so a 200 here plus a 401 elsewhere
    /// distinguishes "router up, key unreadable" from "router down" — two
    /// states that otherwise both present as silence.
    public func health() async throws -> Bool {
        var r = URLRequest(url: base.appendingPathComponent("health"))
        r.httpMethod = "GET"
        let (_, resp) = try await session.data(for: r)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0) == 200
    }
}
