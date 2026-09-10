import Foundation
import Testing
import SottoCore
@testable import SottoAudio

private let frameNs: UInt64 = 20_000_000

private func audioPacket(_ seq: Int, marker: UInt8 = 0) -> Packet {
    Packet(kind: .audio, sequence: UInt16(truncatingIfNeeded: seq), timestamp: UInt32(seq) * 480, payload: [UInt8(truncatingIfNeeded: seq), marker])
}

private func seq(of out: JitterBuffer.Output) -> UInt16? {
    if case .frame(_, let s, _) = out { return s }
    return nil
}

/// Deterministic LCG so traces are reproducible.
private struct Rng {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
    mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000 }
}

@Suite struct JitterBufferTests {
    @Test func prefillsThenPlaysInOrder() {
        var jb = JitterBuffer()
        #expect(jb.pop() == .prefill)
        jb.push(audioPacket(0), arrivedAt: 0)
        #expect(jb.pop() == .prefill) // target 40 ms = 2 frames
        jb.push(audioPacket(1), arrivedAt: frameNs)
        #expect(seq(of: jb.pop()) == 0)
        #expect(seq(of: jb.pop()) == 1)
        #expect(jb.statistics.played == 2)
    }

    @Test func concealsAnIsolatedLossAndOffersFEC() {
        var jb = JitterBuffer()
        for i in [0, 1, 3, 4] { jb.push(audioPacket(i), arrivedAt: UInt64(i) * frameNs) }
        #expect(seq(of: jb.pop()) == 0)
        #expect(seq(of: jb.pop()) == 1)
        let out = jb.pop()
        #expect(out == .conceal(fecCandidate: audioPacket(3).payload))
        #expect(seq(of: jb.pop()) == 3)
        #expect(jb.statistics.concealed == 1)
    }

    @Test func discardsLateAndDuplicatePackets() {
        var jb = JitterBuffer()
        for i in 0..<4 { jb.push(audioPacket(i), arrivedAt: UInt64(i) * frameNs) }
        _ = jb.pop(); _ = jb.pop()
        jb.push(audioPacket(0), arrivedAt: 10 * frameNs) // late
        jb.push(audioPacket(3), arrivedAt: 10 * frameNs) // duplicate
        #expect(jb.statistics.lateDiscarded == 1)
        #expect(jb.statistics.duplicates == 1)
    }

    @Test func skipsAheadAfterAStall() {
        var jb = JitterBuffer()
        for i in 0..<3 { jb.push(audioPacket(i), arrivedAt: UInt64(i) * frameNs) }
        for _ in 0..<3 { _ = jb.pop() }
        // 300 ms stall, then 15 frames arrive at once (3..17).
        for i in 3..<18 { jb.push(audioPacket(i), arrivedAt: 18 * frameNs) }
        // Hard cap (240 ms = 12 frames) trims the burst; whatever arrives after the trim is within the cap.
        let depth = jb.currentDepthFrames()
        #expect(depth < 12)
        let next = seq(of: jb.pop())
        #expect(next != nil && next! > 3)
        #expect(jb.statistics.accelerated > 0)
    }

    @Test func raisesTargetUnderJitterAndStaysWithinClamp() {
        var jb = JitterBuffer()
        var rng = Rng(state: 7)
        for i in 0..<200 {
            let jitter = UInt64(rng.unit() * 60_000_000) // up to 60 ms late
            jb.push(audioPacket(i), arrivedAt: UInt64(i) * frameNs + jitter)
            _ = jb.pop()
        }
        #expect(jb.targetMilliseconds >= 60)
        #expect(jb.targetMilliseconds <= 120)
    }

    @Test func handlesSequenceWrap() {
        var jb = JitterBuffer()
        let start = 65530
        for i in start..<(start + 12) { jb.push(audioPacket(i), arrivedAt: UInt64(i - start) * frameNs) }
        var played: [UInt16] = []
        for _ in 0..<12 { if let s = seq(of: jb.pop()) { played.append(s) } }
        #expect(played == (start..<(start + 12)).map { UInt16(truncatingIfNeeded: $0) })
    }

    @Test func absorbsClockDriftByAccelerating() {
        // Sender clock 1% fast: 101 frames arrive for every 100 played. Depth must not grow unbounded.
        var jb = JitterBuffer()
        var pushed = 0
        for tick in 0..<3000 {
            let due = Int(Double(tick) * 1.01)
            while pushed <= due { jb.push(audioPacket(pushed), arrivedAt: UInt64(tick) * frameNs); pushed += 1 }
            _ = jb.pop()
        }
        #expect(jb.currentDepthFrames() <= jb.targetMilliseconds / 20 + 2)
        #expect(jb.statistics.accelerated >= 20)
    }

    @Test func absorbsSlowSenderByExpanding() {
        // Sender clock 1% slow: fewer frames than pulls. Depth should be held up by expansions rather than run dry into concealments.
        var jb = JitterBuffer()
        var pushed = 0
        for tick in 0..<3000 {
            let due = Int(Double(tick) * 0.99)
            while pushed <= due { jb.push(audioPacket(pushed), arrivedAt: UInt64(tick) * frameNs); pushed += 1 }
            _ = jb.pop()
        }
        #expect(jb.statistics.expanded >= 10)
    }
}

@Suite struct CodecTests {
    @Test func pcmRoundTrip() throws {
        var enc = PCM16Encoder()
        var dec = PCM16Decoder()
        let frame = (0..<480).map { Int16(truncatingIfNeeded: $0 * 37 - 9000) }
        let bytes = try enc.encode(frame)
        #expect(bytes.count == 960)
        #expect(try dec.decode(bytes, fec: false) == frame)
        let concealed = try dec.decode(nil, fec: false)
        #expect(concealed[10] == frame[10] / 2)
    }
    @Test func rejectsWrongFrameSize() {
        var enc = PCM16Encoder()
        #expect(throws: CodecError.invalidFrameSize(expected: 480, got: 3)) { try enc.encode([1, 2, 3]) }
    }
}

@Suite struct LevelMeterTests {
    @Test func silenceIsInactiveToneIsActiveWithHangover() {
        var m = LevelMeter(thresholdDBFS: -40, hangoverFrames: 2)
        let silence = PCMFrame(repeating: 0, count: 480)
        let tone = (0..<480).map { Int16(10000 * sin(Double($0) * 0.2)) }
        #expect(m.process(silence) == false)
        #expect(m.process(tone) == true)
        #expect(m.lastLevelDBFS > -20)
        #expect(m.process(silence) == true)
        #expect(m.process(silence) == true)
        #expect(m.process(silence) == false)
    }
}
