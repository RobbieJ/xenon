import Foundation

/// Fixed-capacity single-producer/single-consumer ring of Int16 samples guarded by a lock.
/// The audio render thread drains it; the playout task fills it. Underrun yields silence.
public final class PCMRingBuffer: @unchecked Sendable {
    private var storage: [Int16]
    private var head = 0
    private var count = 0
    private let lock = NSLock()
    public let capacity: Int
    public private(set) var underrunSamples = 0
    public private(set) var overrunSamples = 0

    public init(capacity: Int) {
        self.capacity = capacity
        self.storage = [Int16](repeating: 0, count: capacity)
    }

    public var availableSamples: Int { lock.lock(); defer { lock.unlock() }; return count }

    /// Appends samples; if the ring is full the oldest are overwritten (we would rather skip than drift).
    public func write(_ samples: [Int16]) {
        lock.lock(); defer { lock.unlock() }
        for s in samples {
            let idx = (head + count) % capacity
            storage[idx] = s
            if count < capacity { count += 1 } else { head = (head + 1) % capacity; overrunSamples += 1 }
        }
    }

    /// Fills `out` with up to `out.count` samples, zero-padding on underrun. Returns samples actually read.
    @discardableResult
    public func read(into out: UnsafeMutableBufferPointer<Int16>) -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = min(out.count, count)
        for i in 0..<n { out[i] = storage[(head + i) % capacity] }
        head = (head + n) % capacity
        count -= n
        if n < out.count {
            for i in n..<out.count { out[i] = 0 }
            underrunSamples += out.count - n
        }
        return n
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        head = 0; count = 0
    }
}
