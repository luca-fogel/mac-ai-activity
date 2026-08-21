import Foundation

/// A discovered inference server, identified by a generation that changes
/// whenever the process is re-spawned.
public struct RuntimeDescriptor: Sendable {
    public var engine: EngineID
    public var generation: EndpointGeneration
    public var host: String
    public var port: UInt16
    public var key: APIKey?
    public var facts: ArgvFacts
    public var command: String
    /// True when argv named a port that is not in the listening set: the
    /// server fell back, and argv is now a lie. The socket wins.
    public var portDisagreement: Bool
}

/// Process-driven discovery.
///
/// Config files are a trap here: ~/.lmstudio/.internal/http-server-config.json
/// advertises port 1234 while the actual llama-server is on an ephemeral port
/// with an ephemeral API key, both visible only in argv. So the scan is the
/// source of truth, and it re-runs every second because that is affordable
/// (~0.9 ms for 530 same-uid pids) and bounds the blind window after a restart.
public actor EndpointRegistry {

    private var cache: [EngineID: RuntimeDescriptor] = [:]
    private var seen: Set<Int32> = []
    private var jan: JanTopology?
    /// pid -> the engine it was classified as, valid for that pid's start time.
    ///
    /// Exists because `comm` is no longer sufficient. Jan and Bionic both run a
    /// bundled binary named exactly `llama-server`, so separating them needs
    /// argv, and argv must therefore be read for llama-server processes on
    /// EVERY scan rather than only for new generations. Caching the verdict per
    /// (pid, startTime) keeps that at one sysctl per process per lifetime.
    private var classified: [Int32: (started: UInt64, engine: EngineID?)] = [:]

    /// `llama-server` is deliberately absent: it is ambiguous and resolved by
    /// `classifyLlamaServer`.
    private static let known: [(prefix: String, engine: EngineID)] = [
        ("local-ai", .localai),
        ("ollama", .ollama),
    ]

    /// Servers that run inside an interpreter have a useless `comm` -- mlx-lm
    /// reports "Python". Reading argv for all ~360 same-uid processes would
    /// cost ~470 ms, so argv is consulted ONLY for interpreters, and only for
    /// pids we have not already classified.
    private static let interpreters = ["Python", "python", "node", "uv", "ruby"]
    private static let argvPatterns: [(needle: String, engine: EngineID)] = [
        ("mlx_lm.server", .mlxlm),
        ("mlx_lm/server", .mlxlm),
        ("vllm.entrypoints", .mlxlm),
    ]

    public init() {}

    /// Which engine a `llama-server` process belongs to, and whether it should
    /// be a runtime at all.
    ///
    /// Three outcomes, and conflating any two of them produces a wrong reading:
    ///
    ///   * **Bionic's** llama-server — a model server. A runtime.
    ///   * **Jan's router** — holds no weights, exposes no pollable /slots. A
    ///     runtime, because it is what is *running*, but its telemetry is
    ///     elsewhere.
    ///   * **Jan's model children** — real model servers, but they are
    ///     discovered through the router by ppid, not independently. Returning
    ///     them here would have each child overwrite `.jan` in a
    ///     dictionary keyed by engine, so the descriptor would flap between
    ///     children once a second and every derived rate would reset with it.
    private func classifyLlamaServer(_ pid: Int32, cachedInfo: inout ProcArgs.Info?)
        -> EngineID? {
        guard let info = ProcArgs.read(pid) else { return nil }
        cachedInfo = info
        guard JanTopology.isJan(info) else { return .bionic }
        return ArgvFacts.parse(info.argv).isRouter ? .jan : nil
    }

    /// Returns the current descriptors and the set of engines whose generation
    /// changed since the last scan (callers must tear down derived state for
    /// those — carrying counters across a re-spawn produces a garbage spike).
    public func refresh() -> (runtimes: [RuntimeDescriptor], changed: Set<EngineID>) {
        var found: [EngineID: RuntimeDescriptor] = [:]
        var changed: Set<EngineID> = []
        var janRouterInfo: ProcArgs.Info?
        var janRouterPID: Int32?

        let scanned = ProcSampler.scan()
        for b in scanned {
            var engine = Self.known.first { b.comm.hasPrefix(String($0.prefix.prefix(15))) }?.engine
            var interpreterArgv: ProcArgs.Info?

            if engine == nil, b.comm.hasPrefix("llama-server") {
                let started = ProcSampler.startedAt(b.pid)
                if let c = classified[b.pid], c.started == started {
                    engine = c.engine
                    // A cached nil is a Jan child: known, and deliberately not
                    // a runtime of its own.
                    if engine == nil { continue }
                    if engine == .jan { janRouterInfo = ProcArgs.read(b.pid); janRouterPID = b.pid }
                } else {
                    var info: ProcArgs.Info?
                    engine = classifyLlamaServer(b.pid, cachedInfo: &info)
                    classified[b.pid] = (started ?? 0, engine)
                    interpreterArgv = info
                    if engine == nil { continue }
                    if engine == .jan { janRouterInfo = info; janRouterPID = b.pid }
                }
            }

            if engine == nil, Self.interpreters.contains(where: { b.comm.contains($0) }) {
                // Cheap enough: only a handful of interpreters are running, and
                // the result is cached per (pid, startTime) generation.
                if let info = ProcArgs.read(b.pid),
                   let hit = Self.argvPatterns.first(where: { pat in
                       info.argv.contains { $0.contains(pat.needle) }
                   }) {
                    engine = hit.engine
                    interpreterArgv = info
                }
            }
            guard let engine else { continue }
            // Prefer the process that is actually listening.
            let ports = ProcSockets.listeningPorts(b.pid)
            guard !ports.isEmpty else { continue }
            guard let started = ProcSampler.startedAt(b.pid) else { continue }

            let existing = cache[engine]
            let sameGeneration = existing?.generation.pid == b.pid
                && existing?.generation.startedAt == started

            if sameGeneration, var d = existing {
                d.port = ports.contains(d.port) ? d.port : ports[0]
                found[engine] = d
                continue
            }

            // New generation: enrich. This is the only place argv is read.
            let info = interpreterArgv ?? ProcArgs.read(b.pid)
            let facts = info.map { ArgvFacts.parse($0.argv) } ?? ArgvFacts()
            let key = info.flatMap { ArgvFacts.apiKey($0.argv, env: $0.env) }.map(APIKey.init)
            let argvPort = facts.port
            let port = (argvPort.flatMap { ports.contains($0) ? $0 : nil }) ?? ports[0]

            found[engine] = RuntimeDescriptor(
                engine: engine,
                generation: EndpointGeneration(pid: b.pid, startedAt: started, port: port),
                host: facts.host ?? "127.0.0.1",
                port: port,
                key: key,
                facts: facts,
                command: b.comm,
                portDisagreement: argvPort != nil && !ports.contains(argvPort!))
            changed.insert(engine)
        }

        // An engine that vanished is also a change.
        for engine in cache.keys where found[engine] == nil { changed.insert(engine) }

        // Jan's instances live one tier below the router and are enumerated by
        // parent pid, so they are resolved after the scan rather than during it.
        if let pid = janRouterPID, let info = janRouterInfo,
           let d = found[.jan], let started = ProcSampler.startedAt(pid) {
            jan = JanTopology.build(
                routerPID: pid, routerStartedAt: started, routerInfo: info,
                routerPort: d.port, children: ProcSampler.children(of: pid))
        } else {
            jan = nil
        }

        cache = found
        // Every Jan pid, not just the router: the router holds ~45 MB while its
        // children hold the weights, so sampling only the process that owns the
        // port under-reports Jan's memory by orders of magnitude.
        seen = Set(found.values.map { $0.generation.pid }).union(jan?.allPIDs ?? [])
        // Bound the classification cache to live processes, reusing the scan
        // already in hand rather than paying for a second one.
        let alive = Set(scanned.map { $0.pid })
        classified = classified.filter { alive.contains($0.key) }
        return (Array(found.values).sorted { $0.engine.rawValue < $1.engine.rawValue }, changed)
    }

    public func descriptor(_ e: EngineID) -> RuntimeDescriptor? { cache[e] }
    public func trackedPIDs() -> Set<Int32> { seen }
    /// Jan's router-and-instances topology, nil when Jan's engine is not up.
    public func janTopology() -> JanTopology? { jan }
}
