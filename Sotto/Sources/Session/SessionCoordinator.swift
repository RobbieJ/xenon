import Foundation
import Observation
import SottoCore
import SottoAudio
import SottoTransport
import SottoSession

/// Wires the pieces together for one conversation: audio engine → codec → link → jitter buffer → audio engine,
/// plus the control channel and the session state machine. UI observes this object.
///
/// Phase 1 scope: the loopback link (talk to yourself with a chosen impairment model) so the whole pipeline
/// can be exercised on a single phone before the radios are wired in (phase 2).
@Observable
@MainActor
final class SessionCoordinator {
    private(set) var state: SessionState = .idle
    private(set) var isMuted = false
    private(set) var partnerIsTalking = false
    private(set) var localLevelDBFS: Double = -120
    private(set) var linkQuality = LinkQuality()
    private(set) var jitterStatistics = JitterBuffer.Statistics()
    private(set) var routeSummary = ""
    private(set) var lastError: String?
    let displayName: String
    let deviceIdentifier: String

    private var pipeline: ConversationPipeline?
    private var loopbackPair: LoopbackLinkPair?
    #if canImport(LiveCommunicationKit)
    private let call = CallController()
    #endif

    init() {
        displayName = ProcessInfo.processInfo.hostName
        deviceIdentifier = UUID().uuidString
        #if canImport(LiveCommunicationKit)
        call.onEndRequested = { [weak self] in self?.end(fromSystem: true) }
        call.onMuteRequested = { [weak self] muted in
            guard let self, self.isMuted != muted else { return }
            self.isMuted = muted
            self.pipeline?.setMuted(muted)
        }
        #endif
    }

    func apply(_ event: SessionEvent) {
        if let next = SessionReducer.reduce(state, event) {
            state = next
        }
    }

    /// Phase 1 self-test: capture from the AirPods, send through an impaired in-process link, play back.
    func startLoopback(model: ImpairmentModel = .ideal) {
        apply(.start)
        let pair = LoopbackLinkPair(model: model)
        loopbackPair = pair
        let me = Partner(id: deviceIdentifier, displayName: "Loopback")
        apply(.linkEstablished(me, .loopback))
        Task {
            // Keep the virtual clock moving so impairments deliver in real time.
            while loopbackPair != nil {
                await pair.advance(to: Double(MonotonicClock.now()) / 1_000_000)
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        start(link: pair.a, receiveLink: pair.b, partner: me, codec: .bleL2CAP)
    }

    private func start(link: any Link, receiveLink: (any Link)? = nil, partner: Partner, codec: CodecConfiguration) {
        do {
            let pipeline = try ConversationPipeline(sendLink: link, receiveLink: receiveLink ?? link, codec: codec, hello: .init(displayName: displayName, nonce: PairingRace.makeNonce(), deviceIdentifier: deviceIdentifier))
            pipeline.onEvent = { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            self.pipeline = pipeline
            #if canImport(LiveCommunicationKit)
            // Present as a system call; the engine starts when the system activates the audio session.
            call.onAudioSessionActivated = { [weak self] in
                guard let self, let pipeline = self.pipeline else { return }
                do {
                    try pipeline.start()
                    self.call.reportConnected()
                    self.apply(.helloCompleted)
                } catch {
                    self.lastError = String(describing: error)
                    self.apply(.failure(self.lastError ?? "start failed"))
                }
            }
            Task {
                do {
                    try await call.startOutgoing(to: partner)
                } catch {
                    // LiveCommunicationKit unavailable (e.g. region): fall back to a plain audio session.
                    lastError = "Call UI unavailable: \(error.localizedDescription)"
                    do { try pipeline.start(); apply(.helloCompleted) } catch { apply(.failure(String(describing: error))) }
                }
            }
            #else
            try pipeline.start()
            apply(.helloCompleted)
            #endif
        } catch {
            lastError = String(describing: error)
            apply(.failure(lastError ?? "start failed"))
        }
    }

    private func handle(_ event: ConversationPipeline.Event) {
        switch event {
        case .partnerTalking(let t): partnerIsTalking = t
        case .localLevel(let l): localLevelDBFS = l
        case .quality(let q): linkQuality = q
        case .jitter(let s): jitterStatistics = s
        case .route(let r): routeSummary = r
        case .linkClosed: apply(.linkDropped)
        case .partnerBye:
            #if canImport(LiveCommunicationKit)
            call.reportRemoteEnded()
            #endif
            apply(.partnerSaidBye)
        case .error(let e): lastError = e
        }
    }

    func toggleMute() {
        isMuted.toggle()
        pipeline?.setMuted(isMuted)
        #if canImport(LiveCommunicationKit)
        Task { await call.setMuted(isMuted) }
        #endif
    }

    func end(fromSystem: Bool = false) {
        pipeline?.stop()
        pipeline = nil
        loopbackPair = nil
        #if canImport(LiveCommunicationKit)
        if !fromSystem { Task { await call.end() } }
        #endif
        apply(.userEnded)
    }

    func reset() {
        apply(.reset)
        lastError = nil
    }

    /// Writes the current session's packet trace to a temporary CSV and returns its URL for sharing.
    func exportTrace() -> URL? {
        guard let pipeline else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-trace-\(stamp).csv")
        do {
            try pipeline.traceCSV.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            lastError = "Could not write trace: \(error.localizedDescription)"
            return nil
        }
    }
}
