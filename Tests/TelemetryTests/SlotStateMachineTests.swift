import XCTest
@testable import Telemetry

/// These tests encode the traps that would otherwise produce plausible,
/// completely fictional numbers.
final class SlotStateMachineTests: XCTestCase {

    func raw(id: Int = 0, processing: Bool, idTask: Int? = nil,
             npt: Int? = nil, processed: Int? = nil, cached: Int? = nil,
             decoded: Int? = nil, nCtx: Int = 262_144) -> LlamaSlotsClient.RawSlot {
        LlamaSlotsClient.RawSlot(
            id: id, isProcessing: processing, nCtx: nCtx, speculative: true,
            idTask: idTask, nPromptTokens: npt, nPromptTokensProcessed: processed,
            nPromptTokensCache: cached, nDecoded: decoded, nRemain: -1,
            hasNextToken: processing, sampler: nil, specTypes: "none,draft-mtp",
            hasCounters: idTask != nil || npt != nil)
    }

    // A slot that has never run exposes only [id, is_processing, n_ctx,
    // speculative]. Every counter must read as absent, never as zero.
    func testNeverUsedSlotYieldsNoNumbers() {
        var m = SlotStateMachine()
        let s = m.update(raw(processing: false), at: Instant(0), fittedContext: 16_384)
        XCTAssertEqual(s.state, .neverUsed)
        XCTAssertNil(s.nDecoded)
        XCTAssertFalse(s.decodeTokensPerSecond.confidence.isAvailable)
        XCTAssertFalse(s.cacheHitRate.confidence.isAvailable)
        XCTAssertNil(s.decodeTokensPerSecond.value)
    }

    // A previously-used idle slot serves FROZEN counters. Differencing them
    // against a later request is the single most likely corruption in the app.
    func testIdleWithHistoryNeverProducesARate() {
        var m = SlotStateMachine()
        _ = m.update(raw(processing: true, idTask: 1, npt: 100, processed: 100,
                         cached: 0, decoded: 10), at: Instant(0), fittedContext: 16_384)
        _ = m.update(raw(processing: true, idTask: 1, npt: 120, processed: 100,
                         cached: 0, decoded: 30), at: Instant(1), fittedContext: 16_384)
        let idle = m.update(raw(processing: false, idTask: 1, npt: 120, processed: 100,
                                cached: 0, decoded: 30), at: Instant(2), fittedContext: 16_384)
        XCTAssertEqual(idle.state, .idleWithHistory)
        XCTAssertFalse(idle.decodeTokensPerSecond.confidence.isAvailable,
                       "an idle slot must not report throughput")
    }

    // A new id_task must reset the accumulator, not difference across requests.
    func testRequestBoundaryResetsAccumulator() {
        var m = SlotStateMachine()
        for (i, d) in [10, 30, 50].enumerated() {
            _ = m.update(raw(processing: true, idTask: 1, npt: 100 + d, processed: 100,
                             cached: 0, decoded: d), at: Instant(Double(i)), fittedContext: 16_384)
        }
        // New request: counters restart low. Naive differencing yields a huge
        // negative slope; the boundary rule must prevent that entirely.
        let s = m.update(raw(processing: true, idTask: 2, npt: 50, processed: 50,
                             cached: 0, decoded: 1), at: Instant(3), fittedContext: 16_384)
        XCTAssertEqual(s.idTask, 2)
        XCTAssertFalse(s.decodeTokensPerSecond.confidence.isAvailable,
                       "a fresh request has too few samples to rate")
    }

    // n_decoded going backwards under an unchanged id_task means the slot was
    // reused between polls. Discard rather than emit a negative rate.
    func testDecodedRegressionDiscardsWindow() {
        var m = SlotStateMachine()
        for (i, d) in [10, 40, 70].enumerated() {
            _ = m.update(raw(processing: true, idTask: 7, npt: 100, processed: 100,
                             cached: 0, decoded: d), at: Instant(Double(i)), fittedContext: 16_384)
        }
        let s = m.update(raw(processing: true, idTask: 7, npt: 100, processed: 100,
                             cached: 0, decoded: 5), at: Instant(3), fittedContext: 16_384)
        if let v = s.decodeTokensPerSecond.value { XCTAssertGreaterThanOrEqual(v, 0) }
    }

    // is_processing can stick true while nothing advances. A stuck slot must be
    // visibly stuck, not silently averaged into throughput.
    func testStalledSlotReportsUnavailableNotZero() {
        var m = SlotStateMachine()
        _ = m.update(raw(processing: true, idTask: 3, npt: 100, processed: 100,
                         cached: 0, decoded: 5), at: Instant(0), fittedContext: 16_384)
        var s = m.update(raw(processing: true, idTask: 3, npt: 100, processed: 100,
                             cached: 0, decoded: 5), at: Instant(3), fittedContext: 16_384)
        XCTAssertNotEqual(s.decodeTokensPerSecond.confidence.reason,
                          "slot stalled — n_decoded frozen", "3 s is not yet a stall")
        s = m.update(raw(processing: true, idTask: 3, npt: 100, processed: 100,
                         cached: 0, decoded: 5), at: Instant(9), fittedContext: 16_384)
        XCTAssertEqual(s.decodeTokensPerSecond.confidence.reason, "slot stalled — n_decoded frozen")
    }

    // The rate must survive a skipped poll, because Δt is measured, not assumed.
    func testMissedSampleStillYieldsCorrectRate() {
        var m = SlotStateMachine()
        var s: SlotSample!
        // 20 tok/s, with a 4-second hole in the middle of the series.
        for (t, d) in [(0.0, 0), (1.0, 20), (5.0, 100), (6.0, 120), (7.0, 140)] {
            s = m.update(raw(processing: true, idTask: 9, npt: 100 + d, processed: 100,
                             cached: 0, decoded: d), at: Instant(t), fittedContext: 16_384)
        }
        XCTAssertNotNil(s.decodeTokensPerSecond.value)
        XCTAssertEqual(s.decodeTokensPerSecond.value!, 20.0, accuracy: 0.5)
    }

    // The 16x trap: /slots reports the model max, argv carries the real window.
    func testContextDenominatorsAreKeptSeparate() {
        var m = SlotStateMachine()
        let s = m.update(raw(processing: true, idTask: 1, npt: 15_446, processed: 1_872,
                             cached: 12_642, decoded: 100), at: Instant(0), fittedContext: 16_384)
        XCTAssertEqual(s.nCtxReported, 262_144)
        XCTAssertEqual(s.nCtxFitted, 16_384)
        // 94% against the fitted window, 5.9% against the model max.
        XCTAssertEqual(Double(s.nPromptTokens!) / Double(s.nCtxFitted!), 0.9427, accuracy: 0.001)
    }

    // cache/(cache+processed), NOT cache/n_prompt_tokens — the latter decays
    // toward zero during a long generation because n_prompt_tokens grows.
    func testCacheHitRateUsesFrozenDenominator() {
        var m = SlotStateMachine()
        let a = m.update(raw(processing: true, idTask: 1, npt: 14_699, processed: 1_872,
                             cached: 12_642, decoded: 1), at: Instant(0), fittedContext: 16_384)
        XCTAssertEqual(a.cacheHitRate.value!, 12_642.0 / 14_514.0, accuracy: 1e-9)

        // 1000 tokens later n_prompt_tokens has grown; the rate must NOT move.
        let b = m.update(raw(processing: true, idTask: 1, npt: 15_699, processed: 1_872,
                             cached: 12_642, decoded: 1_001), at: Instant(50), fittedContext: 16_384)
        XCTAssertEqual(b.cacheHitRate.value!, a.cacheHitRate.value!, accuracy: 1e-9,
                       "hit rate must not drift as context grows")
    }

    // TTFT is a bound, not a point — we are not the client.
    func testTTFTIsAnIntervalNotAPoint() {
        var m = SlotStateMachine()
        _ = m.update(raw(processing: false), at: Instant(0), fittedContext: 16_384)
        _ = m.update(raw(processing: true, idTask: 1, npt: 100, processed: 100,
                         cached: 0, decoded: 0), at: Instant(1.0), fittedContext: 16_384)
        let s = m.update(raw(processing: true, idTask: 1, npt: 101, processed: 100,
                             cached: 0, decoded: 1), at: Instant(2.4), fittedContext: 16_384)
        XCTAssertNil(s.timeToFirstToken.value, "must not publish a point estimate")
        let iv = s.timeToFirstToken.interval
        XCTAssertNotNil(iv)
        XCTAssertEqual(iv!.lo, 1.4, accuracy: 0.01)
        XCTAssertEqual(iv!.hi, 2.4, accuracy: 0.01)
    }

    func testGenerationChangeClearsAllTracks() {
        var m = SlotStateMachine()
        for (i, d) in [10, 30, 50].enumerated() {
            _ = m.update(raw(processing: true, idTask: 1, npt: 100, processed: 100,
                             cached: 0, decoded: d), at: Instant(Double(i)), fittedContext: 16_384)
        }
        m.reset()
        let s = m.update(raw(processing: true, idTask: 1, npt: 100, processed: 100,
                             cached: 0, decoded: 60), at: Instant(3), fittedContext: 16_384)
        XCTAssertFalse(s.decodeTokensPerSecond.confidence.isAvailable,
                       "a re-spawned server must not inherit the old window")
    }
}

final class LenientJSONTests: XCTestCase {
    // The observed failure: raw control bytes inside string literals.
    func testRepairsRawControlBytesInsideStrings() {
        let bad = Data("[{\"prompt\":\"line1\nline2\",\"id\":0}]".utf8)
        XCTAssertThrowsError(try JSONSerialization.jsonObject(with: bad))
        let fixed = LenientJSON.repair(bad)
        XCTAssertEqual(fixed.repairs, 1)
        let obj = try! JSONSerialization.jsonObject(with: fixed.data) as! [[String: Any]]
        XCTAssertEqual(obj[0]["prompt"] as? String, "line1\nline2")
    }

    func testLeavesStructuralWhitespaceAlone() {
        let good = Data("[\n  {\"id\": 0}\n]".utf8)
        let fixed = LenientJSON.repair(good)
        XCTAssertEqual(fixed.repairs, 0)
        XCTAssertEqual(fixed.data, good)
    }

    func testDoesNotCorruptEscapedQuotes() {
        let s = Data(#"[{"a":"he said \"hi\"","b":1}]"#.utf8)
        let fixed = LenientJSON.repair(s)
        XCTAssertEqual(fixed.repairs, 0)
        let obj = try! JSONSerialization.jsonObject(with: fixed.data) as! [[String: Any]]
        XCTAssertEqual(obj[0]["a"] as? String, "he said \"hi\"")
    }

    func testParsesNestedNextTokenDecoded() {
        let payload: [String: Any] = [
            "id": 1, "is_processing": true, "n_ctx": 262_144, "speculative": true,
            "id_task": 1296, "n_prompt_tokens": 14_699,
            "n_prompt_tokens_processed": 1_872, "n_prompt_tokens_cache": 12_642,
            "next_token": [["has_next_token": true, "n_remain": -1, "n_decoded": 369]],
        ]
        let s = LlamaSlotsClient.parseSlot(payload)
        XCTAssertEqual(s.nDecoded, 369, "n_decoded is nested at next_token[0]")
        XCTAssertEqual(s.nRemain, -1)
        XCTAssertTrue(s.hasCounters)
    }

    func testNeverUsedSlotPayloadHasNoCounters() {
        let payload: [String: Any] = [
            "id": 0, "is_processing": false, "n_ctx": 262_144, "speculative": true,
        ]
        let s = LlamaSlotsClient.parseSlot(payload)
        XCTAssertFalse(s.hasCounters)
        XCTAssertNil(s.nDecoded)
        XCTAssertNil(s.nPromptTokens)
    }
}

/// The falsified hypothesis: --fit-ctx looked like the right denominator until
/// a live slot was observed at 17460 tokens against a 16384 target.
final class ContextFillTests: XCTestCase {

    func testFitTargetCanBeExceededAndIsNotTreatedAsACeiling() {
        let c = ContextFill(tokens: 17_460, fitTarget: 16_384, modelMaximum: 262_144)
        XCTAssertTrue(c.exceededFitTarget)
        XCTAssertEqual(c.fractionOfFitTarget!, 1.0657, accuracy: 0.001)
        XCTAssertEqual(c.fractionOfModelMaximum!, 0.0666, accuracy: 0.001)
    }

    func testAllocatedWindowIsAlwaysUnavailableWithAReason() {
        let c = ContextFill(tokens: 15_446, fitTarget: 16_384, modelMaximum: 262_144)
        XCTAssertNil(c.allocatedWindow.value)
        XCTAssertFalse(c.allocatedWindow.confidence.isAvailable)
        XCTAssertNotNil(c.allocatedWindow.confidence.reason)
    }

    func testAbsoluteTokenCountIsAlwaysAvailable() {
        // Whatever the denominators do, the numerator is a real measurement.
        let c = ContextFill(tokens: 17_460, fitTarget: nil, modelMaximum: 262_144)
        XCTAssertEqual(c.tokens, 17_460)
        XCTAssertNil(c.fractionOfFitTarget)
        XCTAssertFalse(c.exceededFitTarget)
    }
}

/// MEASURED 2026-08-18 against the live server: during prefill,
/// `next_token[0].n_decoded` holds the PREVIOUS request's value. Observed
/// reading 370 for 23 s while n_prompt_tokens_processed climbed 42 -> 1300,
/// then resetting to 7 the moment decode began. Publishing a rate from that
/// window produced a confident, entirely fictional "12.4 tok/s".
final class PrefillStaleDecodeTests: XCTestCase {

    func slot(processing: Bool, idTask: Int, processed: Int, decoded: Int)
        -> LlamaSlotsClient.RawSlot {
        LlamaSlotsClient.RawSlot(
            id: 1, isProcessing: processing, nCtx: 262_144, speculative: true,
            idTask: idTask, nPromptTokens: processed, nPromptTokensProcessed: processed,
            nPromptTokensCache: 0, nDecoded: decoded, nRemain: -1,
            hasNextToken: processing, sampler: nil, specTypes: "none,draft-mtp",
            hasCounters: true)
    }

    func testStaleDecodedDuringPrefillIsNeverPublishedAsARate() {
        var m = SlotStateMachine()
        // The real trace: prompt processing advances, n_decoded frozen at 370.
        var last: SlotSample!
        for (i, pp) in [42, 788, 1_300].enumerated() {
            last = m.update(slot(processing: true, idTask: 9_001, processed: pp, decoded: 370),
                            at: Instant(Double(i) * 8), fittedContext: 16_384)
            XCTAssertEqual(last.state, .prefilling, "busy but not yet decoding")
            XCTAssertNil(last.nDecoded, "the stale counter must not be surfaced")
            XCTAssertFalse(last.decodeTokensPerSecond.confidence.isAvailable)
        }
        XCTAssertEqual(last.decodeTokensPerSecond.confidence.reason,
                       "prefilling — n_decoded still holds the previous request's value")

        // Decode begins: the counter resets to a small value.
        let a = m.update(slot(processing: true, idTask: 9_001, processed: 1_304, decoded: 7),
                         at: Instant(24), fittedContext: 16_384)
        XCTAssertEqual(a.state, .processing)
        XCTAssertEqual(a.nDecoded, 7)

        // ...and only now does a rate become derivable.
        var b: SlotSample!
        for (i, d) in [13, 20, 25].enumerated() {
            b = m.update(slot(processing: true, idTask: 9_001, processed: 1_304, decoded: d),
                         at: Instant(25.5 + Double(i) * 1.5), fittedContext: 16_384)
        }
        XCTAssertEqual(b.state, .processing)
        XCTAssertNotNil(b.decodeTokensPerSecond.value)
        XCTAssertEqual(b.decodeTokensPerSecond.value!, 4.0, accuracy: 1.5)
    }

    func testPrefillingCountsAsBusySoTheUIShowsAGeneration() {
        var m = SlotStateMachine()
        let s = m.update(slot(processing: true, idTask: 1, processed: 500, decoded: 999),
                         at: Instant(0), fittedContext: 16_384)
        XCTAssertTrue(s.state.isBusy)
        XCTAssertEqual(s.state, .prefilling)
    }
}
