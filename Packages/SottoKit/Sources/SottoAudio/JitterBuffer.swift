import Foundation
import SottoCore

/// Adaptive playout buffer for 20 ms voice frames.
///
/// Design (a small NetEQ): every arriving frame contributes its *relative arrival delay* to a
/// sliding window; the target depth is the 95th percentile of that window, clamped to a range.
/// On each pull the buffer returns the next frame in sequence, conceals a missing one, or
/// skips ahead when it has fallen behind the target. Depth is nudged back towards the target
/// by dropping one frame (accelerate) or inserting one concealment (expand) when the measured
/// depth has stayed outside the target band for a while, which also absorbs clock drift
/// between the two phones.
///
/// Not thread-safe; owned by the playout actor.
public struct JitterBuffer: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var frameDurationMilliseconds: Int = 20
        /// Initial target before any statistics exist.
        public var initialTargetMilliseconds: Int = 40
        public var minimumTargetMilliseconds: Int = 20
        public var maximumTargetMilliseconds: Int = 120
        /// Frames buffered beyond this are dropped outright (a stall just ended).
        public var hardCapMilliseconds: Int = 240
        public var delayWindowSize: Int = 100
        public var targetPercentile: Double = 0.95
        /// Consecutive pulls the depth must sit outside [target, target + 1 frame] before adjusting.
        public var adjustmentPatience: Int = 25
        public init() {}
    }

    public enum Output: Sendable, Equatable {
        /// Play this packet's payload.
        case frame(payload: [UInt8], sequence: UInt16, flags: PacketFlags)
        /// Nothing available for this slot: run PLC. `fecCandidate` is the *next* packet if we have
        /// it, so the decoder can recover this frame from its in-band FEC.
        case conceal(fecCandidate: [UInt8]?)
        /// Still filling to the initial target; play silence.
        case prefill
    }

    public struct Statistics: Sendable, Equatable {
        public var received = 0
        public var played = 0
        public var concealed = 0
        public var skipped = 0
        public var lateDiscarded = 0
        public var accelerated = 0
        public var expanded = 0
        public var duplicates = 0
        public var targetMilliseconds = 0
        public var currentDepthFrames = 0
    }

    private struct Entry { let payload: [UInt8]; let flags: PacketFlags }

    public let configuration: Configuration
    private var entries: [UInt16: Entry] = [:]
    private var nextSequence: UInt16?
    private var highestSequence: UInt16?
    private var delays: [Double] = []
    private var targetFrames: Int
    private var outsideBandCount = 0
    private var prefilling = true
    private var firstArrivalNanoseconds: UInt64?
    private var firstSequence: UInt16?
    public private(set) var statistics = Statistics()

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.targetFrames = max(1, configuration.initialTargetMilliseconds / configuration.frameDurationMilliseconds)
        statistics.targetMilliseconds = targetFrames * configuration.frameDurationMilliseconds
    }

    private var frameNanoseconds: UInt64 { UInt64(configuration.frameDurationMilliseconds) * 1_000_000 }

    /// Insert an arriving audio packet. `arrivedAt` is the local monotonic clock.
    public mutating func push(_ packet: Packet, arrivedAt: UInt64) {
        guard packet.header.kind == .audio else { return }
        statistics.received += 1
        let seq = packet.header.sequence

        if nextSequence == nil {
            nextSequence = seq
            firstSequence = seq
            firstArrivalNanoseconds = arrivedAt
        }
        if let next = nextSequence, next.sequenceDistance(to: seq) < 0 {
            statistics.lateDiscarded += 1
            return
        }
        if entries[seq] != nil {
            statistics.duplicates += 1
            return
        }
        entries[seq] = Entry(payload: packet.payload, flags: packet.header.flags)
        if let h = highestSequence {
            if h.sequenceDistance(to: seq) > 0 { highestSequence = seq }
        } else {
            highestSequence = seq
        }
        recordDelay(sequence: seq, arrivedAt: arrivedAt)
        enforceHardCap()
    }

    /// Pull the frame that should be played now.
    public mutating func pop() -> Output {
        guard let next = nextSequence else { return .prefill }
        let depth = currentDepthFrames()
        statistics.currentDepthFrames = depth

        if prefilling {
            if depth >= targetFrames { prefilling = false } else { return .prefill }
        }

        // Depth control: drift and post-stall recovery.
        if depth > targetFrames + 1 {
            outsideBandCount += 1
        } else if depth < targetFrames && depth > 0 {
            outsideBandCount -= 1
        } else {
            outsideBandCount = 0
        }
        if outsideBandCount >= configuration.adjustmentPatience {
            // Too deep for too long: drop the oldest frame and advance.
            entries[next] = nil
            nextSequence = next &+ 1
            statistics.accelerated += 1
            outsideBandCount = 0
            return popNextAvailable()
        }
        if outsideBandCount <= -configuration.adjustmentPatience {
            // Too shallow for too long: insert one concealment without advancing.
            statistics.expanded += 1
            outsideBandCount = 0
            return .conceal(fecCandidate: nil)
        }
        return popNextAvailable()
    }

    private mutating func popNextAvailable() -> Output {
        guard let next = nextSequence else { return .prefill }
        if let entry = entries.removeValue(forKey: next) {
            nextSequence = next &+ 1
            statistics.played += 1
            return .frame(payload: entry.payload, sequence: next, flags: entry.flags)
        }
        // Missing. If the buffer holds enough later frames that we are behind target, skip ahead.
        if let h = highestSequence, next.sequenceDistance(to: h) > targetFrames + 1 {
            // Skip forward to the oldest available frame beyond the gap.
            var probe = next &+ 1
            var hops = 1
            while entries[probe] == nil, probe.sequenceDistance(to: h) > 0 { probe = probe &+ 1; hops += 1 }
            statistics.skipped += hops
            nextSequence = probe
            return popNextAvailable()
        }
        statistics.concealed += 1
        nextSequence = next &+ 1
        return .conceal(fecCandidate: entries[next &+ 1]?.payload)
    }

    /// Frames between the next sequence to play and the highest one held, counting gaps as depth.
    public func currentDepthFrames() -> Int {
        guard let next = nextSequence, let h = highestSequence else { return 0 }
        let span = next.sequenceDistance(to: h)
        return span < 0 ? 0 : span + (entries[h] != nil ? 1 : 0)
    }

    public var targetMilliseconds: Int { targetFrames * configuration.frameDurationMilliseconds }

    private mutating func recordDelay(sequence: UInt16, arrivedAt: UInt64) {
        guard let t0 = firstArrivalNanoseconds, let s0 = firstSequence else { return }
        let expected = Double(s0.sequenceDistance(to: sequence)) * Double(frameNanoseconds)
        let actual = Double(Int64(bitPattern: arrivedAt &- t0))
        delays.append(actual - expected)
        if delays.count > configuration.delayWindowSize { delays.removeFirst() }
        guard delays.count >= 10 else { return }
        // Relative delay: how much later than the *earliest* packet in the window each arrived.
        let base = delays.min() ?? 0
        let sorted = delays.map { $0 - base }.sorted()
        let idx = min(sorted.count - 1, Int(Double(sorted.count) * configuration.targetPercentile))
        let p95Ms = sorted[idx] / 1_000_000
        var frames = Int((p95Ms / Double(configuration.frameDurationMilliseconds)).rounded(.up)) + 1
        frames = max(configuration.minimumTargetMilliseconds / configuration.frameDurationMilliseconds, frames)
        frames = min(configuration.maximumTargetMilliseconds / configuration.frameDurationMilliseconds, frames)
        targetFrames = frames
        statistics.targetMilliseconds = targetMilliseconds
    }

    private mutating func enforceHardCap() {
        let cap = configuration.hardCapMilliseconds / configuration.frameDurationMilliseconds
        guard let h = highestSequence, var next = nextSequence, next.sequenceDistance(to: h) >= cap else { return }
        // Drop the oldest until we are at the target again; the stall that caused this is over.
        while next.sequenceDistance(to: h) >= targetFrames {
            if entries.removeValue(forKey: next) != nil { statistics.accelerated += 1 }
            next = next &+ 1
        }
        nextSequence = next
    }

    public mutating func reset() {
        self = JitterBuffer(configuration: configuration)
    }
}
