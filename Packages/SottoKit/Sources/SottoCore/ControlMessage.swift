import Foundation

/// Out-of-band messages that ride the same link as audio, in `PacketKind.control` packets.
/// JSON-encoded; tiny and infrequent, so readability wins over compactness.
public enum ControlMessage: Sendable, Equatable, Codable {
    /// First message on a link. `nonce` breaks the "both tapped Pair" race (see `PairingRace`).
    case hello(Hello)
    case mute(Bool)
    case talking(Bool)
    /// Local AirPods battery, 0...100, or nil if unknown.
    case battery(Int?)
    /// Latency probe; the receiver answers with `pong` carrying its receive and send clocks.
    case ping(id: UInt32, sentAt: UInt64)
    case pong(id: UInt32, sentAt: UInt64, receivedAt: UInt64, repliedAt: UInt64)
    /// Codec parameters the sender is now using, so the receiver can configure its decoder.
    case codec(CodecDescriptor)
    case bye(reason: String)

    public struct Hello: Sendable, Equatable, Codable {
        public var protocolVersion: UInt8
        public var displayName: String
        public var nonce: UInt64
        public var deviceIdentifier: String
        public init(protocolVersion: UInt8 = PacketHeader.currentVersion, displayName: String, nonce: UInt64, deviceIdentifier: String) {
            self.protocolVersion = protocolVersion
            self.displayName = displayName
            self.nonce = nonce
            self.deviceIdentifier = deviceIdentifier
        }
    }

    public struct CodecDescriptor: Sendable, Equatable, Codable {
        public var name: String
        public var sampleRate: Int
        public var channels: Int
        public var frameDurationMilliseconds: Int
        public var bitrate: Int?
        public init(name: String, sampleRate: Int, channels: Int = 1, frameDurationMilliseconds: Int = 20, bitrate: Int? = nil) {
            self.name = name
            self.sampleRate = sampleRate
            self.channels = channels
            self.frameDurationMilliseconds = frameDurationMilliseconds
            self.bitrate = bitrate
        }
    }

    public func encoded() throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Array(try encoder.encode(self))
    }

    public static func decode(_ bytes: [UInt8]) throws -> ControlMessage {
        try JSONDecoder().decode(ControlMessage.self, from: Data(bytes))
    }
}
