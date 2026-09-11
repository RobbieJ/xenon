#if canImport(CoreBluetooth)
import Foundation
import CoreBluetooth
import SottoCore

/// GATT service the peripheral side advertises. The PSM characteristic carries the dynamic
/// L2CAP PSM as a little-endian UInt16 (iOS never assigns fixed PSMs).
public enum SottoBLE {
    // Computed rather than stored: CBUUID is not Sendable, so a static let is rejected under strict concurrency.
    public static var serviceUUID: CBUUID { CBUUID(string: "5A7A0001-9B1E-4C1E-8F3A-4B5C6D7E8F90") }
    public static var psmCharacteristicUUID: CBUUID { CBUUID(string: "5A7A0002-9B1E-4C1E-8F3A-4B5C6D7E8F90") }
    public static var identityCharacteristicUUID: CBUUID { CBUUID(string: "5A7A0003-9B1E-4C1E-8F3A-4B5C6D7E8F90") }
}

/// A `Link` over a `CBL2CAPChannel`. The channel is a byte stream, so packets are framed with
/// `StreamFramer`. Sending is bounded: if the output stream has no space for more than one
/// frame, the oldest queued frame is dropped rather than building latency.
///
/// Device-only; compiles on macOS for CI. NOT yet exercised on hardware.
public final class BLEL2CAPLink: NSObject, Link, StreamDelegate, @unchecked Sendable {
    public let kind: LinkKind = .bleL2CAP
    public let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let channel: CBL2CAPChannel
    private let lock = NSLock()
    private var framer = StreamFramer()
    private var sendQueue: [[UInt8]] = []
    private var partial: [UInt8] = []
    private var partialOffset = 0
    private var isOpen = true
    public var maximumQueuedFrames = 2
    public private(set) var droppedFrames = 0
    private var thread: Thread?

    public init(channel: CBL2CAPChannel) {
        self.channel = channel
        let (stream, cont) = AsyncStream<LinkEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = cont
        super.init()
        startStreamThread()
    }

    private func startStreamThread() {
        let t = Thread { [self] in
            channel.inputStream.delegate = self
            channel.outputStream.delegate = self
            channel.inputStream.schedule(in: .current, forMode: .default)
            channel.outputStream.schedule(in: .current, forMode: .default)
            channel.inputStream.open()
            channel.outputStream.open()
            while self.lock.withLock({ self.isOpen }) {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        }
        t.name = "sotto.ble.l2cap"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
        continuation.yield(.ready)
    }

    public func send(_ packet: Packet) async throws {
        let accepted: Bool = lock.withLock {
            guard isOpen else { return false }
            sendQueue.append(packet.encoded())
            if sendQueue.count > maximumQueuedFrames {
                sendQueue.removeFirst()
                droppedFrames += 1
            }
            return true
        }
        guard accepted else { throw LinkError.notReady }
        pump()
    }

    /// Writes as much as the output stream accepts. Called from send and from space-available events.
    private func pump() {
        lock.lock(); defer { lock.unlock() }
        guard isOpen else { return }
        while channel.outputStream.hasSpaceAvailable {
            if partial.isEmpty {
                guard !sendQueue.isEmpty else { return }
                partial = sendQueue.removeFirst()
                partialOffset = 0
            }
            let wrote = partial.withUnsafeBufferPointer { buf -> Int in
                channel.outputStream.write(buf.baseAddress! + partialOffset, maxLength: buf.count - partialOffset)
            }
            if wrote <= 0 { return }
            partialOffset += wrote
            if partialOffset >= partial.count { partial.removeAll(keepingCapacity: true); partialOffset = 0 }
        }
    }

    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            var buf = [UInt8](repeating: 0, count: 2048)
            while channel.inputStream.hasBytesAvailable {
                let n = buf.withUnsafeMutableBufferPointer { channel.inputStream.read($0.baseAddress!, maxLength: $0.count) }
                guard n > 0 else { break }
                let packets: [Packet] = lock.withLock { framer.append(buf[0..<n]) }
                for p in packets { continuation.yield(.received(p)) }
            }
        case .hasSpaceAvailable:
            pump()
        case .errorOccurred, .endEncountered:
            finish(.lost(aStream.streamError?.localizedDescription ?? "stream ended"))
        default:
            break
        }
    }

    public func close() async {
        finish(.local)
    }

    private func finish(_ reason: LinkCloseReason) {
        let wasOpen: Bool = lock.withLock { let o = isOpen; isOpen = false; return o }
        guard wasOpen else { return }
        channel.inputStream.close()
        channel.outputStream.close()
        continuation.yield(.closed(reason))
        continuation.finish()
    }
}

/// Peripheral role: advertises the Sotto service, publishes an encrypted L2CAP channel and
/// exposes its PSM. Hands each accepted channel to `onLink`.
public final class BLEPeripheralHost: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    private var manager: CBPeripheralManager!
    private var psm: CBL2CAPPSM = 0
    private var psmCharacteristic: CBMutableCharacteristic?
    private let identity: Data
    private let onLink: @Sendable (BLEL2CAPLink) -> Void
    private let onError: @Sendable (String) -> Void

    public init(identity: String, onLink: @escaping @Sendable (BLEL2CAPLink) -> Void, onError: @escaping @Sendable (String) -> Void) {
        self.identity = Data(identity.utf8)
        self.onLink = onLink
        self.onError = onError
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: DispatchQueue(label: "sotto.ble.peripheral"))
    }

    /// Stop being discoverable but keep any channel that is already open alive.
    public func stopAdvertising() {
        manager.stopAdvertising()
    }

    /// Full teardown: also unpublishes the PSM, which closes open channels.
    public func stop() {
        manager.stopAdvertising()
        if psm != 0 { manager.unpublishL2CAPChannel(psm) }
        manager.removeAllServices()
    }

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn: peripheral.publishL2CAPChannel(withEncryption: true)
        case .poweredOff: onError("Bluetooth is switched off.")
        case .unauthorized: onError("Sotto does not have permission to use Bluetooth.")
        case .unsupported: onError("This iPhone does not support Bluetooth LE.")
        default: break
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: (any Error)?) {
        if let error { onError(error.localizedDescription); return }
        psm = PSM
        var value = PSM.littleEndian
        let psmData = Data(bytes: &value, count: 2)
        let psmChar = CBMutableCharacteristic(type: SottoBLE.psmCharacteristicUUID, properties: [.read], value: psmData, permissions: [.readEncryptionRequired])
        let idChar = CBMutableCharacteristic(type: SottoBLE.identityCharacteristicUUID, properties: [.read], value: identity, permissions: [.readable])
        let service = CBMutableService(type: SottoBLE.serviceUUID, primary: true)
        service.characteristics = [psmChar, idChar]
        psmCharacteristic = psmChar
        peripheral.add(service)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        if let error { onError(error.localizedDescription); return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [SottoBLE.serviceUUID]])
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: (any Error)?) {
        if let error { onError(error.localizedDescription); return }
        guard let channel else { return }
        onLink(BLEL2CAPLink(channel: channel))
    }
}

/// Central role: scans for the Sotto service, reads the peer's identity and PSM, and opens the
/// L2CAP channel only when `BLERolePolicy` says this phone is the opener. Peripherals that the
/// policy assigns the other way, or that are not in `acceptedIdentities` when that set is
/// non-empty, are released and the scan resumes.
public final class BLECentralClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private let localIdentity: String
    private let acceptedIdentities: Set<String>
    private let onLink: @Sendable (BLEL2CAPLink, _ remoteIdentity: String?) -> Void
    private let onError: @Sendable (String) -> Void
    private var remoteIdentity: String?
    private var psm: CBL2CAPPSM?
    private var skipped: Set<UUID> = []
    private var linkOpened = false

    /// - Parameters:
    ///   - localIdentity: this phone's stable identifier, compared with the peer's for the role policy.
    ///   - acceptedIdentities: remembered partners; empty means accept anyone (first pairing).
    public init(localIdentity: String, acceptedIdentities: Set<String> = [], onLink: @escaping @Sendable (BLEL2CAPLink, String?) -> Void, onError: @escaping @Sendable (String) -> Void) {
        self.localIdentity = localIdentity
        self.acceptedIdentities = acceptedIdentities
        self.onLink = onLink
        self.onError = onError
        super.init()
        manager = CBCentralManager(delegate: self, queue: DispatchQueue(label: "sotto.ble.central"))
    }

    /// Stop looking for peers but keep a connection that carries an open channel.
    public func stopScanning() {
        manager.stopScan()
        if !linkOpened, let p = peripheral { manager.cancelPeripheralConnection(p); peripheral = nil }
    }

    /// Full teardown, including the connection under an open channel.
    public func stop() {
        manager.stopScan()
        if let p = peripheral { manager.cancelPeripheralConnection(p) }
        peripheral = nil
    }

    private func scan(_ central: CBCentralManager) {
        central.scanForPeripherals(withServices: [SottoBLE.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func release(_ central: CBCentralManager, _ p: CBPeripheral) {
        skipped.insert(p.identifier)
        central.cancelPeripheralConnection(p)
        peripheral = nil
        remoteIdentity = nil
        psm = nil
        scan(central)
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: scan(central)
        case .poweredOff: onError("Bluetooth is switched off.")
        case .unauthorized: onError("Sotto does not have permission to use Bluetooth.")
        case .unsupported: onError("This iPhone does not support Bluetooth LE.")
        default: break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil, !skipped.contains(peripheral.identifier) else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([SottoBLE.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        onError(error?.localizedDescription ?? "connect failed")
        self.peripheral = nil
        scan(central)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        guard !linkOpened else { return }
        self.peripheral = nil
        scan(central)
    }

    /// Once both the identity and the PSM are known, apply the policy and open or release.
    private func decide(_ peripheral: CBPeripheral) {
        guard let remoteIdentity, let psm else { return }
        if !acceptedIdentities.isEmpty, !acceptedIdentities.contains(remoteIdentity) {
            release(manager, peripheral)
            return
        }
        guard BLERolePolicy.shouldOpenChannel(localIdentity: localIdentity, remoteIdentity: remoteIdentity) else {
            // The other phone is the opener; our peripheral will accept its channel.
            release(manager, peripheral)
            return
        }
        peripheral.openL2CAPChannel(psm)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == SottoBLE.serviceUUID }) else { return }
        peripheral.discoverCharacteristics([SottoBLE.psmCharacteristicUUID, SottoBLE.identityCharacteristicUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        for c in service.characteristics ?? [] { peripheral.readValue(for: c) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error { onError(error.localizedDescription); return }
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case SottoBLE.identityCharacteristicUUID:
            remoteIdentity = String(decoding: data, as: UTF8.self)
            decide(peripheral)
        case SottoBLE.psmCharacteristicUUID:
            guard data.count >= 2 else { return }
            psm = CBL2CAPPSM(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
            decide(peripheral)
        default:
            break
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: (any Error)?) {
        if let error { onError(error.localizedDescription); return }
        guard let channel else { return }
        linkOpened = true
        onLink(BLEL2CAPLink(channel: channel), remoteIdentity)
    }
}
#endif
