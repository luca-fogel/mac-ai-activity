import Foundation

/// Jan's process topology, which is not the shape the rest of this app assumes.
///
/// Every other engine here is one process holding one model on one port. Jan
/// 0.8.4 runs llama.cpp in **router mode** (llama.cpp b9967+), which is three
/// tiers:
///
///   Jan.app (Tauri)                          — the UI, holds no weights
///     └── llama-server --models-preset …     — the ROUTER, holds no weights
///           ├── llama-server --alias A …     — instance A, its own port
///           └── llama-server --alias B …     — instance B, its own port
///
/// Every consequence of that shape is a way to get a wrong number:
///
/// 1. **The router is not a model server.** Its `/props` reports
///    `"role":"router"`, `model_path: "none"` and `n_ctx: 0`. Reading it as a
///    model server yields a runtime that appears to hold a 0-token context.
///
/// 2. **The router's `/slots` cannot be polled.** In router mode it answers
///    `400 "model name is missing from the request"` unless a `?model=` is
///    supplied. Naming a model is not a read-only act — see `loadHazard`.
///
/// 3. **The instance ports are ephemeral and appear nowhere in config.** The
///    router launches children with `--port 0`, so the kernel assigns one.
///    They are discoverable only from the child's own argv and listening
///    socket. (MEASURED: router on 61378, children on 52477 and 52550.)
///
/// 4. **The API key is in the environment, not argv.** See `ProcArgs`.
///
/// 5. **`--models-max` instances are resident at once.** Two children held
///    45 MB and 3.0 GB respectively while the router held 45 MB, so
///    attributing Jan's memory to the process that owns the port reports
///    ~1.5% of what Jan is actually holding.
public struct JanTopology: Sendable {

    /// One llama-server child: a single model, on its own port.
    public struct Instance: Sendable, Identifiable {
        public var pid: Int32
        public var startedAt: UInt64
        public var port: UInt16
        public var host: String
        /// The model id, from `--alias`. This is the string /v1/models and the
        /// router log both use, so it is the join key across all three sources.
        public var alias: String
        public var facts: ArgvFacts
        /// Whether this child is the embedding model. Jan preloads
        /// `sentence-transformer-mini` at startup and it is `--embeddings`, so
        /// it never decodes a token — counting it as an idle generation engine
        /// makes Jan look permanently loaded and never busy.
        public var isEmbedding: Bool

        public var id: Int32 { pid }
    }

    /// The router process. Present whenever Jan's llama.cpp engine is up, even
    /// with no model loaded at all.
    public var routerPID: Int32
    public var routerStartedAt: UInt64
    public var routerHost: String
    public var routerPort: UInt16
    /// Read from the router's environment. Children inherit it, so this one
    /// key authenticates every tier.
    public var key: APIKey?
    public var facts: ArgvFacts
    public var instances: [Instance]

    /// Every pid Jan's llama.cpp engine occupies, router included. Memory and
    /// CPU must be summed over all of these; the router alone accounts for
    /// almost none of it.
    public var allPIDs: [Int32] { [routerPID] + instances.map { $0.pid } }

    /// Instances that can actually generate tokens.
    public var generativeInstances: [Instance] { instances.filter { !$0.isEmbedding } }

    /// Why the router's own /slots must never be polled, stated for the UI
    /// rather than left as a silent rule in the collector.
    ///
    /// This app's central promise is that it is observe-only. In router mode
    /// that promise is conditional: `models_autoload` is true, so a request
    /// naming an unloaded model MAKES THE ROUTER LOAD IT. MEASURED — a single
    /// `GET /props?model=sentence-transformer-mini` against an idle router
    /// spawned a child server and logged `ensure_model: waiting until model
    /// name=sentence-transformer-mini is fully loaded`. The same call against
    /// a 3 GB model would have read 3 GB off disk and into the GPU because a
    /// monitor asked a question. So Jan's roster is read from `/v1/models`,
    /// which needs no model name and no key, and slot telemetry is read from
    /// the children's own ports, where `/slots` is unproxied, needs no
    /// `?model=`, and cannot load anything.
    public static let loadHazard =
        "router /slots and /props require ?model=, and naming an unloaded model makes the router load it (models_autoload) — instance ports are read instead"

    /// The same fact, short enough for a table cell. The full statement lives in
    /// the Sources inspector, where there is room for it.
    public static let routerRowNote = "holds no weights — telemetry is on the instance ports"

    /// `/metrics` is not merely absent under Jan, it is refused: the router
    /// answers 501 `This server does not support metrics endpoint. Start it
    /// with --metrics`, and Jan passes no such flag to the router or to any
    /// child. So the Prometheus counters — which would have given exact
    /// per-request token totals with no polling at all — are unavailable, and
    /// nothing the app does can change that.
    public static let metricsGap =
        "Jan starts llama-server without --metrics, so /metrics answers 501 on the router and on every instance"

    // MARK: - Recognition

    /// Jan's llama-server lives inside Jan's own data folder. Matching on the
    /// path and not just the process name is what keeps Jan and Bionic apart:
    /// both spawn a bundled binary literally named `llama-server`, and the
    /// registry keys its cache by engine, so misfiling one as the other made
    /// the two overwrite each other's descriptor on every scan — a permanent
    /// generation change, which tears down the slot state machines and resets
    /// every derived rate once a second.
    static let marker = "/Jan/data/llamacpp/"

    public static func isJan(_ info: ProcArgs.Info) -> Bool {
        if info.executable.contains(marker) { return true }
        return info.argv.first?.contains(marker) ?? false
    }

    /// Builds the topology from a router candidate, discovering its children
    /// by parent pid.
    ///
    /// Children are found via ppid rather than by scanning for `--alias`,
    /// because ppid is what makes them *this* router's children. Two Jan
    /// versions, or a stale orphaned child, would otherwise be merged into one
    /// roster.
    public static func build(routerPID: Int32,
                            routerStartedAt: UInt64,
                            routerInfo: ProcArgs.Info,
                            routerPort: UInt16,
                            children: [Int32]) -> JanTopology {
        let facts = ArgvFacts.parse(routerInfo.argv)
        let key = ArgvFacts.apiKey(routerInfo.argv, env: routerInfo.env).map(APIKey.init)

        var instances: [Instance] = []
        for pid in children {
            guard let info = ProcArgs.read(pid), isJan(info) else { continue }
            let f = ArgvFacts.parse(info.argv)
            // A child without an alias is not addressable in any of the three
            // sources, so it cannot be joined to a roster row.
            guard let alias = f.modelAlias else { continue }
            let ports = ProcSockets.listeningPorts(pid)
            // `--port 0` means the kernel chose; argv's 0 is never the answer,
            // so the socket is the only truth here.
            guard let port = ports.first(where: { $0 != 0 }) else { continue }
            guard let started = ProcSampler.startedAt(pid) else { continue }
            instances.append(Instance(
                pid: pid, startedAt: started, port: port,
                host: f.host ?? "127.0.0.1", alias: alias, facts: f,
                isEmbedding: info.argv.contains("--embeddings")))
        }

        return JanTopology(
            routerPID: routerPID, routerStartedAt: routerStartedAt,
            routerHost: facts.host ?? "127.0.0.1", routerPort: routerPort,
            key: key, facts: facts,
            instances: instances.sorted { $0.alias < $1.alias })
    }
}
