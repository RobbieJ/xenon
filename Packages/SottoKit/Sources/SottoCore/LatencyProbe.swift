import Foundation

/// NTP-style round-trip and clock-offset estimate from one ping/pong exchange.
/// All timestamps are in nanoseconds on each side's own monotonic clock.
public struct LatencySample: Sendable, Equatable {
    public let id: UInt32
    /// Round-trip time excluding the remote side's processing delay.
    public let roundTripNanoseconds: UInt64
    /// Estimated (remote clock - local clock). Positive means the remote clock reads later.
    public let clockOffsetNanoseconds: Int64

    public var roundTripMilliseconds: Double { Double(roundTripNanoseconds) / 1_000_000 }
    public var oneWayMilliseconds: Double { roundTripMilliseconds / 2 }

    /// - Parameters:
    ///   - sentAt: local clock when the ping left (t0)
    ///   - receivedAt: remote clock when the ping arrived (t1)
    ///   - repliedAt: remote clock when the pong left (t2)
    ///   - pongArrivedAt: local clock when the pong arrived (t3)
    public init?(id: UInt32, sentAt: UInt64, receivedAt: UInt64, repliedAt: UInt64, pongArrivedAt: UInt64) {
        guard pongArrivedAt >= sentAt, repliedAt >= receivedAt else { return nil }
        let total = pongArrivedAt - sentAt
        let remoteProcessing = repliedAt - receivedAt
        guard total >= remoteProcessing else { return nil }
        self.id = id
        self.roundTripNanoseconds = total - remoteProcessing
        // offset = ((t1 - t0) + (t2 - t3)) / 2
        let a = Int64(bitPattern: receivedAt &- sentAt)
        let b = Int64(bitPattern: repliedAt &- pongArrivedAt)
        self.clockOffsetNanoseconds = (a + b) / 2
    }
}

/// Keeps a small window of samples and reports a robust estimate (the minimum RTT is the
/// least-jittered measurement; the median offset resists outliers).
public struct LatencyEstimator: Sendable {
    public private(set) var samples: [LatencySample] = []
    public let windowSize: Int

    public init(windowSize: Int = 16) {
        self.windowSize = max(1, windowSize)
    }

    public mutating func add(_ sample: LatencySample) {
        samples.append(sample)
        if samples.count > windowSize { samples.removeFirst(samples.count - windowSize) }
    }

    public var bestRoundTripMilliseconds: Double? {
        samples.map(\.roundTripMilliseconds).min()
    }

    public var medianClockOffsetNanoseconds: Int64? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.map(\.clockOffsetNanoseconds).sorted()
        return sorted[sorted.count / 2]
    }
}
