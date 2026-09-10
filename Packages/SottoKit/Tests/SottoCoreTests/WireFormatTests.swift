import Testing
@testable import SottoCore

@Suite struct WireFormatTests {
    @Test func headerRoundTrips() {
        let h = PacketHeader(kind: .audio, flags: [.fecPresent], sequence: 0xBEEF, timestamp: 0xDEADBEEF, payloadLength: 61)
        var bytes: [UInt8] = []
        h.encode(into: &bytes)
        #expect(bytes.count == PacketHeader.encodedSize)
        #expect(bytes[0] == 1)
        #expect(bytes[1] == 0b0001_0000)
        #expect(PacketHeader.decode(bytes) == h)
    }

    @Test func controlKindIsInLowNibble() {
        let h = PacketHeader(kind: .control, flags: [.silence], sequence: 1, timestamp: 2, payloadLength: 3)
        var bytes: [UInt8] = []
        h.encode(into: &bytes)
        #expect(bytes[1] == 0b0010_0001)
        #expect(PacketHeader.decode(bytes)?.kind == .control)
        #expect(PacketHeader.decode(bytes)?.flags == [.silence])
    }

    @Test func rejectsShortWrongVersionAndUnknownKind() {
        #expect(PacketHeader.decode([1, 0, 0]) == nil)
        var bytes: [UInt8] = []
        PacketHeader(kind: .audio, sequence: 0, timestamp: 0, payloadLength: 0).encode(into: &bytes)
        bytes[0] = 9
        #expect(PacketHeader.decode(bytes) == nil)
        bytes[0] = 1; bytes[1] = 0x0F
        #expect(PacketHeader.decode(bytes) == nil)
    }

    @Test func packetDatagramRoundTrip() {
        let p = Packet(kind: .audio, sequence: 7, timestamp: 960 * 7, payload: Array(0..<60))
        let bytes = p.encoded()
        #expect(bytes.count == 70)
        #expect(Packet.decode(datagram: bytes) == p)
        #expect(Packet.decode(datagram: bytes + [0]) == nil)
        #expect(Packet.decode(datagram: Array(bytes.dropLast())) == nil)
    }

    @Test func sequenceDistanceWraps() {
        #expect(UInt16(65535).sequenceDistance(to: 0) == 1)
        #expect(UInt16(0).sequenceDistance(to: 65535) == -1)
        #expect(UInt16(10).sequenceDistance(to: 13) == 3)
    }
}

@Suite struct StreamFramerTests {
    @Test func reassemblesAcrossArbitrarySplits() {
        let packets = (0..<20).map { Packet(kind: .audio, sequence: UInt16($0), timestamp: UInt32($0) * 480, payload: [UInt8](repeating: UInt8($0), count: 40 + $0)) }
        let stream = packets.flatMap { $0.encoded() }
        var framer = StreamFramer()
        var out: [Packet] = []
        var i = 0
        var step = 1
        while i < stream.count {
            let end = min(stream.count, i + step)
            out += framer.append(stream[i..<end])
            i = end
            step = (step * 7 + 3) % 23 + 1
        }
        #expect(out == packets)
        #expect(framer.pendingByteCount == 0)
        #expect(framer.discardedBytes == 0)
    }

    @Test func resynchronisesAfterGarbage() {
        let good = Packet(kind: .control, sequence: 1, timestamp: 0, payload: [1, 2, 3])
        var framer = StreamFramer()
        let out = framer.append([0xFF, 0x00, 0x42] + good.encoded())
        #expect(out == [good])
        #expect(framer.discardedBytes == 3)
    }

    @Test func boundsPayloadLength() {
        var bytes: [UInt8] = []
        PacketHeader(kind: .audio, sequence: 0, timestamp: 0, payloadLength: 60000).encode(into: &bytes)
        var framer = StreamFramer()
        _ = framer.append(bytes)
        // Should not wait for 60 000 bytes; the bogus header is skipped byte by byte.
        #expect(framer.pendingByteCount < PacketHeader.encodedSize)
    }
}

@Suite struct ControlMessageTests {
    @Test func jsonRoundTrip() throws {
        let messages: [ControlMessage] = [
            .hello(.init(displayName: "Robbie", nonce: 42, deviceIdentifier: "A")),
            .mute(true), .talking(false), .battery(nil), .battery(77),
            .ping(id: 1, sentAt: 100), .pong(id: 1, sentAt: 100, receivedAt: 150, repliedAt: 160),
            .codec(.init(name: "opus", sampleRate: 24000, bitrate: 20000)),
            .bye(reason: "userEnded"),
        ]
        for m in messages {
            #expect(try ControlMessage.decode(try m.encoded()) == m)
        }
    }
}

@Suite struct PairingRaceTests {
    @Test func lowerNonceIsPublisher() {
        #expect(PairingRace.role(localNonce: 1, remoteNonce: 2, localIdentifier: "a", remoteIdentifier: "b") == .publisher)
        #expect(PairingRace.role(localNonce: 2, remoteNonce: 1, localIdentifier: "a", remoteIdentifier: "b") == .subscriber)
    }
    @Test func equalNoncesFallBackToIdentifierAndStayAsymmetric() {
        let a = PairingRace.role(localNonce: 5, remoteNonce: 5, localIdentifier: "a", remoteIdentifier: "b")
        let b = PairingRace.role(localNonce: 5, remoteNonce: 5, localIdentifier: "b", remoteIdentifier: "a")
        #expect(a != b)
    }
}

@Suite struct LatencyProbeTests {
    @Test func computesRoundTripAndOffset() throws {
        // Remote clock runs 1 s ahead; one-way delay 10 ms; remote processing 2 ms.
        let s = try #require(LatencySample(id: 1, sentAt: 0, receivedAt: 1_010_000_000, repliedAt: 1_012_000_000, pongArrivedAt: 22_000_000))
        #expect(s.roundTripNanoseconds == 20_000_000)
        #expect(s.clockOffsetNanoseconds == 1_000_000_000)
        #expect(s.oneWayMilliseconds == 10)
    }
    @Test func rejectsInconsistentClocks() {
        #expect(LatencySample(id: 1, sentAt: 10, receivedAt: 0, repliedAt: 0, pongArrivedAt: 5) == nil)
    }
    @Test func estimatorUsesMinimumRTTAndMedianOffset() throws {
        var e = LatencyEstimator(windowSize: 3)
        // t1 = t2 = offset + rtt/2 and t3 = rtt gives offset exactly and no remote processing time.
        for (rtt, off) in [(30, 5), (20, 7), (40, 100), (26, 6)] {
            e.add(try #require(LatencySample(id: 0, sentAt: 0, receivedAt: UInt64(off + rtt / 2), repliedAt: UInt64(off + rtt / 2), pongArrivedAt: UInt64(rtt))))
        }
        #expect(e.samples.count == 3)
        #expect(e.bestRoundTripMilliseconds == 20 / 1_000_000.0)
        #expect(e.medianClockOffsetNanoseconds == 7)
    }
}

@Suite struct SessionReducerTests {
    @Test func happyPath() {
        let p = Partner(id: "p", displayName: "P")
        var s: SessionState = .idle
        for e in [SessionEvent.start, .pairRequested, .roleResolved(.subscriber), .linkEstablished(p, .wifiAware), .helloCompleted] {
            s = SessionReducer.reduce(s, e)!
        }
        #expect(s == .connected(p, over: .wifiAware))
        #expect(s.isLive)
        #expect(SessionReducer.reduce(s, .userEnded) == .ended(.userEnded))
    }
    @Test func reconnectGivesUpAfterLimit() {
        let p = Partner(id: "p", displayName: "P")
        var s: SessionState = .connected(p, over: .bleL2CAP)
        s = SessionReducer.reduce(s, .linkDropped)!
        #expect(s == .reconnecting(p, attempt: 1))
        s = SessionReducer.reduce(s, .reconnectAttempt(SessionReducer.maximumReconnectAttempts + 1))!
        #expect(s == .ended(.linkLost))
    }
    @Test func invalidTransitionsReturnNil() {
        #expect(SessionReducer.reduce(.idle, .helloCompleted) == nil)
        #expect(SessionReducer.reduce(.idle, .userEnded) == nil)
    }
}
