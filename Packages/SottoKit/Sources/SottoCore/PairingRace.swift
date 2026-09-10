import Foundation

/// Which side of a freshly formed link drives the session.
public enum LinkRole: Sendable, Equatable {
    /// Shows the pairing view / listens; is the "callee" for the system call UI.
    case publisher
    /// Picks the partner / connects; is the "caller".
    case subscriber
}

/// Resolves the "both people tapped Pair at once" race deterministically.
/// Each side draws a random 64-bit nonce and sends it in `ControlMessage.hello`.
/// The lower nonce becomes the publisher and shows "Only one of you needs to tap".
public enum PairingRace {
    public static func role(localNonce: UInt64, remoteNonce: UInt64, localIdentifier: String, remoteIdentifier: String) -> LinkRole {
        if localNonce != remoteNonce {
            return localNonce < remoteNonce ? .publisher : .subscriber
        }
        // Astronomically unlikely, but keep the outcome deterministic and asymmetric.
        return localIdentifier < remoteIdentifier ? .publisher : .subscriber
    }

    public static func makeNonce() -> UInt64 {
        UInt64.random(in: UInt64.min...UInt64.max)
    }
}
