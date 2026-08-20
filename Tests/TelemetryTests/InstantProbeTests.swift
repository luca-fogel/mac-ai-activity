import XCTest
@testable import Telemetry

/// The monotonic clock's own regression test.
///
/// MEASURED: the FIRST `Instant.now()` in a process returned 18446744073.709545
/// seconds. `epoch` is a lazy static, and as the right operand of the
/// subtraction it was initialised only after the clock had already been read —
/// so `now - epoch` went one nanosecond negative and wrapped. Everything
/// downstream of the first timestamp inherited the garbage, and nothing caught
/// it because every subsequent call was fine.
final class InstantEpochTests: XCTestCase {

    func testTheVeryFirstReadingIsNotAnUnsignedUnderflow() {
        // Whichever test runs first exercises the real cold path; the assertion
        // holds either way, and a regression reintroduces ~1.8e10.
        let t = Instant.now()
        XCTAssertGreaterThanOrEqual(t.s, 0)
        XCTAssertLessThan(t.s, 86_400, "epoch underflow: \(t.s)")
    }

    func testReadingsAreMonotonicAndSmall() {
        let a = Instant.now()
        let b = Instant.now()
        XCTAssertGreaterThanOrEqual(b.s, a.s)
        XCTAssertLessThan(b - a, 1.0)
    }

    func testReadingFromADetachedTaskAgrees() async {
        let a = Instant.now()
        let b = await Task.detached { Instant.now() }.value
        XCTAssertGreaterThanOrEqual(b.s, a.s)
        XCTAssertLessThan(b.s, 86_400)
    }
}
