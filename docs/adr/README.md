# Architecture decision records

One file per decision. Status is Proposed until the phase 0 measurements confirm it, then Accepted. Superseded records stay in place with a pointer to the replacement.

| ADR | Decision | Status |
| --- | --- | --- |
| [0001](0001-platform-and-minimum-os.md) | Native Swift 6.4 / SwiftUI, minimum iOS 27.0 | Proposed |
| [0002](0002-transport-wifi-aware-with-ble-fallback.md) | Wi-Fi Aware primary link, BLE L2CAP fallback, no MultipeerConnectivity | Proposed |
| [0003](0003-audio-session-and-capture.md) | Play-and-record voice-chat session over HFP with Apple voice processing | Proposed |
| [0004](0004-codec-libopus.md) | libopus shipped as an xcframework, one 20 ms frame per packet | Proposed |
| [0005](0005-call-lifecycle-livecommunicationkit.md) | LiveCommunicationKit for the session lifecycle, CallKit as fallback | Proposed |
| [0006](0006-pairing-devicediscoveryui.md) | DeviceDiscoveryUI pairing, remembered by the system | Proposed |
| [0007](0007-no-app-sidetone.md) | No synthesised sidetone | Accepted |
