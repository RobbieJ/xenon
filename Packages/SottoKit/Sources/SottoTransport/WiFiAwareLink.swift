#if canImport(WiFiAware) && canImport(Network) && os(iOS)
import Foundation
import Network
import WiFiAware
import SottoCore

/// A `Link` over one Wi-Fi Aware `NetworkConnection` (UDP datagrams, one packet per datagram).
///
/// The connection is created by `WiFiAwareService` below, or by the app after the user picks a
/// partner in DeviceDiscoveryUI. Performance mode `.realtime` and service class
/// `.interactiveVoice` are set on the parameters; both sides must use the same mode.
///
/// DEVICE-ONLY AND NOT YET COMPILED against the iOS 27 SDK in CI: WiFiAware is iOS-only and
/// GitHub's macOS runners cannot build it. Expect to fix API details in Xcode (phase 2).
@available(iOS 26.0, *)
public final class WiFiAwareLink: Link, @unchecked Sendable {
    public let kind: LinkKind = .wifiAware
    public let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let connection: NetworkConnection<UDP>
    private let lock = NSLock()
    private var isOpen = true
    private var receiveTask: Task<Void, Never>?

    public init(connection: NetworkConnection<UDP>) {
        self.connection = connection
        let (stream, cont) = AsyncStream<LinkEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = cont
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    private func receiveLoop() async {
        do {
            try await connection.waitUntilReady()
            continuation.yield(.ready)
            for try await (content, _) in connection.messages {
                guard let packet = Packet.decode(datagram: Array(content)) else { continue }
                continuation.yield(.received(packet))
                if let perf = try await connection.currentPath?.wifiAware?.performance {
                    continuation.yield(.qualityChanged(LinkQuality(signalStrength: Double(perf.signalStrength) / 100.0, estimatedLatencyMilliseconds: nil, throughputBitsPerSecond: nil)))
                }
            }
            finish(.remote)
        } catch {
            finish(.lost(String(describing: error)))
        }
    }

    public func send(_ packet: Packet) async throws {
        guard lock.withLock({ isOpen }) else { throw LinkError.notReady }
        do {
            try await connection.send(Data(packet.encoded()))
        } catch {
            throw LinkError.sendFailed(String(describing: error))
        }
    }

    public func close() async {
        finish(.local)
        // NetworkConnection has no explicit cancel in the structured API; ending the receive task
        // releases the connection.
        receiveTask?.cancel()
    }

    private func finish(_ reason: LinkCloseReason) {
        let wasOpen: Bool = lock.withLock { let o = isOpen; isOpen = false; return o }
        guard wasOpen else { return }
        continuation.yield(.closed(reason))
        continuation.finish()
    }
}

/// Publisher and subscriber helpers built on the iOS 26 Network framework API.
/// Service names must match the `WiFiAwareServices` entries in the app's Info.plist.
@available(iOS 26.0, *)
public enum WiFiAwareService {
    public static let serviceName = "_sotto._udp"

    public static var isSupported: Bool {
        WACapabilities.supportedFeatures.contains(.wifiAware)
    }

    /// Listen for already-paired devices connecting to us. Yields one link per accepted connection.
    public static func listen() throws -> AsyncThrowingStream<WiFiAwareLink, any Error> {
        guard let service = WAPublishableService.allServices[serviceName] else {
            throw LinkError.unsupported("Info.plist has no publishable \(serviceName)")
        }
        // Parameters are written inline so the type is inferred from NetworkListener; both sides must use the same performance mode.
        let listener = try NetworkListener(
            for: .wifiAware(.connecting(to: service, from: .allPairedDevices)),
            using: .parameters { UDP() }
                .wifiAware { $0.performanceMode = .realtime }
                .serviceClass(.interactiveVoice)
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await connection in listener.run() {
                        continuation.yield(WiFiAwareLink(connection: connection))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Browse for a paired device publishing our service and connect to the first one found.
    public static func connectToFirstPairedDevice() async throws -> WiFiAwareLink {
        guard let service = WASubscribableService.allServices[serviceName] else {
            throw LinkError.unsupported("Info.plist has no subscribable \(serviceName)")
        }
        let browser = NetworkBrowser(for: .wifiAware(.connecting(to: service, from: .allPairedDevices)))
        let endpoint = try await browser.run { endpoints in
            if let first = endpoints.first { return .finish(first) }
            return .continue
        }
        let connection = NetworkConnection(
            to: endpoint,
            using: .parameters { UDP() }
                .wifiAware { $0.performanceMode = .realtime }
                .serviceClass(.interactiveVoice)
        )
        return WiFiAwareLink(connection: connection)
    }
}
#endif
