import Foundation
import SottoCore
import SottoAudio
import SottoTransport
import SottoSession
#if canImport(AVFAudio)
import AVFAudio
#endif

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
        /// The AirPods (or any input) went away and did not come back.
        case audioLost
        case linkClosed
        case partnerBye
        case error(String)
    }

    var onEvent: (@Sendable (Event) -> Void)?

    private let engine: AudioEngineController
    private let session: ConversationSession
    private let codec: CodecConfiguration
    private var playoutTask: Task<Void, Never>?
    private var observers: [Any] = []
    private var activatedSessionOurselves = false

    init(sendLink: any Link, receiveLink: any Link, codec: CodecConfiguration, hello: ControlMessage.Hello) throws {
        self.codec = codec
        var config = AudioEngineController.Configuration()
        config.sampleRate = Double(codec.sampleRate)
        config.frameDurationMilliseconds = codec.frameDurationMilliseconds
        self.engine = AudioEngineController(configuration: config)
        self.session = try ConversationSession(source: engine, link: sendLink, receiveLink: receiveLink, codec: codec, hello: hello)
    }

    /// Category and mode only. Call before reporting the call to the system so the session it
    /// activates is already a voice-chat session with the AirPods HFP route allowed.
    func configureAudioSession() throws {
        #if os(iOS)
        try AudioSessionConfigurator.configureForConversation(preferredSampleRate: Double(codec.sampleRate))
        #endif
    }

    /// - Parameter activateSession: true when no system call manages the session (loopback,
    ///   or LiveCommunicationKit unavailable); false when the system has just activated it.
    func start(activateSession: Bool) throws {
        #if os(iOS)
        if activateSession {
            try configureAudioSession()
            try AudioSessionConfigurator.activate()
            activatedSessionOurselves = true
        }
        onEvent?(.route(AudioSessionConfigurator.currentRouteSummary))
        observeRouteChanges()
        #endif
        session.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .partnerHello(let h): onEvent?(.partnerHello(displayName: h.displayName, deviceIdentifier: h.deviceIdentifier))
            case .partnerTalking(let t): onEvent?(.partnerTalking(t))
            case .localLevel(let l): onEvent?(.localLevel(l))
            case .quality(let q): onEvent?(.quality(q))
            case .jitter(let s): onEvent?(.jitter(s))
            case .linkClosed: onEvent?(.linkClosed)
            case .partnerBye: onEvent?(.partnerBye)
            case .error(let e): onEvent?(.error(e))
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
        playoutTask = nil
        session.stop()
        #if os(iOS)
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if activatedSessionOurselves { AudioSessionConfigurator.deactivate() }
        #endif
    }

    func setMuted(_ m: Bool) { session.setMuted(m) }

    /// Per-packet timestamps for the phase 0 per-hop analysis.
    var traceCSV: String { session.traceCSV }

    #if os(iOS)
    /// Ear detection, AirPods switching to a Mac, or any route change: rebuild the engine on the
    /// new route, and report audio lost if no input remains after a grace period.
    private func observeRouteChanges() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.routeChanged()
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] _ in
            self?.routeChanged()
        })
    }

    private func routeChanged() {
        onEvent?(.route(AudioSessionConfigurator.currentRouteSummary))
        let hasInput = !AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty
        if hasInput {
            engine.routeDidChange()
        } else {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                if AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty {
                    self.onEvent?(.audioLost)
                } else {
                    self.engine.routeDidChange()
                }
            }
        }
    }
    #endif
}
