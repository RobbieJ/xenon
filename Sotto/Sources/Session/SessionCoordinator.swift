import Foundation
import Observation
import SottoCore
import SottoAudio
import SottoTransport
import SottoSession
#if canImport(WiFiAware)
import Network
import WiFiAware
#endif

/// Which system pairing sheet is up.
enum PairingSheet: String, Identifiable {
    case host, guest
    var id: String { rawValue }
}

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
    var lastError: String?
    /// Remembered partners, most recent first. Persisted in UserDefaults.
    private(set) var partners: [Partner] = []
    var pairingSheet: PairingSheet?
    let displayName: String
    let deviceIdentifier: String
    private var linkTask: Task<Void, Never>?
    #if canImport(CoreBluetooth)
    private var blePeripheral: BLEPeripheralHost?
    private var bleCentral: BLECentralClient?
    #endif

    private var pipeline: ConversationPipeline?
    private var loopbackPair: LoopbackLinkPair?
    #if canImport(LiveCommunicationKit)
    private let call = CallController()
    #endif

    init() {
        let defaults = UserDefaults.standard
        displayName = defaults.string(forKey: "displayName") ?? ProcessInfo.processInfo.hostName
        if let id = defaults.string(forKey: "deviceIdentifier") {
            deviceIdentifier = id
        } else {
            deviceIdentifier = UUID().uuidString
            defaults.set(deviceIdentifier, forKey: "deviceIdentifier")
        }
        if let data = defaults.data(forKey: "partners"), let saved = try? JSONDecoder().decode([Partner].self, from: data) {
            partners = saved
        }
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
        case .partnerHello(let name, let id):
            remember(Partner(id: id, displayName: name, lastSeen: Date()))
            if case .connected(_, let kind) = state { state = .connected(Partner(id: id, displayName: name, lastSeen: Date()), over: kind) }
            if case .connecting(_, let kind) = state { state = .connecting(Partner(id: id, displayName: name, lastSeen: Date()), over: kind) }
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

    func remember(_ partner: Partner) {
        partners.removeAll { $0.id == partner.id }
        partners.insert(partner, at: 0)
        if let data = try? JSONEncoder().encode(partners) { UserDefaults.standard.set(data, forKey: "partners") }
    }

    func forget(_ partner: Partner) {
        partners.removeAll { $0.id == partner.id }
        if let data = try? JSONEncoder().encode(partners) { UserDefaults.standard.set(data, forKey: "partners") }
    }

    #if canImport(WiFiAware)
    var isWiFiAwareSupported: Bool { WiFiAwareService.isSupported }

    /// "Show a code": publish and wait for the newly paired phone to connect.
    func pairAsHost() {
        apply(.start)
        apply(.pairRequested)
        apply(.roleResolved(.publisher))
        pairingSheet = .host
        linkTask?.cancel()
        linkTask = Task { [weak self] in
            do {
                for try await link in try WiFiAwareService.listen() {
                    await MainActor.run {
                        self?.pairingSheet = nil
                        self?.begin(link: link, kind: .wifiAware)
                    }
                    return
                }
            } catch {
                await MainActor.run { self?.fail(error) }
            }
        }
    }

    /// "Enter a code": the system picker returns the host's endpoint once the PIN is confirmed.
    func pairAsGuest() {
        apply(.start)
        apply(.pairRequested)
        apply(.roleResolved(.subscriber))
        pairingSheet = .guest
    }

    func guestPicked(_ endpoint: NWEndpoint) {
        pairingSheet = nil
        do {
            begin(link: try WiFiAwareService.connect(to: endpoint), kind: .wifiAware)
        } catch {
            fail(error)
        }
    }

    /// Repeat use: listen and browse at the same time; the first link to form wins.
    /// If both phones tap Talk at once each may briefly hold two links; the later one is closed.
    func talk() {
        apply(.start)
        linkTask?.cancel()
        linkTask = Task { [weak self] in
            await withTaskGroup(of: (any Link)?.self) { group in
                group.addTask {
                    do {
                        for try await link in try WiFiAwareService.listen() { return link }
                    } catch {}
                    return nil
                }
                group.addTask {
                    try? await WiFiAwareService.connectToFirstPairedDevice()
                }
                for await candidate in group {
                    if let link = candidate {
                        group.cancelAll()
                        await MainActor.run { self?.begin(link: link, kind: .wifiAware) }
                        return
                    }
                }
                await MainActor.run { self?.fail(LinkError.unsupported("No partner in range")) }
            }
        }
    }

    func cancelPairing() {
        pairingSheet = nil
        linkTask?.cancel()
        linkTask = nil
        stopBluetooth()
        apply(.reset)
    }

    private func begin(link: any Link, kind: LinkKind) {
        let placeholder = partners.first ?? Partner(id: "pending", displayName: "Partner")
        apply(.linkEstablished(placeholder, kind))
        start(link: link, partner: placeholder, codec: kind == .bleL2CAP ? .bleL2CAP : .wifiAware)
    }

    private func fail(_ error: any Error) {
        lastError = String(describing: error)
        apply(.failure(lastError ?? "failed"))
    }
    #endif

    #if canImport(CoreBluetooth)
    /// Bluetooth-only path (ADR-0002 fallback): both phones advertise and scan at once; the first
    /// L2CAP channel to open wins and the other role is torn down. The channel is published with
    /// encryption, so iOS shows its own Bluetooth pairing confirmation on both phones the first time.
    func talkOverBluetooth() {
        apply(.start)
        apply(.pairRequested)
        stopBluetooth()
        blePeripheral = BLEPeripheralHost(identity: deviceIdentifier, onLink: { [weak self] link in
            Task { @MainActor in self?.bluetoothLinkOpened(link) }
        }, onError: { [weak self] message in
            Task { @MainActor in self?.lastError = message }
        })
        bleCentral = BLECentralClient(onLink: { [weak self] link, _ in
            Task { @MainActor in self?.bluetoothLinkOpened(link) }
        }, onError: { [weak self] message in
            Task { @MainActor in self?.lastError = message }
        })
    }

    private func bluetoothLinkOpened(_ link: BLEL2CAPLink) {
        guard state.partner == nil else {
            Task { await link.close() }   // a second channel raced in; keep the first
            return
        }
        // Keep the role that produced the link; stop the other to free the radio.
        bleCentral?.stop()
        blePeripheral?.stop()
        begin(link: link, kind: .bleL2CAP)
    }

    private func stopBluetooth() {
        bleCentral?.stop(); bleCentral = nil
        blePeripheral?.stop(); blePeripheral = nil
    }
    #else
    private func stopBluetooth() {}
    #endif

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
        linkTask?.cancel()
        linkTask = nil
        stopBluetooth()
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
