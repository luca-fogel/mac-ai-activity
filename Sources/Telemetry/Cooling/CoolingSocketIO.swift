import Foundation
import Darwin

/// Bounded, nonblocking transport. The safety loop is serviced while a peer
/// stalls either direction; a per-read timeout alone cannot guarantee this.
public enum CoolingSocketIO {
    private static func ready(_ fd: Int32, events: Int16, deadline: Double,
                              service: () -> Void) -> Bool {
        while ProcessInfo.processInfo.systemUptime < deadline {
            service()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(max(1, min(50, remaining * 1000)))
            let count = poll(&descriptor, 1, milliseconds)
            service()
            if count < 0 && errno != EINTR { return false }
            if count > 0 {
                return descriptor.revents & events != 0
            }
        }
        return false
    }

    public static func readLine(_ fd: Int32, timeout: Double = 2,
                                maximumBytes: Int = 8192,
                                service: () -> Void = {}) -> String? {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 512)
        while data.count < maximumBytes {
            guard ready(fd, events: Int16(POLLIN), deadline: deadline, service: service) else { return nil }
            let count = read(fd, &buffer, min(buffer.count, maximumBytes - data.count))
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { return nil }
            let bytes = buffer.prefix(count)
            if let newline = bytes.firstIndex(of: 0x0A) {
                data.append(contentsOf: bytes.prefix(upTo: newline))
                return String(bytes: data, encoding: .utf8)
            }
            data.append(contentsOf: bytes)
        }
        return nil
    }

    @discardableResult
    public static func write(_ fd: Int32, data: Data, timeout: Double = 2,
                             service: () -> Void = {}) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        return data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard ready(fd, events: Int16(POLLOUT), deadline: deadline, service: service) else { return false }
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}
