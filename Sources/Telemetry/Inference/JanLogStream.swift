import Foundation

/// Jan's telemetry channel, and the reason Jan is the cheapest engine in this
/// app to observe.
///
/// Everywhere else, per-token telemetry costs something. `/slots` is serialized
/// behind llama.cpp's decode loop, so each poll takes 100-450 ms of server time
/// away from generating — a cost this app measures and displays because it
/// cannot avoid it. Jan avoids it: the router runs its children at verbosity 3
/// and pipes their stdout into `~/Library/Application Support/Jan/data/logs/
/// app.log`, where llama.cpp's own instrumentation is already written down.
///
/// So for Jan the app reads a file instead of interrupting a GPU. MEASURED
/// against a live generation:
///
///     [52550] I slot launch_slot_: id  0 | task 1322 | processing task, is_child = 0
///     [52550] I slot print_timing: id  0 | task 1322 | n_decoded =  237, tg = 78.91 t/s, tg_3s = 78.91 t/s
///     [52550] I slot print_timing: id  0 | task 1322 | n_decoded =  848, tg = 56.37 t/s, tg_3s = 52.56 t/s
///     [52550] I slot print_timing: id  0 | task 1322 | prompt eval time = 108.39 ms / 26 tokens (4.17 ms per token, 239.88 tokens per second)
///     [52550] I slot print_timing: id  0 | task 1322 |        eval time = 16040.54 ms / 900 tokens (17.82 ms per token, 56.11 tokens per second)
///     [52550] I slot print_timing: id  0 | task 1322 |       total time = 16148.92 ms / 926 tokens
///     [52550] I slot      release: id  0 | task 1322 | stop processing: n_tokens = 929, truncated = 0
///
/// which is strictly more than `/slots` can report, and free:
///
///   * **`tg_3s` is a trailing 3-second rate.** This app derives instantaneous
///     decode rate by differencing `n_decoded` across two polls; llama.cpp
///     computes the same quantity internally over a fixed window and prints it.
///     It is the engine's own number, so it is exact where ours is estimated —
///     and it is published as such, not laundered into a measurement of ours.
///   * **The receipt is exact.** `prompt eval time` is the true prefill
///     duration and `eval time` the true decode duration, so TTFT arrives as a
///     number rather than as the poll-interval-wide bracket `/slots` forces.
///   * **The `[port]` prefix identifies the instance**, so multiple models
///     logging concurrently stay separable.
///
/// Two things this channel cannot do, stated because silence here must not read
/// as idleness:
///
///   1. **`print_timing` lines arrive every ~3 s**, not per token. Between them
///      there is no new information, which is why the state carries its own
///      `lastActivityAt` and the caller must not treat a 1 s gap as a stop.
///   2. **It is instance-wide.** A generation driven by Jan's own chat window,
///      by another app on this machine, or by this one, are indistinguishable —
///      the log carries no caller identity. Same limitation as LM Studio's
///      diagnostics stream.
///
/// Carries no prompt or completion text. llama.cpp at verbosity 3 does not log
/// token content, and nothing here would keep it if it did.
public final class JanLogStream: @unchecked Sendable {

    /// Model facts the child reports about itself when it finishes loading.
    ///
    /// The `ready` payload settles the context question outright. For the same
    /// child, MEASURED: `n_ctx: 4096` and `n_ctx_train: 262144`. So the 4096
    /// that `/slots` reports is the ALLOCATED window, not the model maximum —
    /// the model maximum is 64x larger and named separately. Under Jan the two
    /// quantities this app normally cannot separate are both stated by the
    /// engine.
    public struct ModelMeta: Sendable, Equatable {
        public var nCtx: Int?          // allocated, per slot
        public var nCtxTrain: Int?     // the model maximum
        public var nEmbd: Int?
        public var nVocab: Int?
        public var nParams: Int64?
        public var sizeBytes: UInt64?
        /// e.g. "Q4_K - Medium". llama.cpp's own naming, not a guess parsed
        /// out of a filename.
        public var ftype: String?
    }

    /// What one instance is doing right now, as its own log says.
    public struct InstanceState: Sendable {
        public var port: UInt16
        /// From the router's proxy lines or the child's `ready` payload.
        public var alias: String?
        public var slotID: Int?
        public var taskID: Int?
        public var nDecoded: Int?
        /// Cumulative mean rate for the request so far. Engine-reported.
        public var tokensPerSecond: Double?
        /// Trailing ~3 s rate. Engine-reported, and the closest thing to an
        /// instantaneous rate any source in this app provides.
        public var tokensPerSecond3s: Double?
        public var lastActivityAt: Instant?
        /// True between `launch_slot_` and `release`.
        public var decoding: Bool = false
        /// Weight loading, 0...1, from the child's `loading` state messages.
        /// Distinct from decoding: a model reading 3 GB off disk is busy but
        /// producing nothing, and calling that a stalled generation would be
        /// wrong.
        public var loadProgress: Double?
        public var meta: ModelMeta?
        public var requestsSeen: Int = 0
    }

    /// A completed request, exactly as the engine measured it.
    ///
    /// Every field here is a clock reading taken by llama.cpp itself, which is
    /// why this is a receipt and not a sample: it describes a generation that
    /// is already over and says nothing about one in flight.
    public struct Receipt: Sendable {
        public var t: Instant
        public var port: UInt16
        public var alias: String?
        public var slotID: Int?
        public var taskID: Int?

        public var promptMillis: Double?
        public var promptTokens: Int?
        public var promptTokensPerSecond: Double?

        public var decodeMillis: Double?
        public var decodedTokens: Int?
        public var decodeTokensPerSecond: Double?

        public var totalMillis: Double?
        public var totalTokens: Int?
        /// Metal graph reuse count. Not a throughput figure, but it is the only
        /// visible signal of whether the backend is re-planning every step.
        public var graphsReused: Int?
        /// Context tokens held at release, and whether the window was hit.
        public var contextTokens: Int?
        public var truncated: Bool?

        /// The true time to first token: prefill duration. `/slots` can only
        /// bracket this by the poll interval; here the engine timed it.
        public var timeToFirstToken: Double? { promptMillis.map { $0 / 1000 } }
    }

    public struct Snapshot: Sendable {
        public var instances: [UInt16: InstanceState] = [:]
        /// Receipts completed since the previous poll. Drained, not
        /// accumulated: a receipt delivered twice would double-count a
        /// generation in the episode ledger.
        public var receipts: [Receipt] = []
        /// Lines the parser recognised, for the self-cost readout.
        public var linesIngested: Int = 0
    }

    public static let defaultPath = ("~/Library/Application Support/Jan/data/logs/app.log"
                                     as NSString).expandingTildeInPath

    public let path: String
    private var offset: UInt64 = 0
    private var carry = ""
    private var instances: [UInt16: InstanceState] = [:]
    /// Receipts under construction. The engine prints one field per line, so a
    /// receipt is assembled across ~5 lines and completed at `release`.
    private var building: [UInt16: Receipt] = [:]
    private var pending: [Receipt] = []
    private var ingested = 0
    /// alias -> port, learned from the router's `proxy_reques` lines. The child
    /// stdout lines carry only a port, so this is what names them before the
    /// `ready` payload arrives.
    private var aliasByPort: [UInt16: String] = [:]

    public init(path: String = JanLogStream.defaultPath, fromStart: Bool = false) {
        self.path = path
        // Start at the end by default: this reports live behaviour, and Jan's
        // app.log persists across runs, so replaying it would emit receipts for
        // generations that finished days ago.
        if !fromStart,
           let a = try? FileManager.default.attributesOfItem(atPath: path),
           let size = a[.size] as? UInt64 { offset = size }
        if !fromStart { primeMetadata() }
    }

    /// Recovers each instance's identity and model facts from the log already on
    /// disk, WITHOUT replaying its generations.
    ///
    /// A child announces itself once, when it finishes loading, in a `ready`
    /// message carrying `n_params`, `size`, `ftype`, `n_ctx` and `n_ctx_train`.
    /// That is the only source for `n_ctx_train` anywhere — a child's `/props`
    /// does not include it (VERIFIED: it returns model_alias, model_ftype,
    /// model_path, total_slots and n_ctx, and nothing about the model's trained
    /// ceiling). But it is announced exactly once, so an app that starts
    /// tailing after the model loaded — the normal case — would never see it,
    /// and the context-headroom line would be permanently blank on a machine
    /// where everything is working.
    ///
    /// So the existing file is read once and ONLY the identity-bearing lines are
    /// ingested. Timing lines are skipped entirely, which is what keeps this
    /// from resurrecting week-old generations as fresh receipts.
    private func primeMetadata() {
        guard let data = FileManager.default.contents(atPath: path) else { return }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let l = String(line)
            // Only two line kinds carry identity: the router naming a model on
            // a port, and a child announcing itself.
            guard l.contains("proxy_reques:")
                    || l.contains("cmd_child_to_router:state:") else { continue }
            ingest(l, now: Instant(0))
        }
        // Anything the replay staged is history, not news.
        pending.removeAll()
        ingested = 0
        for port in instances.keys {
            instances[port]?.decoding = false
            instances[port]?.lastActivityAt = nil
            instances[port]?.requestsSeen = 0
            // A load that was in progress when the log was written is not in
            // progress now.
            instances[port]?.loadProgress = nil
        }
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// Reads whatever is new: a seek and a short read, no re-parsing.
    public func poll(now: Instant) -> Snapshot {
        guard let fh = FileHandle(forReadingAtPath: path) else { return snapshot() }
        defer { try? fh.close() }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size]
                as? UInt64 else { return snapshot() }

        // Jan truncates app.log on launch, so a shrink means a new Jan, not a
        // corrupt file.
        if size < offset { offset = 0; carry = "" }
        if size > offset {
            try? fh.seek(toOffset: offset)
            let data = (try? fh.readToEnd()) ?? Data()
            offset = size
            let text = carry + String(decoding: data, as: UTF8.self)
            var lines = text.components(separatedBy: "\n")
            carry = lines.popLast() ?? ""     // keep the partial line
            for line in lines { ingest(line, now: now) }
        }

        // A request whose `release` line never arrived — the client
        // disconnected, or Jan was killed mid-generation. Retire it rather than
        // leaving an instance decoding forever.
        for (port, st) in instances where st.decoding {
            if let last = st.lastActivityAt, now - last > 10 {
                instances[port]?.decoding = false
            }
        }
        return snapshot()
    }

    private func snapshot() -> Snapshot {
        var s = Snapshot(instances: instances, receipts: pending, linesIngested: ingested)
        pending.removeAll()
        s.instances = instances
        return s
    }

    // MARK: - Parsing

    private func ingest(_ line: String, now: Instant) {
        // Router-level: which model is on which port. This is the only place
        // the alias and the port appear together before a child announces
        // itself, and it is how an instance gets a name.
        if line.contains("proxy_reques:"),
           let r = line.range(of: "proxying request to model ") {
            let rest = line[r.upperBound...]
            if let onIdx = rest.range(of: " on port ") {
                let alias = String(rest[rest.startIndex..<onIdx.lowerBound])
                if let port = UInt16(String(rest[onIdx.upperBound...])
                                        .trimmingCharacters(in: .whitespaces)) {
                    aliasByPort[port] = alias
                    instances[port, default: InstanceState(port: port)].alias = alias
                }
            }
            ingested += 1
            return
        }

        // Everything below is child stdout, prefixed with the child's port.
        guard let port = Self.childPort(line) else { return }
        var st = instances[port] ?? InstanceState(port: port)
        st.alias = st.alias ?? aliasByPort[port]

        // --- child -> router state messages (load progress, model metadata) ---
        if let r = line.range(of: "cmd_child_to_router:state:") {
            let json = String(line[r.upperBound...])
            if let o = try? JSONSerialization.jsonObject(with: Data(json.utf8))
                as? [String: Any] {
                let state = o["state"] as? String
                let payload = o["payload"] as? [String: Any]
                if state == "loading" {
                    st.loadProgress = (payload?["value"] as? NSNumber)?.doubleValue
                    st.lastActivityAt = now
                } else if state == "ready" {
                    st.loadProgress = nil
                    if let id = payload?["id"] as? String {
                        st.alias = id
                        aliasByPort[port] = id
                    }
                    if let m = payload?["meta"] as? [String: Any] {
                        st.meta = ModelMeta(
                            nCtx: (m["n_ctx"] as? NSNumber)?.intValue,
                            nCtxTrain: (m["n_ctx_train"] as? NSNumber)?.intValue,
                            nEmbd: (m["n_embd"] as? NSNumber)?.intValue,
                            nVocab: (m["n_vocab"] as? NSNumber)?.intValue,
                            nParams: (m["n_params"] as? NSNumber)?.int64Value,
                            sizeBytes: (m["size"] as? NSNumber)?.uint64Value,
                            ftype: m["ftype"] as? String)
                    }
                    st.lastActivityAt = now
                }
                ingested += 1
            }
            instances[port] = st
            return
        }

        let slotID = Self.number(line, after: "id ").map(Int.init)
        let taskID = Self.number(line, after: "task ").map(Int.init)

        // --- request start ---
        if line.contains("launch_slot_:") {
            st.slotID = slotID
            st.taskID = taskID
            st.decoding = true
            st.nDecoded = nil
            st.tokensPerSecond = nil
            st.tokensPerSecond3s = nil
            st.lastActivityAt = now
            st.requestsSeen += 1
            // A fresh receipt: fields arrive over the following lines.
            building[port] = Receipt(t: now, port: port, alias: st.alias,
                                     slotID: slotID, taskID: taskID)
            instances[port] = st
            ingested += 1
            return
        }

        // --- live progress, every ~3 s ---
        if line.contains("n_decoded =") && line.contains("tg =") {
            st.nDecoded = Self.number(line, after: "n_decoded =").map(Int.init)
            // "tg_3s =" must be matched BEFORE "tg =" would swallow it; the
            // underscore makes them distinct markers, so order is not load
            // bearing, but reading the wrong one silently reports a mean as an
            // instantaneous rate.
            st.tokensPerSecond = Self.number(line, after: "tg =")
            st.tokensPerSecond3s = Self.number(line, after: "tg_3s =")
            st.decoding = true
            st.lastActivityAt = now
            instances[port] = st
            ingested += 1
            return
        }

        // --- end-of-request receipt, one field per line ---
        if line.contains("prompt eval time =") {
            let n = Self.numbersAfterFirstEquals(line)
            building[port, default: Receipt(t: now, port: port, alias: st.alias,
                                            slotID: slotID, taskID: taskID)]
                .promptMillis = n.count > 0 ? n[0] : nil
            if n.count > 1 { building[port]?.promptTokens = Int(n[1]) }
            if n.count > 3 { building[port]?.promptTokensPerSecond = n[3] }
            st.lastActivityAt = now
            instances[port] = st
            ingested += 1
            return
        }
        if line.contains("eval time =") {   // reached only if not "prompt eval"
            let n = Self.numbersAfterFirstEquals(line)
            building[port, default: Receipt(t: now, port: port, alias: st.alias,
                                            slotID: slotID, taskID: taskID)]
                .decodeMillis = n.count > 0 ? n[0] : nil
            if n.count > 1 { building[port]?.decodedTokens = Int(n[1]) }
            if n.count > 3 { building[port]?.decodeTokensPerSecond = n[3] }
            st.lastActivityAt = now
            instances[port] = st
            ingested += 1
            return
        }
        if line.contains("total time =") {
            let n = Self.numbersAfterFirstEquals(line)
            if n.count > 0 { building[port]?.totalMillis = n[0] }
            if n.count > 1 { building[port]?.totalTokens = Int(n[1]) }
            ingested += 1
            return
        }
        if line.contains("graphs reused =") {
            building[port]?.graphsReused = Self.number(line, after: "graphs reused =")
                .map(Int.init)
            ingested += 1
            return
        }

        // --- request end: completes the receipt ---
        if line.contains("release:") && line.contains("stop processing") {
            st.decoding = false
            st.lastActivityAt = now
            var r = building.removeValue(forKey: port)
                ?? Receipt(t: now, port: port, alias: st.alias,
                           slotID: slotID, taskID: taskID)
            r.t = now
            r.alias = r.alias ?? st.alias
            r.contextTokens = Self.number(line, after: "n_tokens =").map(Int.init)
            r.truncated = Self.number(line, after: "truncated =").map { $0 != 0 }
            // Only publish a receipt that actually carries a measurement; a
            // request cancelled during prefill produces a release line and
            // nothing else, and an empty receipt in the ledger reads as a
            // zero-token generation.
            if r.decodedTokens != nil || r.promptTokens != nil { pending.append(r) }
            instances[port] = st
            ingested += 1
            return
        }

        instances[port] = st
    }

    // MARK: - Test seams
    //
    // The parser is the part of this that can be wrong, and it is driven by a
    // file the tests must not depend on existing. These expose ingest directly
    // so the real captured log lines can be replayed as fixtures.

    func testIngest(_ line: String, now: Instant) { ingest(line, now: now) }
    func testSnapshot() -> Snapshot { snapshot() }

    /// The `[52550]` that prefixes child stdout. Router's own lines carry
    /// `[llamacpp-router]` with no port and are handled separately.
    static func childPort(_ line: String) -> UInt16? {
        guard let marker = line.range(of: "[llamacpp-router stdout] [") else { return nil }
        let rest = line[marker.upperBound...]
        guard let close = rest.firstIndex(of: "]") else { return nil }
        return UInt16(rest[rest.startIndex..<close])
    }

    /// The first number following `marker`. Tolerant of llama.cpp's column
    /// padding (`id  0`, `n_decoded =    848`).
    static func number(_ line: String, after marker: String) -> Double? {
        guard let r = line.range(of: marker) else { return nil }
        return firstNumber(in: line[r.upperBound...])
    }

    /// Every number after the first `=`. Used for the timing lines, whose keys
    /// ("prompt eval time", "total time") contain no digits, so nothing from
    /// the key can leak into the values.
    static func numbersAfterFirstEquals(_ line: String) -> [Double] {
        guard let eq = line.firstIndex(of: "=") else { return [] }
        var out: [Double] = []
        var rest = line[line.index(after: eq)...]
        while let n = firstNumberAndRest(rest) {
            out.append(n.value)
            rest = n.rest
        }
        return out
    }

    private static func firstNumber(in s: Substring) -> Double? {
        firstNumberAndRest(s)?.value
    }

    private static func firstNumberAndRest(_ s: Substring)
        -> (value: Double, rest: Substring)? {
        var i = s.startIndex
        while i < s.endIndex, !(s[i].isNumber || (s[i] == "-" && s.index(after: i) < s.endIndex
                                                 && s[s.index(after: i)].isNumber)) {
            i = s.index(after: i)
        }
        guard i < s.endIndex else { return nil }
        var j = i
        if s[j] == "-" { j = s.index(after: j) }
        while j < s.endIndex, s[j].isNumber { j = s.index(after: j) }
        // A single decimal point, only when a digit follows it.
        if j < s.endIndex, s[j] == ".", s.index(after: j) < s.endIndex,
           s[s.index(after: j)].isNumber {
            j = s.index(after: j)
            while j < s.endIndex, s[j].isNumber { j = s.index(after: j) }
        }
        return Double(s[i..<j]).map { ($0, s[j...]) }
    }
}
