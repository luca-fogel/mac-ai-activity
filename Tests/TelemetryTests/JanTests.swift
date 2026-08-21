import XCTest
@testable import Telemetry

/// Every fixture in this file is a line captured verbatim from a live Jan 0.8.4
/// running llama.cpp b9967 on this machine, during a real 900-token generation.
/// Nothing here is invented, because the whole point of these traps is that the
/// plausible-looking guess is the wrong one.
final class JanLogStreamTests: XCTestCase {

    private let router = "[2026-08-21][00:19:54][tauri_plugin_llamacpp::router][INFO] [llamacpp-router] 8.57.538.546 I srv  proxy_reques: proxying request to model Jan-v3.5-4B-Q4_K_XL on port 52550"
    private func child(_ body: String, port: Int = 52550) -> String {
        "[2026-08-21][00:20:09][tauri_plugin_llamacpp::router][INFO] [llamacpp-router stdout] [\(port)] \(body)"
    }

    private func stream(_ lines: [String]) -> JanLogStream.Snapshot {
        // A path that does not exist: poll() returns the accumulated state
        // without reading a file, so ingest can be driven directly.
        let s = JanLogStream(path: "/nonexistent/jan.log")
        for l in lines { s.testIngest(l, now: Instant(1000)) }
        return s.testSnapshot()
    }

    // MARK: - Instance identity

    func testChildPortIsExtractedAndRouterLinesAreNot() {
        XCTAssertEqual(JanLogStream.childPort(child("anything")), 52550)
        // The router's own lines have no port and must not be attributed to an
        // instance -- doing so invents an instance on a port nothing listens on.
        XCTAssertNil(JanLogStream.childPort(router))
    }

    func testProxyLineNamesTheInstance() {
        let snap = stream([router])
        XCTAssertEqual(snap.instances[52550]?.alias, "Jan-v3.5-4B-Q4_K_XL")
    }

    // MARK: - The rate that is NOT the rate

    /// `tg` and `tg_3s` are different quantities and the key names differ only
    /// by a suffix, so a loose match reports a whole-request mean as an
    /// instantaneous rate. MEASURED: at n_decoded 534 they were 59.13 and 45.97
    /// t/s -- a 29% error in the number the timeline draws.
    func testCumulativeAndTrailingRatesAreNotConfused() {
        let snap = stream([child("1.47.705.699 I slot print_timing: id  0 | task 1322 | n_decoded =    534, tg =  59.13 t/s, tg_3s =  45.97 t/s")])
        let st = snap.instances[52550]
        XCTAssertEqual(st?.nDecoded, 534)
        XCTAssertEqual(st?.tokensPerSecond ?? 0, 59.13, accuracy: 0.001)
        XCTAssertEqual(st?.tokensPerSecond3s ?? 0, 45.97, accuracy: 0.001)
        XCTAssertTrue(st?.decoding == true)
    }

    /// The `3` in the key `tg_3s` is a digit sitting where a value scanner
    /// would look for one.
    func testKeyDigitsDoNotLeakIntoValues() {
        XCTAssertEqual(JanLogStream.number("tg_3s =  52.56 t/s", after: "tg_3s ="), 52.56)
        XCTAssertEqual(JanLogStream.number("n_decoded =    848, tg =  56.37 t/s", after: "tg ="), 56.37)
    }

    // MARK: - Receipts

    func testCompleteReceiptIsAssembledAcrossLinesAndPublishedOnRelease() {
        let snap = stream([
            router,
            child("1.38.566.115 I slot launch_slot_: id  0 | task 1322 | processing task, is_child = 0"),
            child("1.53.718.064 I slot print_timing: id  0 | task 1322 | n_decoded =    848, tg =  56.37 t/s, tg_3s =  52.56 t/s"),
            child("1.54.715.073 I slot print_timing: id  0 | task 1322 | prompt eval time =     108.39 ms /    26 tokens (    4.17 ms per token,   239.88 tokens per second)"),
            child("1.54.715.077 I slot print_timing: id  0 | task 1322 |        eval time =   16040.54 ms /   900 tokens (   17.82 ms per token,    56.11 tokens per second)"),
            child("1.54.715.077 I slot print_timing: id  0 | task 1322 |       total time =   16148.92 ms /   926 tokens"),
            child("1.54.715.078 I slot print_timing: id  0 | task 1322 |    graphs reused =       2188"),
            child("1.54.715.089 I slot      release: id  0 | task 1322 | stop processing: n_tokens = 929, truncated = 0"),
        ])

        XCTAssertEqual(snap.receipts.count, 1)
        let r = snap.receipts[0]
        XCTAssertEqual(r.alias, "Jan-v3.5-4B-Q4_K_XL")
        XCTAssertEqual(r.slotID, 0)
        XCTAssertEqual(r.taskID, 1322)

        XCTAssertEqual(r.promptMillis ?? 0, 108.39, accuracy: 0.001)
        XCTAssertEqual(r.promptTokens, 26)
        XCTAssertEqual(r.promptTokensPerSecond ?? 0, 239.88, accuracy: 0.001)

        XCTAssertEqual(r.decodeMillis ?? 0, 16040.54, accuracy: 0.001)
        XCTAssertEqual(r.decodedTokens, 900)
        XCTAssertEqual(r.decodeTokensPerSecond ?? 0, 56.11, accuracy: 0.001)

        XCTAssertEqual(r.totalMillis ?? 0, 16148.92, accuracy: 0.001)
        XCTAssertEqual(r.totalTokens, 926)
        XCTAssertEqual(r.graphsReused, 2188)
        XCTAssertEqual(r.contextTokens, 929)
        XCTAssertEqual(r.truncated, false)

        // The exact TTFT -- the thing /slots can only bracket.
        XCTAssertEqual(r.timeToFirstToken ?? 0, 0.10839, accuracy: 1e-5)
        // Release ends the generation.
        XCTAssertTrue(snap.instances[52550]?.decoding == false)
    }

    /// "prompt eval time" CONTAINS "eval time", so checking the shorter marker
    /// first files prefill numbers as decode numbers -- reporting 239.88 t/s of
    /// decoding on a model that decodes at 56.
    func testPromptEvalIsNotReadAsDecodeEval() {
        let snap = stream([
            child("I slot launch_slot_: id  0 | task 7 | processing task, is_child = 0"),
            child("I slot print_timing: id  0 | task 7 | prompt eval time =     108.39 ms /    26 tokens (    4.17 ms per token,   239.88 tokens per second)"),
            child("I slot      release: id  0 | task 7 | stop processing: n_tokens = 40, truncated = 0"),
        ])
        let r = snap.receipts.first
        XCTAssertEqual(r?.promptTokens, 26)
        // Decode never happened, and absent is not zero.
        XCTAssertNil(r?.decodedTokens)
        XCTAssertNil(r?.decodeTokensPerSecond)
    }

    /// A release with no timing lines at all is a cancelled request. Publishing
    /// it would put a zero-token generation in the ledger.
    func testEmptyReceiptIsNotPublished() {
        let snap = stream([
            child("I slot launch_slot_: id  1 | task 9 | processing task, is_child = 0"),
            child("I slot      release: id  1 | task 9 | stop processing: n_tokens = 0, truncated = 0"),
        ])
        XCTAssertTrue(snap.receipts.isEmpty)
        XCTAssertTrue(snap.instances[52550]?.decoding == false)
    }

    func testReceiptsAreDrainedNotAccumulated() {
        let s = JanLogStream(path: "/nonexistent/jan.log")
        for l in [
            child("I slot launch_slot_: id  0 | task 1 | processing task, is_child = 0"),
            child("I slot print_timing: id  0 | task 1 |        eval time =   1000.00 ms /   100 tokens (   10.00 ms per token,   100.00 tokens per second)"),
            child("I slot      release: id  0 | task 1 | stop processing: n_tokens = 100, truncated = 0"),
        ] { s.testIngest(l, now: Instant(1)) }
        XCTAssertEqual(s.testSnapshot().receipts.count, 1)
        // Delivering it twice would double-count the generation.
        XCTAssertEqual(s.testSnapshot().receipts.count, 0)
    }

    // MARK: - Model metadata, and the context question it settles

    /// The child states BOTH numbers, so under Jan they never have to be
    /// conflated: n_ctx 4096 is the allocated per-slot window and n_ctx_train
    /// 262144 is the model maximum -- a factor of 64 apart.
    func testReadyPayloadSeparatesAllocatedWindowFromModelMaximum() {
        let line = child(#"cmd_child_to_router:state:{"state":"ready","payload":{"id":"Jan-v3.5-4B-Q4_K_XL","aliases":["Jan-v3.5-4B-Q4_K_XL"],"tags":[],"object":"model","created":1787271504,"owned_by":"llamacpp","meta":{"vocab_type":2,"n_vocab":151936,"n_ctx":4096,"n_ctx_train":262144,"n_embd":2560,"n_params":4411424256,"size":2993227264,"ftype":"Q4_K - Medium"}}}"#)
        let snap = stream([line])
        let st = snap.instances[52550]
        XCTAssertEqual(st?.alias, "Jan-v3.5-4B-Q4_K_XL")
        XCTAssertEqual(st?.meta?.nCtx, 4096)
        XCTAssertEqual(st?.meta?.nCtxTrain, 262144)
        XCTAssertEqual(st?.meta?.nParams, 4_411_424_256)
        XCTAssertEqual(st?.meta?.sizeBytes, 2_993_227_264)
        // llama.cpp's own quantization name, not a guess parsed from a filename.
        XCTAssertEqual(st?.meta?.ftype, "Q4_K - Medium")
        XCTAssertNil(st?.loadProgress)          // ready clears it
    }

    /// Loading is busy but produces no tokens. Reporting it as a generation
    /// would show a stalled 0 t/s decode for the ~9 s a 3 GB model takes.
    func testLoadProgressIsNotDecoding() {
        let snap = stream([child(#"cmd_child_to_router:state:{"state":"loading","payload":{"stages":["text_model"],"current":"text_model","value":0.0}}"#)])
        XCTAssertEqual(snap.instances[52550]?.loadProgress, 0.0)
        XCTAssertFalse(snap.instances[52550]?.decoding ?? true)
    }

    // MARK: - Concurrent instances

    /// With --models-max 2 two children log into the same file at once, each
    /// numbering its slots from 0. Keying on slot id alone splices two models'
    /// counters into one fictional track.
    func testTwoInstancesStaySeparate() {
        let snap = stream([
            child("I slot print_timing: id  0 | task 1 | n_decoded =    100, tg =  50.00 t/s, tg_3s =  50.00 t/s", port: 52550),
            child("I slot print_timing: id  0 | task 2 | n_decoded =    900, tg =  10.00 t/s, tg_3s =  10.00 t/s", port: 52477),
        ])
        XCTAssertEqual(snap.instances.count, 2)
        XCTAssertEqual(snap.instances[52550]?.nDecoded, 100)
        XCTAssertEqual(snap.instances[52477]?.nDecoded, 900)
    }
}

/// Discovery-layer facts about router mode.
final class JanTopologyTests: XCTestCase {

    /// The router's real argv, verbatim. It names no model and no key, which is
    /// why an argv-only reader learns nothing about what Jan is doing.
    private let routerArgv = [
        "/Users/x/Library/Application Support/Jan/data/llamacpp/backends/b9967/macos-arm64/build/bin/llama-server",
        "--models-preset", "/Users/x/Library/Application Support/Jan/data/llamacpp/router.preset.ini",
        "--models-max", "2", "--host", "127.0.0.1", "--port", "61378", "--no-ui",
    ]

    /// A child's real argv, verbatim.
    private let childArgv = [
        "/Users/x/Library/Application Support/Jan/data/llamacpp/backends/b9967/macos-arm64/build/bin/llama-server",
        "--host", "127.0.0.1", "--port", "52550", "--no-webui",
        "--alias", "Jan-v3.5-4B-Q4_K_XL", "--ctx-size", "8192",
        "--no-cont-batching", "--cache-ram", "-1", "--fit", "off",
        "--model", "/Users/x/Library/Application Support/Jan/data/llamacpp/models/Jan-v3.5-4B-Q4_K_XL/model.gguf",
        "--parallel", "2",
    ]

    func testRouterIsRecognisedAndHoldsNoModel() {
        let f = ArgvFacts.parse(routerArgv)
        XCTAssertTrue(f.isRouter)
        XCTAssertEqual(f.modelsMax, 2)
        XCTAssertEqual(f.port, 61378)
        // The router holds no weights. Reading it as a model server yields a
        // runtime that appears to hold a nil model with a 0-token context.
        XCTAssertNil(f.modelPath)
        XCTAssertNil(f.modelAlias)
        XCTAssertNil(f.requestedContext)
    }

    func testChildIsNotRouterAndCarriesTheModelIdentity() {
        let f = ArgvFacts.parse(childArgv)
        XCTAssertFalse(f.isRouter)
        // --alias is the ONLY place the model id appears; the --model path is
        // a content-addressed `.../<id>/model.gguf` whose basename is the
        // useless constant "model.gguf".
        XCTAssertEqual(f.modelAlias, "Jan-v3.5-4B-Q4_K_XL")
        XCTAssertEqual(f.modelName, "model.gguf")
        XCTAssertEqual(f.parallelSlots, 2)
        XCTAssertEqual(f.requestedContext, 8192)
        XCTAssertEqual(f.fitMode, "off")
        XCTAssertEqual(f.contBatching, false)
        XCTAssertEqual(f.cacheRamMiB, -1)
    }

    /// The whole reason the context caveat can be dropped under Jan.
    func testAllocatedSlotContextIsExactWhenFitIsOff() {
        let f = ArgvFacts.parse(childArgv)
        // 8192 / 2 -- and the live server reported exactly this as n_ctx.
        XCTAssertEqual(f.allocatedSlotContext, 4096)
    }

    /// With auto-fit ON, --ctx-size is a target the server may not honour, so
    /// claiming an exact window would be a guess dressed as a measurement.
    func testAllocatedSlotContextIsWithheldWhenFitIsOn() {
        var argv = childArgv
        argv[argv.firstIndex(of: "off")!] = "on"
        XCTAssertNil(ArgvFacts.parse(argv).allocatedSlotContext)
        // And absent entirely, which is llama.cpp's own default.
        XCTAssertNil(ArgvFacts.parse(["--ctx-size", "8192", "--parallel", "2"])
                        .allocatedSlotContext)
    }

    /// Jan's key is in the environment and nowhere else. Without this the
    /// entire inference domain reads 401 for a healthy, running server.
    func testAPIKeyIsFoundInTheEnvironment() {
        let k = ArgvFacts.apiKey(routerArgv, env: ["LLAMA_API_KEY": "s3cret",
                                                  "LLAMA_ARG_TIMEOUT": "600"])
        XCTAssertEqual(k, "s3cret")
        // Argv still wins when both are present: a flag is intent, an
        // environment variable may merely have been inherited.
        XCTAssertEqual(ArgvFacts.apiKey(routerArgv + ["--api-key", "explicit"],
                                        env: ["LLAMA_API_KEY": "inherited"]),
                       "explicit")
        XCTAssertNil(ArgvFacts.apiKey(routerArgv))
        // An empty value is not a key.
        XCTAssertNil(ArgvFacts.apiKey(routerArgv, env: ["LLAMA_API_KEY": ""]))
    }

    /// Jan and Bionic both spawn a bundled binary named exactly
    /// `llama-server`. Telling them apart by name is impossible; the install
    /// path is the discriminator.
    func testJanIsDistinguishedFromBionicByPath() {
        XCTAssertTrue(JanTopology.isJan(ProcArgs.Info(
            executable: routerArgv[0], argv: routerArgv)))
        XCTAssertFalse(JanTopology.isJan(ProcArgs.Info(
            executable: "/Applications/Bionic.app/Contents/Resources/.../llama-server",
            argv: ["llama-server", "--api-key", "x"])))
    }
}

/// The context caveat, and the one configuration in which it lifts.
final class JanContextFillTests: XCTestCase {

    func testAllocatedWindowIsStatedWhenKnown() {
        // A live Jan slot: 688 tokens held, 4096 allocated, 262144 trainable.
        let c = ContextFill(tokens: 688, fitTarget: nil, modelMaximum: 4096,
                            allocatedSlotContext: 4096)
        XCTAssertEqual(c.allocatedWindow.value, 4096)
        XCTAssertTrue(c.allocatedWindow.confidence.isAvailable)
        XCTAssertEqual(c.fractionOfAllocatedWindow ?? 0, 688.0 / 4096.0, accuracy: 1e-9)
    }

    func testWindowStaysUnavailableWithoutTheFlagsToProveIt() {
        let c = ContextFill(tokens: 17_460, fitTarget: 16_384, modelMaximum: 262_144)
        XCTAssertNil(c.allocatedWindow.value)
        XCTAssertNil(c.fractionOfAllocatedWindow)
        // The original trap is untouched: the fit target is still exceedable.
        XCTAssertTrue(c.exceededFitTarget)
    }
}

/// The decode-detection signal that fast models need.
///
/// The two original signals both require catching `n_decoded` early in the
/// request. Jan's default model is a 4B at ~72 tok/s whose prefill took 128 ms
/// — over before the first 1 Hz poll — so neither could ever fire, and a slot
/// that was plainly decoding reported `prefilling` with no rate for the whole
/// generation.
final class JanFastModelDecodeDetectionTests: XCTestCase {

    /// Values taken from the live Jan slot: 17-token prompt (processed frozen),
    /// total context climbing as tokens are emitted, and n_decoded already well
    /// past the 64 the second signal requires.
    private func slot(promptTokens: Int, decoded: Int, processed: Int = 17)
        -> LlamaSlotsClient.RawSlot {
        LlamaSlotsClient.RawSlot(
            id: 1, isProcessing: true, nCtx: 4096, speculative: false,
            idTask: 613, nPromptTokens: promptTokens,
            nPromptTokensProcessed: processed, nPromptTokensCache: 3,
            nDecoded: decoded, nRemain: nil, hasNextToken: true,
            sampler: nil, specTypes: nil, hasCounters: true)
    }

    func testFrozenPrefillWithGrowingContextProvesDecodeBegan() {
        var m = SlotStateMachine()
        // First poll of the request: nothing to compare against yet, so the
        // counter is correctly still distrusted.
        var s = m.update(slot(promptTokens: 339, decoded: 322), at: Instant(0),
                         fittedContext: 4096, allocatedContext: 4096)
        XCTAssertEqual(s.state, .prefilling)
        XCTAssertNil(s.nDecoded, "a distrusted counter must never be surfaced")

        // Second poll: prefill frozen at 17 while total context grew 339 -> 399.
        // Only emitted tokens can do that.
        s = m.update(slot(promptTokens: 399, decoded: 382), at: Instant(1),
                     fittedContext: 4096, allocatedContext: 4096)
        XCTAssertEqual(s.state, .processing)

        // Third poll: now that the counter is trusted, a rate can be derived
        // from two trusted readings.
        s = m.update(slot(promptTokens: 459, decoded: 442), at: Instant(2),
                     fittedContext: 4096, allocatedContext: 4096)
        XCTAssertEqual(s.state, .processing)
        XCTAssertEqual(s.nDecoded, 442)
        XCTAssertEqual(s.decodeTokensPerSecond.value ?? 0, 60, accuracy: 1.0)
    }

    /// The protection this must not undo: while prefill is still running,
    /// n_decoded holds the PREVIOUS request's count and must stay hidden even
    /// though the context is also changing.
    func testStillDistrustedWhilePrefillIsRunning() {
        var m = SlotStateMachine()
        // processed climbing = prefill in progress. n_decoded reads 400, which
        // is the previous request's final count.
        var s = m.update(slot(promptTokens: 1618, decoded: 400, processed: 1106),
                         at: Instant(0), fittedContext: 4096)
        XCTAssertEqual(s.state, .prefilling)
        s = m.update(slot(promptTokens: 1618, decoded: 400, processed: 1618),
                     at: Instant(1), fittedContext: 4096)
        XCTAssertEqual(s.state, .prefilling, "prefill was still advancing")
        XCTAssertNil(s.nDecoded)
    }
}

/// Recovering instance identity from a log that was written before the app
/// started — the normal case, since a child announces itself exactly once.
final class JanLogPrimingTests: XCTestCase {

    private func writeLog(_ lines: [String]) throws -> String {
        let p = FileManager.default.temporaryDirectory
            .appendingPathComponent("jan-prime-\(UUID().uuidString).log")
        try lines.joined(separator: "\n").appending("\n").write(
            to: p, atomically: true, encoding: .utf8)
        return p.path
    }

    private func child(_ body: String, port: Int = 52550) -> String {
        "[2026-08-21][00:20:09][tauri_plugin_llamacpp::router][INFO] [llamacpp-router stdout] [\(port)] \(body)"
    }

    func testMetadataIsRecoveredButOldGenerationsAreNot() throws {
        let path = try writeLog([
            "[2026-08-21][00:19:54][tauri_plugin_llamacpp::router][INFO] [llamacpp-router] I srv  proxy_reques: proxying request to model Jan-v3.5-4B-Q4_K_XL on port 52550",
            child(#"cmd_child_to_router:state:{"state":"ready","payload":{"id":"Jan-v3.5-4B-Q4_K_XL","meta":{"n_ctx":4096,"n_ctx_train":262144,"n_params":4411424256,"size":2993227264,"ftype":"Q4_K - Medium"}}}"#),
            // A generation that finished long ago. Replaying it would publish a
            // stale receipt and show the instance as mid-decode.
            child("I slot launch_slot_: id  0 | task 99 | processing task, is_child = 0"),
            child("I slot print_timing: id  0 | task 99 | n_decoded =    500, tg =  60.00 t/s, tg_3s =  55.00 t/s"),
            child("I slot print_timing: id  0 | task 99 |        eval time =   1000.00 ms /   500 tokens (   2.00 ms per token,   500.00 tokens per second)"),
            child("I slot      release: id  0 | task 99 | stop processing: n_tokens = 520, truncated = 0"),
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let s = JanLogStream(path: path)
        let snap = s.testSnapshot()

        // Identity and model facts survive.
        let st = snap.instances[52550]
        XCTAssertEqual(st?.alias, "Jan-v3.5-4B-Q4_K_XL")
        XCTAssertEqual(st?.meta?.nCtx, 4096)
        XCTAssertEqual(st?.meta?.nCtxTrain, 262144)
        XCTAssertEqual(st?.meta?.ftype, "Q4_K - Medium")
        XCTAssertEqual(st?.meta?.nParams, 4_411_424_256)

        // History does not.
        XCTAssertTrue(snap.receipts.isEmpty, "an old generation must not resurface as a receipt")
        XCTAssertFalse(st?.decoding ?? true, "the instance is idle now, whatever the log once said")
        XCTAssertNil(st?.lastActivityAt)
        XCTAssertEqual(st?.requestsSeen, 0)
    }

    /// Priming must not consume the file: live lines appended afterwards still
    /// have to arrive.
    func testPrimingLeavesTheTailReadable() throws {
        let path = try writeLog([
            child(#"cmd_child_to_router:state:{"state":"ready","payload":{"id":"M","meta":{"n_ctx_train":262144}}}"#),
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = JanLogStream(path: path)
        XCTAssertEqual(s.testSnapshot().instances[52550]?.meta?.nCtxTrain, 262144)

        // A new generation lands after the app started.
        let fh = FileHandle(forWritingAtPath: path)!
        fh.seekToEndOfFile()
        fh.write(Data((child("I slot launch_slot_: id  0 | task 7 | processing task, is_child = 0") + "\n").utf8))
        fh.write(Data((child("I slot print_timing: id  0 | task 7 |        eval time =   500.00 ms /   50 tokens (   10.00 ms per token,   100.00 tokens per second)") + "\n").utf8))
        fh.write(Data((child("I slot      release: id  0 | task 7 | stop processing: n_tokens = 60, truncated = 0") + "\n").utf8))
        try? fh.close()

        let snap = s.poll(now: Instant(10))
        XCTAssertEqual(snap.receipts.count, 1)
        XCTAssertEqual(snap.receipts.first?.decodedTokens, 50)
        // And the primed metadata is still there.
        XCTAssertEqual(snap.instances[52550]?.meta?.nCtxTrain, 262144)
    }
}

/// Jan's /slots channel is not judged like the others, and the difference is
/// load-bearing.
final class JanFreshnessPolicyTests: XCTestCase {

    /// Jan's instances are polled only while a request is in a slot, so between
    /// generations there is nothing to report. Judging that as a missed 1 Hz
    /// poll put an amber "stale" chip on a healthy idle server — the exact class
    /// of false fault the five source states exist to prevent.
    func testJanSlotsAreEventDrivenAndOthersArePolled() {
        guard case .eventDriven = FreshnessPolicy.slots(for: .jan) else {
            return XCTFail("Jan's slots must not be judged as a fixed-rate poll")
        }
        for e in [EngineID.bionic, .mlxlm, .localai, .ollama] {
            guard case .polled = FreshnessPolicy.slots(for: e) else {
                return XCTFail("\(e) polls /slots at a fixed rate and silence there is a fault")
            }
        }
    }

    /// An idle Jan must read as absent, not stale.
    func testQuietJanReadsAbsentRatherThanStale() {
        let quiet = Freshness.judge(
            FreshnessInput(now: Instant(100), lastOKAt: Instant(10),
                           consecutiveFailures: 0, lastOutcome: .ok, exists: true),
            policy: FreshnessPolicy.slots(for: .jan))
        if case .stale = quiet {
            XCTFail("90 s of idleness is not a fault for an event-driven channel")
        }
        // The same channel on a fixed-rate engine degrades, because there a
        // missed poll really is a missed poll: 3 s without a 1 Hz sample is
        // stale, and 90 s is dark.
        func judgeBionic(after gap: Double) -> Freshness {
            Freshness.judge(
                FreshnessInput(now: Instant(gap), lastOKAt: Instant(0),
                               consecutiveFailures: 0, lastOutcome: .ok, exists: true),
                policy: FreshnessPolicy.slots(for: .bionic))
        }
        if case .stale = judgeBionic(after: 3) {} else {
            XCTFail("3 s without a 1 Hz poll is stale")
        }
        if case .dark = judgeBionic(after: 90) {} else {
            XCTFail("90 s without a 1 Hz poll is dark")
        }
        // Jan stays live across the same 90 s, because nothing was due.
        if case .live = Freshness.judge(
            FreshnessInput(now: Instant(90), lastOKAt: Instant(0),
                           consecutiveFailures: 0, lastOutcome: .ok, exists: true),
            policy: FreshnessPolicy.slots(for: .jan)) {} else {
            XCTFail("an idle Jan is not degraded")
        }
    }
}
