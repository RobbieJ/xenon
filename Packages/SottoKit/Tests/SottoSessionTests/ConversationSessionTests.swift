import Foundation
import Testing
import SottoCore
import SottoAudio
import SottoTransport
@testable import SottoSession

/// Test audio source: the test pushes frames in by hand.
final class ManualSource: AudioSource, @unchecked Sendable {
    private var handler: (@Sendable (PCMFrame) -> Void)?
    private let lock = NSLock()
    func start(onFrame: @escaping @Sendable (PCMFrame) -> Void) throws { lock.withLock { handler = onFrame } }
    func stop() { lock.withLock { handler = nil } }
    func push(_ frame: PCMFrame) { lock.withLock { handler }?(frame) }
}

private func tone(_ index: Int, samples: Int, sampleRate: Double = 24000, hz: Double = 440) -> PCMFrame {
    (0..<samples).map { i in
        let t = Double(index * samples + i) / sampleRate
        return Int16(8000 * sin(2 * .pi * hz * t))
    }
}

/// Drains an AsyncStream-driven pipeline: gives queued tasks a chance to run.
private func settle() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(5)) }

/// Waits (up to ~1 s) until the loopback pair holds at least `count` undelivered packets.
private func waitForQueued(_ pair: LoopbackLinkPair, atLeast count: Int) async {
    for _ in 0..<200 {
        if await pair.pendingCount >= count { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Virtual clock shared by the session and the loopback pair: 1 ms per loopback millisecond.
final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Double = 0
    func set(_ v: Double) { lock.withLock { ms = v } }
    var nanoseconds: UInt64 { lock.withLock { UInt64(ms * 1_000_000) } }
}

private func makeOptions(clock: VirtualClock) -> ConversationSession.Options {
    var options = ConversationSession.Options()
    options.pingInterval = .zero
    options.now = { clock.nanoseconds }
    return options
}

@Suite struct ConversationSessionTests {
    @Test func audioFlowsEndToEndOverAnIdealLink() async throws {
        let pair = LoopbackLinkPair()
        let clock = VirtualClock()
        let srcA = ManualSource(), srcB = ManualSource()
        let options = makeOptions(clock: clock)
        let a = try ConversationSession(source: srcA, link: pair.a, codec: .bleL2CAP, hello: .init(displayName: "A", nonce: 1, deviceIdentifier: "A"), options: options)
        let b = try ConversationSession(source: srcB, link: pair.b, codec: .bleL2CAP, hello: .init(displayName: "B", nonce: 2, deviceIdentifier: "B"), options: options)
        try a.start(); try b.start()
        await settle(); await pair.advance(to: 0); await settle()

        let n = a.codec.samplesPerFrame
        var received: [PCMFrame] = []
        for i in 0..<60 {
            srcA.push(tone(i, samples: n))
            await waitForQueued(pair, atLeast: 1)
            clock.set(Double(i + 1) * 20)
            await pair.advance(to: Double(i + 1) * 20)
            await settle()
            received.append(b.nextPlayoutFrame())
        }
        let stats = b.jitterStatistics
        #expect(stats.received == 60)
        #expect(stats.concealed == 0)
        // After prefill (2 frames) every pulled frame is real audio, so the tail must not be silent.
        let energy = received.suffix(40).map { LevelMeter.rmsDBFS($0) }
        #expect(energy.allSatisfy { $0 > -40 })
        a.stop(); b.stop()
    }

    @Test func survivesLossJitterAndConnectionIntervals() async throws {
        var model = ImpairmentModel()
        model.baseDelayMilliseconds = 15
        model.jitterMilliseconds = 40
        model.lossProbability = 0.05
        model.connectionIntervalMilliseconds = 30
        model.seed = 11
        let pair = LoopbackLinkPair(model: model)
        let clock = VirtualClock()
        let srcA = ManualSource(), srcB = ManualSource()
        let options = makeOptions(clock: clock)
        let a = try ConversationSession(source: srcA, link: pair.a, codec: .bleL2CAP, hello: .init(displayName: "A", nonce: 1, deviceIdentifier: "A"), options: options)
        let b = try ConversationSession(source: srcB, link: pair.b, codec: .bleL2CAP, hello: .init(displayName: "B", nonce: 2, deviceIdentifier: "B"), options: options)
        try a.start(); try b.start()
        await settle(); await pair.advance(to: 0); await settle()

        let n = a.codec.samplesPerFrame
        var nonSilent = 0
        let frames = 300
        for i in 0..<frames {
            srcA.push(tone(i, samples: n))
            await settle()
            clock.set(Double(i + 1) * 20)
            await pair.advance(to: Double(i + 1) * 20)
            await settle()
            if LevelMeter.rmsDBFS(b.nextPlayoutFrame()) > -40 { nonSilent += 1 }
        }
        let stats = b.jitterStatistics
        #expect(stats.received > frames * 9 / 10)
        #expect(stats.concealed < frames / 5)
        #expect(nonSilent > frames * 3 / 4)
        #expect(stats.targetMilliseconds >= 40)
        a.stop(); b.stop()
    }

    @Test func controlMessagesArriveAndMuteStopsAudio() async throws {
        let pair = LoopbackLinkPair()
        let srcA = ManualSource(), srcB = ManualSource()
        let options = makeOptions(clock: VirtualClock())
        let a = try ConversationSession(source: srcA, link: pair.a, codec: .bleL2CAP, hello: .init(displayName: "Alice", nonce: 1, deviceIdentifier: "A"), options: options)
        let b = try ConversationSession(source: srcB, link: pair.b, codec: .bleL2CAP, hello: .init(displayName: "Bob", nonce: 2, deviceIdentifier: "B"), options: options)
        let events = EventLog()
        b.onEvent = { events.append($0) }
        try a.start(); try b.start()
        await settle(); await pair.advance(to: 0); await settle()
        #expect(events.contains { if case .partnerHello(let h) = $0 { return h.displayName == "Alice" }; return false })

        a.setMuted(true)
        await settle(); await pair.advance(to: 1); await settle()
        #expect(events.contains { $0 == .partnerMuted(true) })
        let before = b.jitterStatistics.received
        srcA.push(tone(0, samples: a.codec.samplesPerFrame))
        await settle(); await pair.advance(to: 2); await settle()
        #expect(b.jitterStatistics.received == before)
        a.stop(); b.stop()
    }
}

final class EventLog: @unchecked Sendable {
    private var items: [ConversationSession.Event] = []
    private let lock = NSLock()
    func append(_ e: ConversationSession.Event) { lock.withLock { items.append(e) } }
    func contains(_ p: (ConversationSession.Event) -> Bool) -> Bool { lock.withLock { items.contains(where: p) } }
}
