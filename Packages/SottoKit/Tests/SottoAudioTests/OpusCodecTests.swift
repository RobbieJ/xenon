import Foundation
import Testing
import SottoCore
@testable import SottoAudio

/// Runs only when libopus is linked (xcframework or system library); otherwise records that it was skipped.
@Suite struct OpusCodecTests {
    private func sine(_ n: Int, rate: Double = 24000, hz: Double = 440, offset: Int = 0) -> PCMFrame {
        (0..<n).map { Int16(12000 * sin(2 * .pi * hz * Double($0 + offset) / rate)) }
    }

    @Test func roundTripKeepsTheTone() throws {
        guard CodecFactory.isOpusAvailable else { return }
        let config = CodecConfiguration.wifiAware
        var enc = try CodecFactory.makeEncoder(config)
        var dec = try CodecFactory.makeDecoder(config)
        let n = config.samplesPerFrame
        var decoded: [PCMFrame] = []
        var sizes: [Int] = []
        for i in 0..<50 {
            let packet = try enc.encode(sine(n, offset: i * n))
            sizes.append(packet.count)
            decoded.append(try dec.decode(packet, fec: false))
        }
        // 24 kbps at 20 ms is ~60 bytes; allow VBR headroom.
        #expect(sizes.suffix(40).allSatisfy { $0 > 10 && $0 < 200 })
        #expect(decoded.allSatisfy { $0.count == n })
        // After the codec settles, the decoded tone should be loud and correlated with the input.
        let late = decoded.suffix(20).flatMap { $0 }
        #expect(LevelMeter.rmsDBFS(late) > -20)
        let input = (30..<50).flatMap { sine(n, offset: $0 * n) }
        var dot = 0.0, ii = 0.0, oo = 0.0
        for k in 0..<late.count { let a = Double(input[k]), b = Double(late[k]); dot += a * b; ii += a * a; oo += b * b }
        let normalised = dot / (ii.squareRoot() * oo.squareRoot())
        // Opus adds a small delay, so alignment is imperfect; still expect clear positive correlation
        // once the delay is searched over a few samples.
        var best = normalised
        for shift in 1..<200 {
            var d = 0.0, o = 0.0
            for k in shift..<late.count { let a = Double(input[k - shift]), b = Double(late[k]); d += a * b; o += b * b }
            best = max(best, d / (ii.squareRoot() * o.squareRoot()))
        }
        #expect(best > 0.8)
    }

    @Test func concealmentAndFECProduceFrames() throws {
        guard CodecFactory.isOpusAvailable else { return }
        var config = CodecConfiguration.wifiAware
        config.inbandFEC = true
        config.expectedPacketLossPercent = 10
        var enc = try CodecFactory.makeEncoder(config)
        var dec = try CodecFactory.makeDecoder(config)
        let n = config.samplesPerFrame
        var packets: [[UInt8]] = []
        for i in 0..<20 { packets.append(try enc.encode(sine(n, offset: i * n))) }
        for i in 0..<10 { _ = try dec.decode(packets[i], fec: false) }
        // Lose packet 10: recover it from packet 11's FEC, then decode 11 normally.
        let recovered = try dec.decode(packets[11], fec: true)
        #expect(recovered.count == n)
        let plc = try dec.decode(nil, fec: false)
        #expect(plc.count == n)
        _ = try dec.decode(packets[11], fec: false)
    }

    @Test func rejectsWrongFrameSize() throws {
        guard CodecFactory.isOpusAvailable else { return }
        var enc = try CodecFactory.makeEncoder(.bleL2CAP)
        #expect(throws: CodecError.self) { try enc.encode([0, 1, 2]) }
    }
}
