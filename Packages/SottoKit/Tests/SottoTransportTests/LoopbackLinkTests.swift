import Testing
import SottoCore
@testable import SottoTransport

@Suite struct LoopbackLinkTests {
    @Test func deliversInBothDirections() async throws {
        let pair = LoopbackLinkPair()
        let p = Packet(kind: .control, sequence: 1, timestamp: 0, payload: [9])
        try await pair.a.send(p)
        try await pair.b.send(p)
        await pair.advance(to: 0)
        var it = pair.b.events.makeAsyncIterator()
        #expect(await it.next() == .ready)
        #expect(await it.next() == .received(p))
        var ia = pair.a.events.makeAsyncIterator()
        #expect(await ia.next() == .ready)
        #expect(await ia.next() == .received(p))
    }

    @Test func impairmentDropsAndDelaysDeterministically() async throws {
        var model = ImpairmentModel()
        model.lossProbability = 0.5
        model.baseDelayMilliseconds = 10
        model.connectionIntervalMilliseconds = 15
        model.seed = 3
        let pair = LoopbackLinkPair(model: model)
        for i in 0..<100 { try await pair.a.send(Packet(kind: .audio, sequence: UInt16(i), timestamp: 0, payload: [])) }
        #expect(await pair.pendingCount < 100)
        #expect(await pair.pendingCount > 0)
        await pair.advance(to: 14)
        #expect(await pair.pendingCount > 0) // quantised to 15 ms boundary, nothing before
        await pair.advance(to: 15)
        #expect(await pair.pendingCount == 0)
    }

    @Test func closePropagates() async throws {
        let pair = LoopbackLinkPair()
        await pair.a.close()
        var ib = pair.b.events.makeAsyncIterator()
        #expect(await ib.next() == .ready)
        #expect(await ib.next() == .closed(.remote))
        #expect(await ib.next() == nil)
        await #expect(throws: LinkError.notReady) { try await pair.b.send(Packet(kind: .control, sequence: 0, timestamp: 0, payload: [])) }
    }
}
