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

/// Wires the pieces together for one conversation: audio engine → codec → link → jitter buffer →
/// audio engine, plus the control channel, the session state machine and the system call UI.
///
/// Link establishment always goes through `adopt(link:kind:initiatedLocally:)`, which runs the
/// hello handshake first. That gives the partner's identity before media starts, lets two links
/// that formed at once be reduced to the same one on both phones, and keeps unknown partners out
/// of the remembered list until the user says so.
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
    /// A phone we have never talked to connected over Bluetooth; the user keeps it or ends.
    private(set) var unknownPartnerName: String?
    private var pendingUnknownPartner: Partner?
    let displayName: String
    let deviceIdentifier: String

    private var pipeline: ConversationPipeline?
    private var loopbackPair: LoopbackLinkPair?
    private var linkTask: Task<Void, Never>?
    private var lastTransport: LinkKind?
    private var handshakeTasks: [Task<Void, Never>] = []
    #if canImport(CoreBluetooth)
    private var blePeripheral: BLEPeripheralHost?
    private var bleCentral: BLECentralClient?
    #endif
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

    // MARK: - Partners

    func remember(_ partner: Partner) {
        partners.removeAll { $0.id == partner.id }
        partners.insert(partner, at: 0)
        persistPartners()
    }

    func forget(_ partner: Partner) {
        partners.removeAll { $0.id == partner.id }
        persistPartners()
    }

    private func persistPartners() {
        if let data = try? JSONEncoder().encode(partners) { UserDefaults.standard.set(data, forKey: "partners") }
    }

    /// The user chose to keep talking to a phone that was not remembered.
    func acceptUnknownPartner() {
        if let p = pendingUnknownPartner { remember(p) }
        pendingUnknownPartner = nil
        unknownPartnerName = nil
    }

    func rejectUnknownPartner() {
        pendingUnknownPartner = nil
        unknownPartnerName = nil
        end()
    }

    // MARK: - Loopback self-test (phase 1)

    /// Capture from the AirPods, send through an impaired in-process link, play back.
    func startLoopback(model: ImpairmentModel = .ideal) {
        apply(.start)
        let pair = LoopbackLinkPair(model: model)
        loopbackPair = pair
        Task {
            // Keep the virtual clock moving so impairments deliver in real time.
            while loopbackPair != nil {
                await pair.advance(to: Double(MonotonicClock.now()) / 1_000_000)
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        lastTransport = .loopback
        let me = Partner(id: deviceIdentifier, displayName: "Loopback")
        apply(.linkEstablished(me, .loopback))
        startMedia(sendLink: pair.a, receiveLink: pair.b, partner: me, codec: .bleL2CAP)
    }

    // MARK: - Wi-Fi Aware

    #if canImport(WiFiAware)
    var isWiFiAwareSupported: Bool { WiFiAwareService.isSupported }

    /// "Show a code": publish and wait for the newly paired phone to connect.
    func pairAsHost() {
        apply(.start)
        apply(.pairRequested)
        apply(.roleResolved(.publisher))
        pairingSheet = .host
        lastTransport = .wifiAware
        linkTask?.cancel()
        linkTask = Task { [weak self] in
            do {
                for try await link in try WiFiAwareService.listen() {
                    await MainActor.run {
                        self?.pairingSheet = nil
                        self?.adopt(link: link, kind: .wifiAware, initiatedLocally: false)
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
        lastTransport = .wifiAware
    }

    func guestPicked(_ endpoint: NWEndpoint) {
        pairingSheet = nil
        do {
            adopt(link: try WiFiAwareService.connect(to: endpoint), kind: .wifiAware, initiatedLocally: true)
        } catch {
            fail(error)
        }
    }

    /// Repeat use: listen and browse at the same time. Each link that forms goes through the
    /// handshake; `LinkHandshake.shouldKeep` makes both phones settle on the same one.
    func talk() {
        apply(.start)
        startWiFiAwareTalk()
    }

    private func startWiFiAwareTalk() {
        lastTransport = .wifiAware
        linkTask?.cancel()
        linkTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        for try await link in try WiFiAwareService.listen() {
                            await MainActor.run { self?.adopt(link: link, kind: .wifiAware, initiatedLocally: false) }
                        }
                    } catch {}
                }
                group.addTask {
                    if let link = try? await WiFiAwareService.connectToFirstPairedDevice() {
                        await MainActor.run { self?.adopt(link: link, kind: .wifiAware, initiatedLocally: true) }
                    }
                }
                await group.waitForAll()
            }
        }
    }
    #endif

    // MARK: - Bluetooth only

    #if canImport(CoreBluetooth)
    /// Bluetooth-only path (ADR-0002 fallback): both phones advertise and scan at once.
    /// `BLERolePolicy` makes exactly one channel form between a pair; the handshake then
    /// identifies the peer. The channel is published with encryption, so iOS shows its own
    /// pairing confirmation on both phones the first time.
    func talkOverBluetooth() {
        apply(.start)
        apply(.pairRequested)
        startBluetoothRoles()
    }

    private func startBluetoothRoles() {
        stopBluetooth()
        lastTransport = .bleL2CAP
        blePeripheral = BLEPeripheralHost(identity: deviceIdentifier, onLink: { [weak self] link in
            Task { @MainActor in self?.bluetoothLinkOpened(link, asCentral: false) }
        }, onError: { [weak self] message in
            Task { @MainActor in self?.bluetoothFailed(message) }
        })
        bleCentral = BLECentralClient(localIdentity: deviceIdentifier, onLink: { [weak self] link, _ in
            Task { @MainActor in self?.bluetoothLinkOpened(link, asCentral: true) }
        }, onError: { [weak self] message in
            Task { @MainActor in self?.bluetoothFailed(message) }
        })
    }

    private func bluetoothFailed(_ message: String) {
        lastError = message
        // Radio-level failures end the attempt; transient ones keep scanning.
        if message.hasPrefix("Bluetooth is") || message.hasPrefix("Sotto does not") || message.hasPrefix("This iPhone") {
            stopBluetooth()
            apply(.failure(message))
        }
    }

    private func bluetoothLinkOpened(_ link: BLEL2CAPLink, asCentral: Bool) {
        // Stop discovery on both roles without disturbing the connection that carries the channel.
        if asCentral { blePeripheral?.stop(); bleCentral?.stopScanning() } else { bleCentral?.stop(); blePeripheral?.stopAdvertising() }
        adopt(link: link, kind: .bleL2CAP, initiatedLocally: asCentral)
    }

    private func stopBluetooth() {
        bleCentral?.stop(); bleCentral = nil
        blePeripheral?.stop(); blePeripheral = nil
    }
    #else
    private func stopBluetooth() {}
    #endif

    // MARK: - Link adoption

    /// Handshake, duplicate resolution, partner bookkeeping, then media.
    private func adopt(link: any Link, kind: LinkKind, initiatedLocally: Bool) {
        let local = ControlMessage.Hello(displayName: displayName, nonce: PairingRace.makeNonce(), deviceIdentifier: deviceIdentifier)
        let task = Task { [weak self] in
            let result: LinkHandshake.Result
            do {
                result = try await LinkHandshake.perform(on: link, local: local)
            } catch {
                await link.close()
                await MainActor.run { self?.lastError = "Handshake failed: \(error)" }
                return
            }
            await MainActor.run { self?.handshakeCompleted(link: link, kind: kind, initiatedLocally: initiatedLocally, remote: result.remote) }
        }
        handshakeTasks.append(task)
    }

    private func handshakeCompleted(link: any Link, kind: LinkKind, initiatedLocally: Bool, remote: ControlMessage.Hello) {
        // Two links formed at once: keep the one both phones agree on.
        if pipeline != nil || !LinkHandshake.shouldKeep(localIdentifier: deviceIdentifier, remoteIdentifier: remote.deviceIdentifier, initiatedLocally: initiatedLocally) {
            if pipeline == nil, kind == .bleL2CAP {
                // Under BLERolePolicy only one channel forms, so keep it even if the rule disagrees.
            } else {
                Task { await link.close() }
                return
            }
        }
        // The reducer decides whether a link is welcome in this state (not after give-up or end).
        guard SessionReducer.reduce(state, .linkEstablished(Partner(id: remote.deviceIdentifier, displayName: remote.displayName), kind)) != nil else {
            Task { await link.close() }
            return
        }
        linkTask?.cancel()
        linkTask = nil
        let partner = Partner(id: remote.deviceIdentifier, displayName: remote.displayName, lastSeen: Date())
        let known = partners.contains { $0.id == partner.id }
        if known || kind == .wifiAware {
            remember(partner)      // system pairing already implied trust
        } else if partners.isEmpty {
            remember(partner)      // first ever partner: the iOS pairing prompt was the consent
        } else {
            pendingUnknownPartner = partner
            unknownPartnerName = partner.displayName
        }
        lastTransport = kind
        apply(.linkEstablished(partner, kind))
        startMedia(sendLink: link, receiveLink: link, partner: partner, codec: kind == .bleL2CAP ? .bleL2CAP : .wifiAware)
    }

    // MARK: - Media and the system call

    private func startMedia(sendLink: any Link, receiveLink: any Link, partner: Partner, codec: CodecConfiguration) {
        pipeline?.stop()
        do {
            let pipeline = try ConversationPipeline(sendLink: sendLink, receiveLink: receiveLink, codec: codec, hello: .init(displayName: displayName, nonce: PairingRace.makeNonce(), deviceIdentifier: deviceIdentifier))
            pipeline.onEvent = { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            self.pipeline = pipeline
            #if canImport(LiveCommunicationKit)
            // Configure the session category first, then let the system activate it (ADR-0005).
            try pipeline.configureAudioSession()
            call.onAudioSessionActivated = { [weak self] in
                guard let self, let pipeline = self.pipeline else { return }
                do {
                    try pipeline.start(activateSession: false)
                    self.call.reportConnected()
                    self.apply(.helloCompleted)
                } catch {
                    self.fail(error)
                }
            }
            call.onAudioSessionDeactivated = { [weak self] in self?.pipeline?.stop() }
            Task {
                do {
                    try await call.startOutgoing(to: partner)
                } catch {
                    // LiveCommunicationKit unavailable (e.g. region): fall back to a plain audio session.
                    lastError = "Call UI unavailable: \(error.localizedDescription)"
                    do { try pipeline.start(activateSession: true); apply(.helloCompleted) } catch { fail(error) }
                }
            }
            #else
            try pipeline.start(activateSession: true)
            apply(.helloCompleted)
            #endif
        } catch {
            fail(error)
        }
    }

    private func handle(_ event: ConversationPipeline.Event) {
        switch event {
        case .partnerHello:
            break   // identity was settled by the handshake
        case .partnerTalking(let t): partnerIsTalking = t
        case .localLevel(let l): localLevelDBFS = l
        case .quality(let q): linkQuality = q
        case .jitter(let s): jitterStatistics = s
        case .route(let r): routeSummary = r
        case .audioLost:
            pipeline?.stop()
            pipeline = nil
            #if canImport(LiveCommunicationKit)
            Task { await call.end() }
            #endif
            apply(.audioLost)
        case .linkClosed: linkDidClose()
        case .partnerBye:
            pipeline?.stop()
            pipeline = nil
            #if canImport(LiveCommunicationKit)
            call.reportRemoteEnded()
            #endif
            apply(.partnerSaidBye)
        case .error(let e): lastError = e
        }
    }

    // MARK: - Drops and reconnects

    private func linkDidClose() {
        pipeline?.stop()
        pipeline = nil
        stopBluetooth()
        apply(.linkDropped)
        scheduleReconnect(attempt: 1)
    }

    private func scheduleReconnect(attempt: Int) {
        guard case .reconnecting = state else { return }
        if attempt > SessionReducer.maximumReconnectAttempts {
            giveUp()
            return
        }
        apply(.reconnectAttempt(attempt))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, case .reconnecting = self.state else { return }
            switch self.lastTransport {
            #if canImport(CoreBluetooth)
            case .bleL2CAP: self.startBluetoothRoles()
            #endif
            #if canImport(WiFiAware)
            case .wifiAware: self.startWiFiAwareTalk()
            #endif
            default: self.giveUp(); return
            }
            try? await Task.sleep(for: .seconds(8))
            guard case .reconnecting = self.state else { return }
            self.scheduleReconnect(attempt: attempt + 1)
        }
    }

    private func giveUp() {
        stopTransports()
        apply(.reconnectGaveUp)
        #if canImport(LiveCommunicationKit)
        Task { await call.end() }
        #endif
    }

    private func stopTransports() {
        linkTask?.cancel(); linkTask = nil
        handshakeTasks.forEach { $0.cancel() }; handshakeTasks.removeAll()
        stopBluetooth()
        loopbackPair = nil
    }

    private func fail(_ error: any Error) {
        lastError = String(describing: error)
        stopTransports()
        apply(.failure(lastError ?? "failed"))
    }

    // MARK: - User actions

    func toggleMute() {
        isMuted.toggle()
        pipeline?.setMuted(isMuted)
        #if canImport(LiveCommunicationKit)
        Task { await call.setMuted(isMuted) }
        #endif
    }

    func cancelPairing() {
        pairingSheet = nil
        stopTransports()
        apply(.reset)
    }

    func end(fromSystem: Bool = false) {
        pipeline?.stop()
        pipeline = nil
        stopTransports()
        #if canImport(LiveCommunicationKit)
        if !fromSystem { Task { await call.end() } }
        #endif
        apply(.userEnded)
    }

    func reset() {
        apply(.reset)
        lastError = nil
        unknownPartnerName = nil
        pendingUnknownPartner = nil
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
