import Foundation

/// Per-packet timestamps for the phase 0 per-hop breakdown (docs/measurements/PHASE0-PROTOCOL.md).
/// Each side records what it can see: the sender knows capture, encode and send times; the
/// receiver knows arrival and playout times. Offline analysis joins the two CSVs on sequence and
/// aligns the clocks with the ping/pong offset that the session also logs.
public struct PacketTrace: Sendable, Equatable {
    public var sequence: UInt16
    public var capturedAt: UInt64 = 0
    public var encodedAt: UInt64 = 0
    public var sentAt: UInt64 = 0
    public var receivedAt: UInt64 = 0
    public var playedAt: UInt64 = 0
    public init(sequence: UInt16) { self.sequence = sequence }
}

/// Fixed-size ring of traces keyed by sequence number. Cheap enough to leave on in release builds.
public struct TraceLog: Sendable {
    public let capacity: Int
    private var entries: [UInt16: PacketTrace] = [:]
    private var order: [UInt16] = []
    public private(set) var clockOffsetNanoseconds: Int64?

    public init(capacity: Int = 6000) { self.capacity = capacity }

    public mutating func update(_ sequence: UInt16, _ mutate: (inout PacketTrace) -> Void) {
        var t = entries[sequence] ?? PacketTrace(sequence: sequence)
        if entries[sequence] == nil {
            order.append(sequence)
            if order.count > capacity { entries[order.removeFirst()] = nil }
        }
        mutate(&t)
        entries[sequence] = t
    }

    public mutating func recordClockOffset(_ ns: Int64?) { clockOffsetNanoseconds = ns }

    public var traces: [PacketTrace] { order.compactMap { entries[$0] } }

    /// CSV with one row per packet. Zero means "not observed on this side".
    public func csv() -> String {
        var out = "sequence,captured_ns,encoded_ns,sent_ns,received_ns,played_ns\n"
        for t in traces {
            out += "\(t.sequence),\(t.capturedAt),\(t.encodedAt),\(t.sentAt),\(t.receivedAt),\(t.playedAt)\n"
        }
        if let off = clockOffsetNanoseconds { out += "# remote_clock_minus_local_ns,\(off)\n" }
        return out
    }
}
