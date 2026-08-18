import Foundation

/// Flat, time-ordered columns for charting.
///
/// Replaces calling `RingBuffer.ordered` from view bodies. That returned a
/// freshly allocated 3,000-element array on every access, and a single redraw
/// touched it three or four times — ~240k element copies per second at 20 Hz.
/// Here the storage IS the array, so handing it to a chart is free (COW), and
/// trimming is amortised in batches rather than per append.
struct Series<V> {
    private(set) var times: [Double] = []
    private(set) var values: [V] = []
    let capacity: Int
    private let slack: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.slack = max(64, capacity / 8)
        times.reserveCapacity(capacity + slack)
        values.reserveCapacity(capacity + slack)
    }

    mutating func append(t: Double, _ v: V) {
        times.append(t); values.append(v)
        if times.count > capacity + slack {
            times.removeFirst(slack); values.removeFirst(slack)
        }
    }

    var last: V? { values.last }
    var count: Int { times.count }

    /// Index of the first sample at or after `t`. Lets a 60 s window scan ~600
    /// samples instead of all 3,000.
    func startIndex(from t: Double) -> Int {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The visible slice, without copying the whole history.
    func window(_ range: ClosedRange<Double>) -> (times: ArraySlice<Double>, values: ArraySlice<V>) {
        let i = startIndex(from: range.lowerBound)
        return (times[i...], values[i...])
    }
}
