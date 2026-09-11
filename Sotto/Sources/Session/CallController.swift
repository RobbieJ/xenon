import Foundation
import SottoCore
#if canImport(LiveCommunicationKit)
// ConversationManager and ConversationAction are not Sendable in the iOS 26.5 SDK; the framework
// is used only from the main actor here, so its Sendable diagnostics are downgraded.
@preconcurrency import LiveCommunicationKit
import AVFAudio

/// Presents the conversation to the system as a call through LiveCommunicationKit (ADR-0005):
/// lock-screen and Dynamic Island UI, Recents, AirPods stem-press, and a system-activated audio
/// session. Signatures follow the iOS 26.5 SDK interface printed by CI.
///
/// Audio ordering: configure the AVAudioSession category before performing the start or join
/// action; start the engine only when `didActivate` arrives; stop it on `didDeactivate`.
@MainActor
final class CallController: NSObject, ConversationManagerDelegate {
    var onAudioSessionActivated: (() -> Void)?
    var onAudioSessionDeactivated: (() -> Void)?
    /// The user ended the call from the system UI or an AirPods stem press.
    var onEndRequested: (() -> Void)?
    var onMuteRequested: ((Bool) -> Void)?
    var onIncomingAnswered: (() -> Void)?

    private let manager: ConversationManager
    private(set) var conversationUUID: UUID?
    private var conversation: Conversation?

    override init() {
        manager = ConversationManager(configuration: .init(
            ringtoneName: nil,
            iconTemplateImageData: nil,
            maximumConversationGroups: 1,
            maximumConversationsPerConversationGroup: 1,
            includesConversationInRecents: true,
            supportsVideo: false,
            supportedHandleTypes: [.generic]
        ))
        super.init()
        manager.delegate = self
    }

    private func handle(for partner: Partner) -> Handle {
        Handle(type: .generic, value: partner.id, displayName: partner.displayName)
    }

    /// We initiated: show the outgoing call UI. On a reconnect the existing conversation is kept
    /// and the audio session is already active, so the activation callback is replayed.
    func startOutgoing(to partner: Partner) async throws {
        if conversationUUID != nil {
            onAudioSessionActivated?()
            return
        }
        let uuid = UUID()
        conversationUUID = uuid
        try await manager.perform([StartConversationAction(conversationUUID: uuid, handles: [handle(for: partner)], isVideo: false)])
    }

    /// The partner's invite arrived over the link: show the incoming call UI. The user answers in
    /// the system UI, which comes back as a JoinConversationAction.
    func reportIncoming(from partner: Partner) async throws {
        let uuid = UUID()
        conversationUUID = uuid
        try await manager.reportNewIncomingConversation(uuid: uuid, update: .init(members: [handle(for: partner)]))
    }

    /// Media is flowing: mark the call connected so the timer starts on the lock screen.
    func reportConnected() {
        guard let conversation else { return }
        manager.reportConversationEvent(.conversationConnected(Date()), for: conversation)
    }

    func reportRemoteEnded() {
        guard let conversation else { return }
        manager.reportConversationEvent(.conversationEnded(Date(), .remoteEnded), for: conversation)
        conversationUUID = nil
    }

    func end() async {
        guard let uuid = conversationUUID else { return }
        try? await manager.perform([EndConversationAction(conversationUUID: uuid)])
        conversationUUID = nil
    }

    func setMuted(_ muted: Bool) async {
        guard let uuid = conversationUUID else { return }
        try? await manager.perform([MuteConversationAction(conversationUUID: uuid, isMuted: muted)])
    }

    // MARK: ConversationManagerDelegate

    nonisolated func conversationManager(_ manager: ConversationManager, conversationChanged conversation: Conversation) {
        Task { @MainActor in self.conversation = conversation }
    }

    nonisolated func conversationManagerDidBegin(_ manager: ConversationManager) {}

    nonisolated func conversationManagerDidReset(_ manager: ConversationManager) {
        Task { @MainActor in
            self.conversation = nil
            self.conversationUUID = nil
        }
    }

    nonisolated func conversationManager(_ manager: ConversationManager, perform action: ConversationAction) {
        // Fulfil synchronously on the delegate's context (the action is not Sendable), then notify
        // the main actor with plain values only.
        switch action {
        case let start as StartConversationAction:
            start.fulfill(dateStarted: Date())
        case let join as JoinConversationAction:
            join.fulfill(dateConnected: Date())
            Task { @MainActor in self.onIncomingAnswered?() }
        case let end as EndConversationAction:
            end.fulfill(dateEnded: Date())
            Task { @MainActor in self.onEndRequested?() }
        case let mute as MuteConversationAction:
            let muted = mute.isMuted
            mute.fulfill()
            Task { @MainActor in self.onMuteRequested?(muted) }
        default:
            action.fulfill()
        }
    }

    nonisolated func conversationManager(_ manager: ConversationManager, timedOutPerforming action: ConversationAction) {
        action.fail()
    }

    nonisolated func conversationManager(_ manager: ConversationManager, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in onAudioSessionActivated?() }
    }

    nonisolated func conversationManager(_ manager: ConversationManager, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in onAudioSessionDeactivated?() }
    }
}
#endif
