import Foundation
import SottoCore
import SottoAudio
import SottoTransport

/// The real-time path. Capture frames arrive on the audio tap queue, are encoded and sent;
/// received packets go into the jitter buffer; a 20 ms playout timer pulls frames, decodes and
/// pushes PCM into the engine's output ring.
final class ConversationPipeline: @unchecked Sendable {
    enum Event: Sendable {
        case partnerTalking(Bool)
        case localLevel(Double)
        case quality(LinkQuality)
        case jitter(JitterBuffer.Statistics)
        case route(String)
        case linkClosed
        case partnerBye
        case error(String)
    }

    var onEvent: (@Sendable (Event) -> Void)?

    private let sendLink: any Link
    private let receiveLink: any Link
    private let codec: CodecConfiguration
    private let hello: ControlMessage.Hello
    private let engine: AudioEngineController
    private let lock = NSLock()
    private var encoder: any VoiceEncoder
    private var decoder: any VoiceDecoder
    private var jitter = JitterBuffer()
    private var meter = LevelMeter()
    private var sequence: UInt16 = 0
    private var timestamp: UInt32 = 0
    private var muted = false
    private var lastTalking = false
    private var receiveTask: Task<Void, Never>?
    private var playoutTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var latency = LatencyEstimator()

    init(sendLink: any Link, receiveLink: any Link, codec: CodecConfiguration, hello: ControlMessage.Hello) {
        self.sendLink = sendLink
        self.receiveLink = receiveLink
        self.codec = codec
        self.hello = hello
        var config = AudioEngineController.Configuration()
        config.sampleRate = Double(codec.sampleRate)
        config.frameDurationMilliseconds = codec.frameDurationMilliseconds
        self.engine = AudioEngineController(configuration: config)
        self.encoder = (try? CodecFactory.makeEncoder(codec)) ?? PCM16Encoder(configuration: codec)
        self.decoder = (try? CodecFactory.makeDecoder(codec)) ?? PCM16Decoder(configuration: codec)
    }

    func start() throws {
        #if os(iOS)
        try AudioSessionConfigurator.configureForConversation(preferredSampleRate: Double(codec.sampleRate))
        try AudioSessionConfigurator.activate()
        onEvent?(.route(AudioSessionConfigurator.currentRouteSummary))
        #endif
        engine.onCaptureFrame = { [weak self] frame in self?.captured(frame) }
        try engine.start()

        receiveTask = Task { [weak self] in await self?.receiveLoop() }
        playoutTask = Task(priority: .userInitiated) { [weak self] in await self?.playoutLoop() }
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.onEvent?(.jitter(self.lock.withLock { self.jitter.statistics }))
            }
        }
        pingTask = Task { [weak self] in
            var id: UInt32 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                id &+= 1
                await self?.sendControl(.ping(id: id, sentAt: MonotonicClock.now()))
            }
        }
        Task { await sendControl(.hello(hello)); await sendControl(.codec(codec.descriptor)) }
    }

    func stop() {
        receiveTask?.cancel(); playoutTask?.cancel(); statsTask?.cancel(); pingTask?.cancel()
        Task { [sendLink] in await sendLink.close() }
        engine.stop()
        #if os(iOS)
        AudioSessionConfigurator.deactivate()
        #endif
    }

    func setMuted(_ m: Bool) {
        lock.withLock { muted = m }
        Task { await sendControl(.mute(m)) }
    }

    private func captured(_ frame: PCMFrame) {
        let (talking, level, muted): (Bool, Double, Bool) = lock.withLock {
            let t = meter.process(frame)
            return (t, meter.lastLevelDBFS, self.muted)
        }
        onEvent?(.localLevel(level))
        if talking != lastTalking {
            lastTalking = talking
            Task { await sendControl(.talking(talking)) }
        }
        guard !muted else { return }
        let packet: Packet? = lock.withLock {
            guard let bytes = try? encoder.encode(frame) else { return nil }
            let p = Packet(kind: .audio, flags: codec.inbandFEC ? [.fecPresent] : [], sequence: sequence, timestamp: timestamp, payload: bytes)
            sequence &+= 1
            timestamp &+= UInt32(frame.count)
            return p
        }
        guard let packet else { return }
        Task { [sendLink] in try? await sendLink.send(packet) }
    }

    private func sendControl(_ message: ControlMessage) async {
        guard let bytes = try? message.encoded() else { return }
        let packet: Packet = lock.withLock {
            let p = Packet(kind: .control, sequence: sequence, timestamp: timestamp, payload: bytes)
            sequence &+= 1
            return p
        }
        try? await sendLink.send(packet)
    }

    private func receiveLoop() async {
        for await event in receiveLink.events {
            switch event {
            case .ready: break
            case .received(let packet):
                switch packet.header.kind {
                case .audio:
                    lock.withLock { jitter.push(packet, arrivedAt: MonotonicClock.now()) }
                case .control:
                    await handleControl(packet)
                }
            case .qualityChanged(let q): onEvent?(.quality(q))
            case .closed: onEvent?(.linkClosed); return
            }
        }
    }

    private func handleControl(_ packet: Packet) async {
        guard let message = try? ControlMessage.decode(packet.payload) else { return }
        switch message {
        case .talking(let t): onEvent?(.partnerTalking(t))
        case .ping(let id, let sentAt):
            let now = MonotonicClock.now()
            await sendControl(.pong(id: id, sentAt: sentAt, receivedAt: now, repliedAt: MonotonicClock.now()))
        case .pong(let id, let sentAt, let receivedAt, let repliedAt):
            if let sample = LatencySample(id: id, sentAt: sentAt, receivedAt: receivedAt, repliedAt: repliedAt, pongArrivedAt: MonotonicClock.now()) {
                let rtt: Double? = lock.withLock { latency.add(sample); return latency.bestRoundTripMilliseconds }
                onEvent?(.quality(LinkQuality(estimatedLatencyMilliseconds: rtt.map { $0 / 2 })))
            }
        case .bye: onEvent?(.partnerBye)
        case .hello, .mute, .battery, .codec: break
        }
    }

    /// Pulls one frame every 20 ms of *audio clock* (tracked by the ring's fill level, not wall time).
    private func playoutLoop() async {
        let frameSamples = codec.samplesPerFrame
        let targetFill = frameSamples * 2
        while !Task.isCancelled {
            if engine.outputRing.availableSamples < targetFill {
                let output: JitterBuffer.Output = lock.withLock { jitter.pop() }
                let pcm: PCMFrame? = lock.withLock {
                    switch output {
                    case .frame(let payload, _, _): return try? decoder.decode(payload, fec: false)
                    case .conceal(let fec):
                        if let fec, codec.inbandFEC, let recovered = try? decoder.decode(fec, fec: true) { return recovered }
                        return try? decoder.decode(nil, fec: false)
                    case .prefill: return nil
                    }
                }
                engine.outputRing.write(pcm ?? PCMFrame(repeating: 0, count: frameSamples))
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
