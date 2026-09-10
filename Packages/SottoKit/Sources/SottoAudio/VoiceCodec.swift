import Foundation
import SottoCore

/// One mono frame of 16-bit PCM.
public typealias PCMFrame = [Int16]

public struct CodecConfiguration: Sendable, Equatable {
    public var sampleRate: Int
    public var frameDurationMilliseconds: Int
    public var bitrate: Int
    public var inbandFEC: Bool
    public var expectedPacketLossPercent: Int
    public var complexity: Int

    public init(sampleRate: Int = 24000, frameDurationMilliseconds: Int = 20, bitrate: Int = 20000, inbandFEC: Bool = false, expectedPacketLossPercent: Int = 0, complexity: Int = 7) {
        self.sampleRate = sampleRate
        self.frameDurationMilliseconds = frameDurationMilliseconds
        self.bitrate = bitrate
        self.inbandFEC = inbandFEC
        self.expectedPacketLossPercent = expectedPacketLossPercent
        self.complexity = complexity
    }

    public var samplesPerFrame: Int { sampleRate * frameDurationMilliseconds / 1000 }

    /// Profile used over Wi-Fi Aware: lossy datagrams, plenty of bandwidth.
    public static let wifiAware = CodecConfiguration(sampleRate: 24000, bitrate: 24000, inbandFEC: true, expectedPacketLossPercent: 5)
    /// Profile used over BLE L2CAP: reliable stream, tight bandwidth. FEC off; the sender drops stale frames instead.
    public static let bleL2CAP = CodecConfiguration(sampleRate: 24000, bitrate: 16000, inbandFEC: false)

    public var descriptor: ControlMessage.CodecDescriptor {
        .init(name: "opus", sampleRate: sampleRate, channels: 1, frameDurationMilliseconds: frameDurationMilliseconds, bitrate: bitrate)
    }
}

public enum CodecError: Error, Equatable {
    case unavailable(String)
    case invalidFrameSize(expected: Int, got: Int)
    case encodeFailed(Int32)
    case decodeFailed(Int32)
}

public protocol VoiceEncoder: Sendable {
    var configuration: CodecConfiguration { get }
    /// Encodes exactly one frame of `configuration.samplesPerFrame` samples.
    mutating func encode(_ frame: PCMFrame) throws -> [UInt8]
}

public protocol VoiceDecoder: Sendable {
    var configuration: CodecConfiguration { get }
    /// Decodes one packet. Pass nil for a lost packet to run packet-loss concealment.
    /// `fec` asks the decoder to recover the *previous* frame from this packet's in-band FEC.
    mutating func decode(_ packet: [UInt8]?, fec: Bool) throws -> PCMFrame
}

/// Codec-free passthrough used in tests and the phase 0 measurement build. Frames are sent as raw
/// little-endian PCM; "concealment" repeats the last frame with a decaying gain.
public struct PCM16Encoder: VoiceEncoder {
    public let configuration: CodecConfiguration
    public init(configuration: CodecConfiguration = CodecConfiguration()) { self.configuration = configuration }
    public mutating func encode(_ frame: PCMFrame) throws -> [UInt8] {
        guard frame.count == configuration.samplesPerFrame else {
            throw CodecError.invalidFrameSize(expected: configuration.samplesPerFrame, got: frame.count)
        }
        var out: [UInt8] = []
        out.reserveCapacity(frame.count * 2)
        for s in frame {
            let u = UInt16(bitPattern: s)
            out.append(UInt8(u & 0xFF)); out.append(UInt8(u >> 8))
        }
        return out
    }
}

public struct PCM16Decoder: VoiceDecoder {
    public let configuration: CodecConfiguration
    private var last: PCMFrame
    private var concealCount = 0
    public init(configuration: CodecConfiguration = CodecConfiguration()) {
        self.configuration = configuration
        self.last = PCMFrame(repeating: 0, count: configuration.samplesPerFrame)
    }
    public mutating func decode(_ packet: [UInt8]?, fec: Bool) throws -> PCMFrame {
        guard let packet else {
            concealCount += 1
            let gain = max(0, 1.0 - 0.5 * Double(concealCount))
            last = last.map { Int16(Double($0) * gain) }
            return last
        }
        guard packet.count == configuration.samplesPerFrame * 2 else {
            throw CodecError.invalidFrameSize(expected: configuration.samplesPerFrame * 2, got: packet.count)
        }
        concealCount = 0
        var frame = PCMFrame(repeating: 0, count: configuration.samplesPerFrame)
        for i in 0..<frame.count {
            frame[i] = Int16(bitPattern: UInt16(packet[2 * i]) | UInt16(packet[2 * i + 1]) << 8)
        }
        last = frame
        return frame
    }
}
