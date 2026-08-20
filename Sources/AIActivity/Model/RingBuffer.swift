import Foundation

/// Fixed-capacity, in-memory only. Nothing here is ever written to disk —
/// "live display only" is enforced by there being no persistence code at all.
struct RingBuffer<Element> {
    private var storage: [Element] = []
    private var head = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    mutating func append(_ e: Element) {
        if storage.count < capacity {
            storage.append(e)
        } else {
            storage[head] = e
            head = (head + 1) % capacity
        }
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    /// Oldest to newest.
    var ordered: [Element] {
        if storage.count < capacity { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    var last: Element? {
        guard !storage.isEmpty else { return nil }
        return storage[storage.count < capacity ? storage.count - 1 : (head + capacity - 1) % capacity]
    }

    mutating func removeAll() { storage.removeAll(keepingCapacity: true); head = 0 }
}
