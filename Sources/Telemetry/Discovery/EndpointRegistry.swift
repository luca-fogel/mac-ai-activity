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

    private static let known: [(prefix: String, engine: EngineID)] = [
        ("llama-server", .bionic),
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

    /// Returns the current descriptors and the set of engines whose generation
    /// changed since the last scan (callers must tear down derived state for
    /// those — carrying counters across a re-spawn produces a garbage spike).
    public func refresh() -> (runtimes: [RuntimeDescriptor], changed: Set<EngineID>) {
        var found: [EngineID: RuntimeDescriptor] = [:]
        var changed: Set<EngineID> = []

        for b in ProcSampler.scan() {
            var engine = Self.known.first { b.comm.hasPrefix(String($0.prefix.prefix(15))) }?.engine
            var interpreterArgv: ProcArgs.Info?
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
            let key = info.flatMap { ArgvFacts.apiKey($0.argv) }.map(APIKey.init)
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

        cache = found
        seen = Set(found.values.map { $0.generation.pid })
        return (Array(found.values).sorted { $0.engine.rawValue < $1.engine.rawValue }, changed)
    }

    public func descriptor(_ e: EngineID) -> RuntimeDescriptor? { cache[e] }
    public func trackedPIDs() -> Set<Int32> { seen }
}
