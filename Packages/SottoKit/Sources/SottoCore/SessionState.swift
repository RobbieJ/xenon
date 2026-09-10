import Foundation

/// A remembered conversation partner.
public struct Partner: Sendable, Equatable, Codable, Identifiable, Hashable {
    public var id: String
    public var displayName: String
    public var lastSeen: Date?
    public init(id: String, displayName: String, lastSeen: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.lastSeen = lastSeen
    }
}

public enum LinkKind: String, Sendable, Codable, Equatable {
    case wifiAware
    case bleL2CAP
    case loopback
}

public enum SessionEndReason: Sendable, Equatable {
    case userEnded
    case partnerEnded
    case linkLost
    case audioUnavailable
    case failed(String)
}

/// The observable state of one conversation. Pure data; the reducer below is the only way it changes.
public enum SessionState: Sendable, Equatable {
    case idle
    /// Browsing for remembered partners and publishing for new ones.
    case discovering
    /// System pairing UI is up, or the hello exchange is in flight.
    case pairing(role: LinkRole?)
    case connecting(Partner, over: LinkKind)
    case connected(Partner, over: LinkKind)
    case reconnecting(Partner, attempt: Int)
    case ended(SessionEndReason)

    public var partner: Partner? {
        switch self {
        case .connecting(let p, _), .connected(let p, _), .reconnecting(let p, _): return p
        default: return nil
        }
    }

    public var isLive: Bool {
        if case .connected = self { return true }
        return false
    }
}

public enum SessionEvent: Sendable, Equatable {
    case start
    case pairRequested
    case roleResolved(LinkRole)
    case linkEstablished(Partner, LinkKind)
    case helloCompleted
    case linkDropped
    case reconnectAttempt(Int)
    case reconnectGaveUp
    case partnerSaidBye
    case audioLost
    case userEnded
    case failure(String)
    case reset
}

public enum SessionReducer {
    public static let maximumReconnectAttempts = 5

    /// Returns the next state, or nil if the event is not valid in the current state (callers log and ignore).
    public static func reduce(_ state: SessionState, _ event: SessionEvent) -> SessionState? {
        switch (state, event) {
        case (_, .reset): return .idle
        case (_, .failure(let why)): return .ended(.failed(why))
        case (.idle, .start): return .discovering
        case (.discovering, .pairRequested): return .pairing(role: nil)
        case (.pairing, .roleResolved(let role)): return .pairing(role: role)
        case (.discovering, .linkEstablished(let p, let k)), (.pairing, .linkEstablished(let p, let k)):
            return .connecting(p, over: k)
        case (.connecting(let p, let k), .helloCompleted): return .connected(p, over: k)
        case (.connected(let p, _), .linkDropped), (.connecting(let p, _), .linkDropped):
            return .reconnecting(p, attempt: 1)
        case (.reconnecting(let p, _), .reconnectAttempt(let n)):
            return n > maximumReconnectAttempts ? .ended(.linkLost) : .reconnecting(p, attempt: n)
        case (.reconnecting(let p, _), .linkEstablished(_, let k)): return .connecting(p, over: k)
        case (.reconnecting, .reconnectGaveUp): return .ended(.linkLost)
        case (.connected, .partnerSaidBye), (.connecting, .partnerSaidBye): return .ended(.partnerEnded)
        case (.connected, .audioLost): return .ended(.audioUnavailable)
        case (.idle, .userEnded): return nil
        case (_, .userEnded): return .ended(.userEnded)
        default: return nil
        }
    }
}
