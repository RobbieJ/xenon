import Foundation
import SottoCore

/// Deterministic network impairment model for tests and the simulator build.
public struct ImpairmentModel: Sendable, Equatable {
    public var baseDelayMilliseconds: Double = 0
    /// Uniform random extra delay in [0, jitterMilliseconds].
    public var jitterMilliseconds: Double = 0
    /// Independent per-packet loss probability.
    public var lossProbability: Double = 0
    /// Quantise delivery to multiples of this interval, like a BLE connection event.
    public var connectionIntervalMilliseconds: Double = 0
    public var seed: UInt64 = 1
    public init() {}
    public static let ideal = ImpairmentModel()
}

/// Two links wired back to back in-process. Packets sent on `a` arrive on `b` and vice versa,
/// after the impairment model has had its say. Uses a virtual clock so tests run instantly:
/// call `advance(to:)` to deliver everything due by then.
public actor LoopbackLinkPair {
    public nonisolated let a: LoopbackLink
    public nonisolated let b: LoopbackLink
    public nonisolated let model: ImpairmentModel
    private var rngState: UInt64
    private var queue: [(due: Double, to: LoopbackLink, packet: Packet)] = []
    public private(set) var nowMilliseconds: Double = 0

    public init(model: ImpairmentModel = .ideal) {
        self.model = model
        self.rngState = model.seed &* 0x9E3779B97F4A7C15 | 1
        self.a = LoopbackLink(kind: .loopback)
        self.b = LoopbackLink(kind: .loopback)
        a.installPair(self, peer: b)
        b.installPair(self, peer: a)
        a.emit(.ready)
        b.emit(.ready)
    }

    private func random() -> Double {
        rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
        return Double(rngState >> 11) / Double(1 << 53)
    }

    func enqueue(_ packet: Packet, to: LoopbackLink) {
        if model.lossProbability > 0, random() < model.lossProbability { return }
        var due = nowMilliseconds + model.baseDelayMilliseconds + random() * model.jitterMilliseconds
        if model.connectionIntervalMilliseconds > 0 {
            let ci = model.connectionIntervalMilliseconds
            due = (due / ci).rounded(.up) * ci
        }
        queue.append((due, to, packet))
    }

    /// Delivers every packet due at or before `milliseconds`, in due order.
    public func advance(to milliseconds: Double) {
        nowMilliseconds = max(nowMilliseconds, milliseconds)
        let ready = queue.filter { $0.due <= nowMilliseconds }.sorted { $0.due < $1.due }
        queue.removeAll { $0.due <= nowMilliseconds }
        for item in ready { item.to.emit(.received(item.packet)) }
    }

    public var pendingCount: Int { queue.count }
}

public final class LoopbackLink: Link, @unchecked Sendable {
    public let kind: LinkKind
    public let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let lock = NSLock()
    private weak var pair: LoopbackLinkPair?
    private weak var peer: LoopbackLink?
    private var isOpen = true
    public private(set) var sentCount = 0

    init(kind: LinkKind) {
        self.kind = kind
        let (stream, cont) = AsyncStream<LinkEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = cont
    }

    func installPair(_ pair: LoopbackLinkPair, peer: LoopbackLink) {
        lock.lock(); defer { lock.unlock() }
        self.pair = pair
        self.peer = peer
    }

    func emit(_ event: LinkEvent) {
        lock.lock(); defer { lock.unlock() }
        guard isOpen else { return }
        continuation.yield(event)
    }

    public func send(_ packet: Packet) async throws {
        let (pair, peer, open): (LoopbackLinkPair?, LoopbackLink?, Bool) = { lock.lock(); defer { lock.unlock() }; sentCount += 1; return (self.pair, self.peer, isOpen) }()
        guard open, let pair, let peer else { throw LinkError.notReady }
        await pair.enqueue(packet, to: peer)
    }

    public func close() async {
        let peer: LoopbackLink? = { lock.lock(); defer { lock.unlock() }; guard isOpen else { return nil }; isOpen = false; return self.peer }()
        guard let peer else { return }
        continuation.yield(.closed(.local))
        continuation.finish()
        peer.remoteClosed()
    }

    private func remoteClosed() {
        lock.lock(); defer { lock.unlock() }
        guard isOpen else { return }
        isOpen = false
        continuation.yield(.closed(.remote))
        continuation.finish()
    }
}
