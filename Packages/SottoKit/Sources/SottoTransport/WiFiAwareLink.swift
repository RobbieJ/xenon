#if canImport(WiFiAware) && canImport(Network) && os(iOS)
import Foundation
import Network
import WiFiAware
import SottoCore

/// A `Link` over one Wi-Fi Aware `NetworkConnection<UDP>` (one packet per datagram).
///
/// Signatures below follow the iOS 26.5 SDK's Swift interface (printed by the CI job):
/// `NetworkListener.run` and `NetworkBrowser.run` take handler closures; the publisher action is
/// `connecting(to: service, from: devices)` while the subscriber action is
/// `connecting(to: devices, from: service)`; `WAPerformanceReport.signalStrength` is optional and
/// `transmitLatency` is keyed by access category.
///
/// Device-only. Compiles in the advisory iOS CI job; not yet run on hardware.
@available(iOS 26.0, *)
public final class WiFiAwareLink: Link, @unchecked Sendable {
    public let kind: LinkKind = .wifiAware
    public let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let connection: NetworkConnection<UDP>
    private let lock = NSLock()
    private var isOpen = true
    private var receiveTask: Task<Void, Never>?
    private var qualityTask: Task<Void, Never>?

    public init(connection: NetworkConnection<UDP>) {
        self.connection = connection
        let (stream, cont) = AsyncStream<LinkEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = cont
        continuation.yield(.ready)
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
        qualityTask = Task { [weak self] in await self?.qualityLoop() }
    }

    private func receiveLoop() async {
        do {
            for try await message in connection.messages {
                guard let packet = Packet.decode(datagram: Array(message.content)) else { continue }
                continuation.yield(.received(packet))
            }
            finish(.remote)
        } catch {
            finish(.lost(String(describing: error)))
        }
    }

    /// Samples the Wi-Fi Aware performance report once a second for the field-trial logs.
    private func qualityLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard let report = try? await connection.currentPath?.wifiAware?.performance else { continue }
            let latency = report.transmitLatency[.interactiveVoice]?.average.map { Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15 }
            continuation.yield(.qualityChanged(LinkQuality(
                signalStrength: report.signalStrength.map { max(0, min(1, ($0 + 100) / 70)) },
                estimatedLatencyMilliseconds: latency,
                throughputBitsPerSecond: report.throughputCapacity.map { Int($0) }
            )))
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
        receiveTask?.cancel()
        qualityTask?.cancel()
    }

    private func finish(_ reason: LinkCloseReason) {
        let wasOpen: Bool = lock.withLock { let o = isOpen; isOpen = false; return o }
        guard wasOpen else { return }
        continuation.yield(.closed(reason))
        continuation.finish()
    }
}

/// Publisher and subscriber helpers on the iOS 26 Network framework API.
/// Service names must match the `WiFiAwareServices` entries in the app's Info.plist.
@available(iOS 26.0, *)
public enum WiFiAwareService {
    public static let serviceName = "_sotto._udp"

    public static var isSupported: Bool {
        WACapabilities.supportedFeatures.contains(.wifiAware)
    }

    /// Listen for already-paired devices connecting to us. Yields one link per accepted connection.
    /// Cancelling the consuming task stops the listener.
    public static func listen() throws -> AsyncThrowingStream<WiFiAwareLink, any Error> {
        guard let service = WAPublishableService.allServices[serviceName] else {
            throw LinkError.unsupported("Info.plist has no publishable \(serviceName)")
        }
        let listener = try NetworkListener(
            for: .wifiAware(.connecting(to: service, from: .allPairedDevices)),
            using: .parameters { UDP() }
                .wifiAware { $0.performanceMode = .realtime }
                .serviceClass(.interactiveVoice)
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await listener.run { connection in
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
        let browser = NetworkBrowser(for: .wifiAware(.connecting(to: .allPairedDevices, from: service)))
        let found = EndpointBox()
        do {
            // NetworkBrowser has no cancel; throwing from the handler ends the browse.
            try await browser.run { endpoints in
                if let first = endpoints.first, found.set(first) {
                    throw BrowseFinished()
                }
            }
        } catch is BrowseFinished {
            // expected
        } catch {
            if found.value == nil { throw error }
        }
        guard let endpoint = found.value else { throw LinkError.unsupported("No paired device found") }
        let connection = NetworkConnection(
            to: endpoint,
            using: .parameters { UDP() }
                .wifiAware { $0.performanceMode = .realtime }
                .serviceClass(.interactiveVoice)
        )
        return WiFiAwareLink(connection: connection)
    }

    private struct BrowseFinished: Error {}

    private final class EndpointBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: WAEndpoint?
        var value: WAEndpoint? { lock.withLock { stored } }
        /// Returns true only for the first successful set.
        func set(_ e: WAEndpoint) -> Bool {
            lock.withLock { if stored == nil { stored = e; return true } else { return false } }
        }
    }
}
#endif
