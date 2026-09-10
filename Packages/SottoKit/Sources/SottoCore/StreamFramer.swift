import Foundation

/// Reassembles packets from a byte stream (for example a BLE L2CAP channel, which does not
/// preserve SDU boundaries). Feed it bytes as they arrive and drain the packets it emits.
///
/// Resynchronisation: if the bytes at the head do not decode as a valid header, the framer
/// skips one byte at a time until a plausible header appears. Payload lengths are also bounded
/// so a corrupted length field cannot stall the stream for long.
public struct StreamFramer: Sendable {
    public static let maximumPayloadLength = 2048

    private var buffer: [UInt8] = []
    private(set) public var discardedBytes = 0

    public init() {}

    /// Appends bytes and returns every complete packet now available, in order.
    public mutating func append(_ bytes: some Sequence<UInt8>) -> [Packet] {
        buffer.append(contentsOf: bytes)
        var packets: [Packet] = []
        var cursor = 0
        while buffer.count - cursor >= PacketHeader.encodedSize {
            guard let header = PacketHeader.decode(buffer[cursor...]), Int(header.payloadLength) <= Self.maximumPayloadLength else {
                cursor += 1
                discardedBytes += 1
                continue
            }
            let end = cursor + PacketHeader.encodedSize + Int(header.payloadLength)
            guard end <= buffer.count else { break }
            packets.append(Packet(header: header, payload: Array(buffer[(cursor + PacketHeader.encodedSize)..<end])))
            cursor = end
        }
        if cursor > 0 { buffer.removeFirst(cursor) }
        return packets
    }

    public var pendingByteCount: Int { buffer.count }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}
