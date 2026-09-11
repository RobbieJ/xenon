import Foundation
import SottoCore

public enum LinkEvent: Sendable, Equatable {
    case ready
    case received(Packet)
    case qualityChanged(LinkQuality)
    case closed(LinkCloseReason)
}

public enum LinkCloseReason: Sendable, Equatable {
    case local
    case remote
    case lost(String)
}

public struct LinkQuality: Sendable, Equatable {
    /// 0...1 where known, else nil.
    public var signalStrength: Double?
    public var estimatedLatencyMilliseconds: Double?
    public var throughputBitsPerSecond: Int?
    public init(signalStrength: Double? = nil, estimatedLatencyMilliseconds: Double? = nil, throughputBitsPerSecond: Int? = nil) {
        self.signalStrength = signalStrength
        self.estimatedLatencyMilliseconds = estimatedLatencyMilliseconds
        self.throughputBitsPerSecond = throughputBitsPerSecond
    }
}

public enum LinkError: Error, Equatable {
    case notReady
    case unsupported(String)
    case sendFailed(String)
}

/// One bidirectional phone-to-phone channel. Implementations: Wi-Fi Aware (UDP datagrams),
/// BLE L2CAP (byte stream, framed by `StreamFramer`), and the in-process loopback used in tests.
///
/// Semantics every implementation must honour:
/// - `send` is fire-and-forget and never blocks the audio thread; stale frames may be dropped.
/// - Delivery is not guaranteed and may be out of order (the jitter buffer copes).
/// - `events` finishes after `.closed`.
public protocol Link: AnyObject, Sendable {
    var kind: LinkKind { get }
    var events: AsyncStream<LinkEvent> { get }
    func send(_ packet: Packet) async throws
    func close() async
}

/// Which phone opens the BLE L2CAP channel when both run both roles. Deterministic on both sides
/// without any prior exchange: the phone with the lexicographically lower identity acts as the
/// central and opens the channel; the other only accepts as the peripheral. The BLE equivalent of
/// `PairingRace`, so the two phones never keep different channels.
public enum BLERolePolicy {
    public static func shouldOpenChannel(localIdentity: String, remoteIdentity: String) -> Bool {
        localIdentity < remoteIdentity
    }
}
