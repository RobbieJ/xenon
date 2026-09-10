# ADR-0006: DeviceDiscoveryUI pairing, remembered by the system

**Status:** Proposed. **Date:** 2026-09-10.

## Context

See `docs/research/05-product-ux-prior-art.md` §3 and `docs/research/04-ios27-platform.md` §6. iPhones cannot pair over NFC with each other from a third-party app, Nearby Interaction needs a bootstrap channel, and MultipeerConnectivity's invitation UI is deprecated with the framework. Wi-Fi Aware's DeviceDiscoveryUI shows a `DevicePairingView` on the publisher and a `DevicePicker` on the subscriber, the system handles the PIN, and the pairing persists as a `WAPairedDevice` in Settings, so later sessions reconnect without any prompt. Competing apps are criticised mostly for discovery that fails or spams.

## Decision

- First use: both phones publish and browse simultaneously. One person taps Pair; the other sees the system PIN sheet. If both tap Pair, the phone with the lower random session nonce becomes the publisher and shows "Only one of you needs to tap".
- Repeat use: the app auto-connects to any remembered partner in range when opened, or from the Action button App Intent. One tap total.
- Guests without the app join via a QR code carrying a `WASharedSecret` that launches an App Clip. Phase 4.
- BLE fallback pairing uses a long-term key exchanged during the first Wi-Fi Aware session, or a six-digit on-screen code over GATT when Wi-Fi Aware was never available.
- Partners can be forgotten from Settings inside the app.

## Consequences

- No custom consent UI to get through App Review; the system sheet is the consent.
- The pairing record lives in iOS Settings, so users can also revoke it there.
- Requires both phones to support Wi-Fi Aware for the smoothest path; the BLE path is a few taps longer on first use only.
