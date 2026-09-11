import Foundation
import SottoCore
import SottoAudio
import SottoTransport

/// Where captured frames come from. The app's AVAudioEngine controller conforms; tests inject a generator.
public protocol AudioSource: AnyObject, Sendable {
    /// Start delivering exactly `samplesPerFrame` samples per call, on any thread.
    func start(onFrame: @escaping @Sendable (PCMFrame) -> Void) throws
    func stop()
}

/// The real-time path between one audio device and one link, independent of Apple frameworks.
///
/// Capture side: frames arrive from the `AudioSource`, are metered for the talking indicator,
/// encoded and sent as one packet each. Receive side: audio packets go into the jitter buffer and
/// control packets are handled. Playout is pull-based: the audio output calls `nextPlayoutFrame()`
/// every 20 ms of its own clock, which keeps the two sides' clocks decoupled and makes the whole
/// thing testable with a virtual clock.
public final class ConversationSession: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case partnerHello(ControlMessage.Hello)
        case partnerTalking(Bool)
        case partnerMuted(Bool)
        case localLevel(Double)
        case quality(LinkQuality)
        case jitter(JitterBuffer.Statistics)
        case linkClosed(LinkCloseReason)
        case partnerBye
        case error(String)
    }

    public var onEvent: (@Sendable (Event) -> Void)?

    public let codec: CodecConfiguration
    private let source: any AudioSource
    private let sendLink: any Link
    private let receiveLink: any Link
    private let hello: ControlMessage.Hello
    private let lock = NSLock()
    private var encoder: any VoiceEncoder
    private var decoder: any VoiceDecoder
    private var jitter: JitterBuffer
    private var meter = LevelMeter()
    /// Audio and control packets use separate sequence spaces; the jitter buffer only sees audio,
    /// so a control packet must never leave a gap in the audio numbering.
    private var sequence: UInt16 = 0
    private var controlSequence: UInt16 = 0
    private var timestamp: UInt32 = 0
    private var muted = false
    private var lastTalking = false
    private var latency = LatencyEstimator()
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var started = false
    private var trace = TraceLog()

    public struct Options: Sendable {
        public var pingInterval: Duration = .seconds(2)
        public var jitter = JitterBuffer.Configuration()
        /// Monotonic nanoseconds used for arrival timestamps and pings. Tests inject a virtual clock.
        public var now: @Sendable () -> UInt64 = { MonotonicClock.now() }
        public init() {}
    }
    private let options: Options

    /// `receiveLink` defaults to `link`; tests pass the other end of a loopback pair.
    public init(source: any AudioSource, link: any Link, receiveLink: (any Link)? = nil, codec: CodecConfiguration, hello: ControlMessage.Hello, options: Options = Options()) throws {
        self.source = source
        self.sendLink = link
        self.receiveLink = receiveLink ?? link
        self.codec = codec
        self.hello = hello
        self.options = options
        self.encoder = try CodecFactory.makeEncoder(codec)
        self.decoder = try CodecFactory.makeDecoder(codec)
        var jc = options.jitter
        jc.frameDurationMilliseconds = codec.frameDurationMilliseconds
        self.jitter = JitterBuffer(configuration: jc)
    }

    public func start() throws {
        guard !started else { return }
        started = true
        try source.start { [weak self] frame in self?.captured(frame) }
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
        if options.pingInterval > .zero {
            pingTask = Task { [weak self] in
                var id: UInt32 = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: self?.options.pingInterval ?? .seconds(2))
                    id &+= 1
                    await self?.sendControl(.ping(id: id, sentAt: self?.options.now() ?? 0))
                }
            }
        }
        Task { await sendControl(.hello(hello)); await sendControl(.codec(codec.descriptor)) }
    }

    public func stop() {
        guard started else { return }
        started = false
        source.stop()
        receiveTask?.cancel(); pingTask?.cancel()
        Task { [sendLink] in
            let bye = try? ControlMessage.bye(reason: "userEnded").encoded()
            if let bye { try? await sendLink.send(Packet(kind: .control, sequence: 0, timestamp: 0, payload: bye)) }
            await sendLink.close()
        }
    }

    public var isMuted: Bool { lock.withLock { muted } }

    public func setMuted(_ m: Bool) {
        lock.withLock { muted = m }
        Task { await sendControl(.mute(m)) }
    }

    public var jitterStatistics: JitterBuffer.Statistics { lock.withLock { jitter.statistics } }
    /// Snapshot of the per-packet trace for export (see PacketTrace).
    public var traceCSV: String { lock.withLock { trace.csv() } }
    public var traces: [PacketTrace] { lock.withLock { trace.traces } }
    public var bestRoundTripMilliseconds: Double? { lock.withLock { latency.bestRoundTripMilliseconds } }

    /// Pull one frame for playback. Returns silence while prefilling.
    public func nextPlayoutFrame() -> PCMFrame {
        let output: JitterBuffer.Output = lock.withLock { jitter.pop() }
        let now = options.now()
        let pcm: PCMFrame? = lock.withLock {
            switch output {
            case .frame(let payload, let seq, _):
                trace.update(seq) { $0.playedAt = now }
                return try? decoder.decode(payload, fec: false)
            case .conceal(let fec):
                if let fec, codec.inbandFEC, let recovered = try? decoder.decode(fec, fec: true) { return recovered }
                return try? decoder.decode(nil, fec: false)
            case .prefill:
                return nil
            }
        }
        return pcm ?? PCMFrame(repeating: 0, count: codec.samplesPerFrame)
    }

    // MARK: - Capture side

    private func captured(_ frame: PCMFrame) {
        let capturedAt = options.now()
        let (talking, level, muted): (Bool, Double, Bool) = lock.withLock {
            let t = meter.process(frame)
            return (t, meter.lastLevelDBFS, self.muted)
        }
        onEvent?(.localLevel(level))
        if talking != lastTalking {
            lastTalking = talking
            Task { await sendControl(.talking(talking)) }
        }
        // Muted: advance the audio clock without sending, so the partner's jitter buffer sees a
        // gap it can skip over on unmute rather than a stale sequence it discards as late.
        guard !muted else {
            lock.withLock { sequence &+= 1; timestamp &+= UInt32(frame.count) }
            return
        }
        let packet: Packet? = lock.withLock {
            guard let bytes = try? encoder.encode(frame) else { return nil }
            let p = Packet(kind: .audio, flags: codec.inbandFEC ? [.fecPresent] : [], sequence: sequence, timestamp: timestamp, payload: bytes)
            trace.update(sequence) { $0.capturedAt = capturedAt; $0.encodedAt = options.now() }
            sequence &+= 1
            timestamp &+= UInt32(frame.count)
            return p
        }
        guard let packet else { return }
        Task { [sendLink, weak self] in
            try? await sendLink.send(packet)
            guard let self else { return }
            let t = self.options.now()
            self.lock.withLock { self.trace.update(packet.header.sequence) { $0.sentAt = t } }
        }
    }

    private func sendControl(_ message: ControlMessage) async {
        guard let bytes = try? message.encoded() else { return }
        let packet: Packet = lock.withLock {
            let p = Packet(kind: .control, sequence: controlSequence, timestamp: timestamp, payload: bytes)
            controlSequence &+= 1
            return p
        }
        try? await sendLink.send(packet)
    }

    // MARK: - Receive side

    private func receiveLoop() async {
        for await event in receiveLink.events {
            switch event {
            case .ready:
                break
            case .received(let packet):
                switch packet.header.kind {
                case .audio:
                    let t = options.now()
                    lock.withLock {
                        jitter.push(packet, arrivedAt: t)
                        trace.update(packet.header.sequence) { $0.receivedAt = t }
                    }
                case .control: await handleControl(packet)
                }
                if packet.header.sequence % 50 == 0 { onEvent?(.jitter(jitterStatistics)) }
            case .qualityChanged(let q):
                onEvent?(.quality(q))
            case .closed(let reason):
                onEvent?(.linkClosed(reason))
                return
            }
        }
    }

    private func handleControl(_ packet: Packet) async {
        guard let message = try? ControlMessage.decode(packet.payload) else { return }
        switch message {
        case .hello(let h): onEvent?(.partnerHello(h))
        case .talking(let t): onEvent?(.partnerTalking(t))
        case .mute(let m): onEvent?(.partnerMuted(m))
        case .ping(let id, let sentAt):
            let now = options.now()
            await sendControl(.pong(id: id, sentAt: sentAt, receivedAt: now, repliedAt: options.now()))
        case .pong(let id, let sentAt, let receivedAt, let repliedAt):
            if let sample = LatencySample(id: id, sentAt: sentAt, receivedAt: receivedAt, repliedAt: repliedAt, pongArrivedAt: options.now()) {
                let rtt: Double? = lock.withLock {
                    latency.add(sample)
                    trace.recordClockOffset(latency.medianClockOffsetNanoseconds)
                    return latency.bestRoundTripMilliseconds
                }
                onEvent?(.quality(LinkQuality(estimatedLatencyMilliseconds: rtt.map { $0 / 2 })))
            }
        case .bye: onEvent?(.partnerBye)
        case .battery, .codec: break
        }
    }
}
