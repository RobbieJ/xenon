# ADR-0001: Native Swift 6.4 / SwiftUI app with a minimum of iOS 27.0

**Status:** Proposed. **Date:** 2026-09-10.

## Context

The app depends on APIs that arrived across iOS 26.0 (Wi-Fi Aware, DeviceDiscoveryUI, the structured-concurrency Network framework types, SpeechAnalyzer), iOS 26.4 (`WASharedSecret`) and iOS 27.0 (`WAPerformanceForecast`). Xcode 27 ships Swift 6.4, makes Liquid Glass mandatory and formally deprecates MultipeerConnectivity. iOS 27 supports every device iOS 26 did (iPhone 11 and later). Public release is 14 September 2026 and our first App Store build is several months away.

## Decision

- Swift 6.4, SwiftUI, Xcode 27, strict concurrency.
- Minimum deployment target iOS 27.0. No iOS 26 branch.
- Real devices only. The simulator has neither Bluetooth nor Wi-Fi Aware.
- Plain Xcode project checked in, with three local Swift packages (`SottoCore`, `SottoAudio`, `SottoTransport`) so the protocol, codec and jitter buffer are unit-tested on a macOS CI runner without a phone.

## Consequences

- Simplest possible availability story and access to the iOS 27 Wi-Fi Aware forecast API.
- Excludes users who have not updated in the first months. Acceptable for a new app whose users, by definition, own recent AirPods.
- The `@State` macro change in iOS 27's SwiftUI must be respected from the first commit.
