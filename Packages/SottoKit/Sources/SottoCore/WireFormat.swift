import Foundation

/// The kind of payload a packet carries. Stored in the low nibble of the header flags.
public enum PacketKind: UInt8, Sendable, Equatable {
    case audio = 0
    case control = 1
}

/// Header flags. The low nibble is the `PacketKind`; the high nibble is reserved for hints.
public struct PacketFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The Opus payload carries in-band FEC for the previous frame.
    public static let fecPresent = PacketFlags(rawValue: 0b0001_0000)
    /// The sender considers this frame silence (DTX or gated); receivers may treat a gap as intentional.
    public static let silence = PacketFlags(rawValue: 0b0010_0000)

    static let kindMask: UInt8 = 0b0000_1111
}

/// Ten-byte packet header. Big-endian on the wire.
///
/// ```
/// 0        1        2        4              8              10
/// | version | flags | sequence | timestamp (samples) | payload length |
/// ```
public struct PacketHeader: Sendable, Equatable {
    public static let currentVersion: UInt8 = 1
    public static let encodedSize = 10

    public var version: UInt8
    public var kind: PacketKind
    public var flags: PacketFlags
    /// Wraps at 65 535. Audio and control packets number themselves independently, so the audio
    /// sequence has no gaps when a control message is interleaved.
    public var sequence: UInt16
    /// Sample timestamp of the first sample in the payload at the encoder's sample rate. Wraps.
    public var timestamp: UInt32
    public var payloadLength: UInt16

    public init(kind: PacketKind, flags: PacketFlags = [], sequence: UInt16, timestamp: UInt32, payloadLength: UInt16, version: UInt8 = PacketHeader.currentVersion) {
        self.version = version
        self.kind = kind
        self.flags = PacketFlags(rawValue: flags.rawValue & ~PacketFlags.kindMask)
        self.sequence = sequence
        self.timestamp = timestamp
        self.payloadLength = payloadLength
    }

    public func encode(into buffer: inout [UInt8]) {
        buffer.append(version)
        buffer.append(flags.rawValue | (kind.rawValue & PacketFlags.kindMask))
        buffer.append(UInt8(sequence >> 8)); buffer.append(UInt8(sequence & 0xFF))
        buffer.append(UInt8(timestamp >> 24)); buffer.append(UInt8((timestamp >> 16) & 0xFF))
        buffer.append(UInt8((timestamp >> 8) & 0xFF)); buffer.append(UInt8(timestamp & 0xFF))
        buffer.append(UInt8(payloadLength >> 8)); buffer.append(UInt8(payloadLength & 0xFF))
    }

    /// Decodes a header from the first ten bytes of `bytes`. Returns nil if too short, wrong version or unknown kind.
    public static func decode<C: RandomAccessCollection>(_ bytes: C) -> PacketHeader? where C.Element == UInt8 {
        guard bytes.count >= encodedSize else { return nil }
        var it = bytes.makeIterator()
        let version = it.next()!
        guard version == currentVersion else { return nil }
        let rawFlags = it.next()!
        guard let kind = PacketKind(rawValue: rawFlags & PacketFlags.kindMask) else { return nil }
        let seq = UInt16(it.next()!) << 8 | UInt16(it.next()!)
        let ts = UInt32(it.next()!) << 24 | UInt32(it.next()!) << 16 | UInt32(it.next()!) << 8 | UInt32(it.next()!)
        let len = UInt16(it.next()!) << 8 | UInt16(it.next()!)
        return PacketHeader(kind: kind, flags: PacketFlags(rawValue: rawFlags & ~PacketFlags.kindMask), sequence: seq, timestamp: ts, payloadLength: len, version: version)
    }
}

/// A complete packet: header plus payload. Exactly one Opus frame or one control message.
public struct Packet: Sendable, Equatable {
    public var header: PacketHeader
    public var payload: [UInt8]

    public init(header: PacketHeader, payload: [UInt8]) {
        precondition(payload.count <= Int(UInt16.max))
        self.header = header
        self.header.payloadLength = UInt16(payload.count)
        self.payload = payload
    }

    public init(kind: PacketKind, flags: PacketFlags = [], sequence: UInt16, timestamp: UInt32, payload: [UInt8]) {
        self.init(header: PacketHeader(kind: kind, flags: flags, sequence: sequence, timestamp: timestamp, payloadLength: UInt16(payload.count)), payload: payload)
    }

    public var encodedSize: Int { PacketHeader.encodedSize + payload.count }

    public func encoded() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(encodedSize)
        header.encode(into: &out)
        out.append(contentsOf: payload)
        return out
    }

    /// Decodes exactly one packet from a datagram. Trailing bytes cause failure: datagrams carry one packet.
    public static func decode(datagram bytes: [UInt8]) -> Packet? {
        guard let header = PacketHeader.decode(bytes) else { return nil }
        let end = PacketHeader.encodedSize + Int(header.payloadLength)
        guard bytes.count == end else { return nil }
        return Packet(header: header, payload: Array(bytes[PacketHeader.encodedSize..<end]))
    }
}

public extension UInt16 {
    /// Distance from `self` to `other` in modular arithmetic, positive if `other` is ahead.
    func sequenceDistance(to other: UInt16) -> Int {
        Int(Int16(bitPattern: other &- self))
    }
}
