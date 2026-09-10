import Foundation
import SottoCore

#if SOTTO_HAS_OPUS
import Copus

/// libopus wrapper. Requires Vendor/opus.xcframework, built by Scripts/build-opus-xcframework.sh,
/// which also compiles the tiny C shim that replaces the variadic `opus_encoder_ctl`.
public final class OpusEncoderBox: VoiceEncoder, @unchecked Sendable {
    public let configuration: CodecConfiguration
    private let encoder: OpaquePointer
    private var out = [UInt8](repeating: 0, count: 1275)

    public init(configuration: CodecConfiguration) throws {
        self.configuration = configuration
        var err: Int32 = 0
        guard let enc = opus_encoder_create(Int32(configuration.sampleRate), 1, OPUS_APPLICATION_VOIP, &err), err == OPUS_OK else {
            throw CodecError.encodeFailed(err)
        }
        encoder = enc
        _ = sotto_opus_encoder_set_bitrate(enc, Int32(configuration.bitrate))
        _ = sotto_opus_encoder_set_complexity(enc, Int32(configuration.complexity))
        _ = sotto_opus_encoder_set_inband_fec(enc, configuration.inbandFEC ? 1 : 0)
        _ = sotto_opus_encoder_set_packet_loss_perc(enc, Int32(configuration.expectedPacketLossPercent))
        _ = sotto_opus_encoder_set_dtx(enc, 0)
        _ = sotto_opus_encoder_set_signal_voice(enc)
    }

    deinit { opus_encoder_destroy(encoder) }

    public func encode(_ frame: PCMFrame) throws -> [UInt8] {
        guard frame.count == configuration.samplesPerFrame else {
            throw CodecError.invalidFrameSize(expected: configuration.samplesPerFrame, got: frame.count)
        }
        let n = frame.withUnsafeBufferPointer { pcm in
            out.withUnsafeMutableBufferPointer { buf in
                opus_encode(encoder, pcm.baseAddress, Int32(frame.count), buf.baseAddress, Int32(buf.count))
            }
        }
        guard n > 0 else { throw CodecError.encodeFailed(n) }
        return Array(out[0..<Int(n)])
    }
}

public final class OpusDecoderBox: VoiceDecoder, @unchecked Sendable {
    public let configuration: CodecConfiguration
    private let decoder: OpaquePointer

    public init(configuration: CodecConfiguration) throws {
        self.configuration = configuration
        var err: Int32 = 0
        guard let dec = opus_decoder_create(Int32(configuration.sampleRate), 1, &err), err == OPUS_OK else {
            throw CodecError.decodeFailed(err)
        }
        decoder = dec
    }

    deinit { opus_decoder_destroy(decoder) }

    public func decode(_ packet: [UInt8]?, fec: Bool) throws -> PCMFrame {
        var pcm = PCMFrame(repeating: 0, count: configuration.samplesPerFrame)
        let n: Int32 = pcm.withUnsafeMutableBufferPointer { buf in
            if let packet {
                return packet.withUnsafeBufferPointer { p in
                    opus_decode(decoder, p.baseAddress, Int32(packet.count), buf.baseAddress, Int32(buf.count), fec ? 1 : 0)
                }
            } else {
                return opus_decode(decoder, nil, 0, buf.baseAddress, Int32(buf.count), 0)
            }
        }
        guard n > 0 else { throw CodecError.decodeFailed(n) }
        return n == pcm.count ? pcm : Array(pcm[0..<Int(n)])
    }
}
#endif

/// Picks Opus when the library is linked, otherwise raw PCM (measurement builds and tests).
public enum CodecFactory {
    public static var isOpusAvailable: Bool {
        #if SOTTO_HAS_OPUS
        return true
        #else
        return false
        #endif
    }

    public static func makeEncoder(_ configuration: CodecConfiguration) throws -> any VoiceEncoder {
        #if SOTTO_HAS_OPUS
        return try OpusEncoderBox(configuration: configuration)
        #else
        return PCM16Encoder(configuration: configuration)
        #endif
    }

    public static func makeDecoder(_ configuration: CodecConfiguration) throws -> any VoiceDecoder {
        #if SOTTO_HAS_OPUS
        return try OpusDecoderBox(configuration: configuration)
        #else
        return PCM16Decoder(configuration: configuration)
        #endif
    }
}
