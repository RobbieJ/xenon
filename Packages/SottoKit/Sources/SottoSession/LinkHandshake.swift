import Foundation
import SottoCore
import SottoTransport

/// Exchanges hello messages on a freshly opened link before any media starts, so the caller
/// knows who is on the other end and can resolve duplicate links deterministically.
///
/// The link's event stream is consumed only up to the remote hello; `ConversationSession` then
/// continues iterating the same stream. Audio packets that arrive early are dropped here, which
/// costs at most a few frames.
public enum LinkHandshake {
    public struct Result: Sendable, Equatable {
        public let remote: ControlMessage.Hello
    }

    public enum Failure: Error, Equatable {
        case timedOut
        case linkClosed
    }

    public static func perform(on link: any Link, local: ControlMessage.Hello, timeout: Duration = .seconds(5)) async throws -> Result {
        let bytes = try ControlMessage.hello(local).encoded()
        try await link.send(Packet(kind: .control, sequence: 0, timestamp: 0, payload: bytes))
        return try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask {
                for await event in link.events {
                    switch event {
                    case .received(let packet) where packet.header.kind == .control:
                        if case .hello(let h) = try? ControlMessage.decode(packet.payload) { return Result(remote: h) }
                    case .closed:
                        throw Failure.linkClosed
                    default:
                        continue
                    }
                }
                throw Failure.linkClosed
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// When both phones run both roles and two links form, both sides must keep the same one.
    /// Rule: the phone with the lower identifier keeps the link it initiated; the other keeps the
    /// link it accepted. `initiatedLocally` is true for the browser or central side.
    public static func shouldKeep(localIdentifier: String, remoteIdentifier: String, initiatedLocally: Bool) -> Bool {
        (localIdentifier < remoteIdentifier) == initiatedLocally
    }
}
