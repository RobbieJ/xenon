import Foundation
import SottoCore
import SottoAudio
import SottoTransport
import SottoSession

/// Thin device-side wrapper: owns the AVAudioEngine controller, hands its capture frames to the
/// package's `ConversationSession`, and tops up the engine's output ring from the session's
/// pull-based playout. All the real-time logic lives in `SottoSession` so it is unit-tested.
final class ConversationPipeline: @unchecked Sendable {
    enum Event: Sendable {
        case partnerHello(displayName: String, deviceIdentifier: String)
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

    private let engine: AudioEngineController
    private let session: ConversationSession
    private let codec: CodecConfiguration
    private var playoutTask: Task<Void, Never>?

    init(sendLink: any Link, receiveLink: any Link, codec: CodecConfiguration, hello: ControlMessage.Hello) throws {
        self.codec = codec
        var config = AudioEngineController.Configuration()
        config.sampleRate = Double(codec.sampleRate)
        config.frameDurationMilliseconds = codec.frameDurationMilliseconds
        self.engine = AudioEngineController(configuration: config)
        self.session = try ConversationSession(source: engine, link: sendLink, receiveLink: receiveLink, codec: codec, hello: hello)
    }

    func start() throws {
        #if os(iOS)
        try AudioSessionConfigurator.configureForConversation(preferredSampleRate: Double(codec.sampleRate))
        try AudioSessionConfigurator.activate()
        onEvent?(.route(AudioSessionConfigurator.currentRouteSummary))
        #endif
        session.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .partnerTalking(let t): onEvent?(.partnerTalking(t))
            case .localLevel(let l): onEvent?(.localLevel(l))
            case .quality(let q): onEvent?(.quality(q))
            case .jitter(let s): onEvent?(.jitter(s))
            case .linkClosed: onEvent?(.linkClosed)
            case .partnerBye: onEvent?(.partnerBye)
            case .error(let e): onEvent?(.error(e))
            case .partnerHello(let h): onEvent?(.partnerHello(displayName: h.displayName, deviceIdentifier: h.deviceIdentifier))
            case .partnerMuted: break
            }
        }
        try session.start()
        let frameSamples = codec.samplesPerFrame
        let ring = engine.outputRing
        playoutTask = Task(priority: .userInitiated) { [session] in
            while !Task.isCancelled {
                // Keep two frames ahead of the render callback; pull only when the ring needs it.
                while ring.availableSamples < frameSamples * 2 {
                    ring.write(session.nextPlayoutFrame())
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    func stop() {
        playoutTask?.cancel()
        session.stop()
        #if os(iOS)
        AudioSessionConfigurator.deactivate()
        #endif
    }

    func setMuted(_ m: Bool) { session.setMuted(m) }

    /// Per-packet timestamps for the phase 0 per-hop analysis.
    var traceCSV: String { session.traceCSV }
}
