import SwiftUI
import Network
import SottoTransport
#if canImport(DeviceDiscoveryUI)
import DeviceDiscoveryUI
#endif

/// The system pairing sheet for the phone that publishes ("Only one of you needs to tap").
/// Wraps DeviceDiscoveryUI's UIKit controller; the SwiftUI DevicePairingView is not in the
/// iOS 26.5 SDK's public interface, so the representable is the confirmed path.
struct PairingHostView: UIViewControllerRepresentable {
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        #if canImport(DeviceDiscoveryUI)
        do {
            let provider = try WiFiAwareService.pairingListenerProvider()
            guard DDDevicePairingViewController.isSupported(provider) else {
                onError("Wi-Fi Aware pairing is not supported on this iPhone.")
                return UIViewController()
            }
            return DDDevicePairingViewController(listenerProvider: provider, access: .permanent)
        } catch {
            onError(String(describing: error))
            return UIViewController()
        }
        #else
        return UIViewController()
        #endif
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

/// The system device picker for the phone that subscribes. Returns the chosen endpoint.
struct PairingPickerView: UIViewControllerRepresentable {
    let onPicked: (NWEndpoint) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        #if canImport(DeviceDiscoveryUI)
        do {
            let descriptor = try WiFiAwareService.pairingBrowseDescriptor()
            guard DDDevicePickerViewController.isSupported(descriptor),
                  let picker = DDDevicePickerViewController(browseDescriptor: descriptor, parameters: nil, access: .permanent) else {
                onError("Wi-Fi Aware pairing is not supported on this iPhone.")
                return UIViewController()
            }
            // On iOS the picker's result is its async `endpoint` property (the ObjC completion
            // handler is tvOS-only and hidden from Swift).
            let onPicked = onPicked, onError = onError
            Task { @MainActor in
                do { onPicked(try await picker.endpoint) } catch { onError(String(describing: error)) }
            }
            return picker
        } catch {
            onError(String(describing: error))
            return UIViewController()
        }
        #else
        return UIViewController()
        #endif
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
