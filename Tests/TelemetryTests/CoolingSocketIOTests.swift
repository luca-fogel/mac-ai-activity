import XCTest
import Foundation
import Darwin
@testable import Telemetry

final class CoolingSocketIOTests: XCTestCase {
    private func sockets() -> [Int32] {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        return pair
    }

    func testPartialRequestHasAbsoluteDeadlineAndServicesGuard() {
        let pair = sockets()
        defer { close(pair[0]); close(pair[1]) }
        let started = ProcessInfo.processInfo.systemUptime
        var lastByte = started
        var ticks = 0
        var byte: UInt8 = 65
        let line = CoolingSocketIO.readLine(pair[0], timeout: 0.3) {
            ticks += 1
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastByte >= 0.04 {
                _ = Darwin.write(pair[1], &byte, 1)
                lastByte = now
            }
        }
        XCTAssertNil(line)
        XCTAssertGreaterThan(ticks, 3)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.0)
    }

    func testCompleteJSONLineAndRequestLimit() {
        let pair = sockets()
        defer { close(pair[0]); close(pair[1]) }
        let request = Data("{\"op\":\"status\"}\n".utf8)
        XCTAssertTrue(CoolingSocketIO.write(pair[1], data: request))
        XCTAssertEqual(CoolingSocketIO.readLine(pair[0]), "{\"op\":\"status\"}")
        XCTAssertTrue(CoolingSocketIO.write(pair[1], data: Data(repeating: 65, count: 64)))
        XCTAssertNil(CoolingSocketIO.readLine(pair[0], maximumBytes: 32))
    }

    func testClosedPartialRequestIsNotAccepted() {
        let pair = sockets()
        defer { close(pair[0]) }
        XCTAssertTrue(CoolingSocketIO.write(pair[1], data: Data("{}".utf8)))
        close(pair[1])
        XCTAssertNil(CoolingSocketIO.readLine(pair[0]))
    }

    func testNonReadingPeerCannotBlockGuard() {
        let pair = sockets()
        defer { close(pair[0]); close(pair[1]) }
        var size: Int32 = 1024
        setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var ticks = 0
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(CoolingSocketIO.write(pair[0], data: Data(repeating: 65, count: 1_000_000), timeout: 0.3) { ticks += 1 })
        XCTAssertGreaterThan(ticks, 3)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.0)
    }
}
