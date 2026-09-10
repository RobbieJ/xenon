# ADR-0002: Wi-Fi Aware as the primary link, BLE L2CAP as the fallback, no MultipeerConnectivity

**Status:** Proposed, pending phase 0 measurements. **Date:** 2026-09-10.

## Context

See `docs/research/01-transport.md`. Third-party apps cannot use Bluetooth Classic profiles. The candidates were BLE L2CAP channels, MultipeerConnectivity, Network framework over AWDL, and the iOS 26 Wi-Fi Aware framework.

- MultipeerConnectivity is deprecated in Xcode 27, only ever used AWDL on modern systems, and has an iOS 26 regression where AWDL is torn down before the session forms when no access point is present.
- Network framework over AWDL suffers 30 to 50 ms jitter roughly once a second from channel hopping and has no supported way to request the real-time mode.
- Wi-Fi Aware offers a sanctioned `.realtime` performance mode and `.interactiveVoice` access category, link-layer encryption, a system pairing UI, and keeps phone-to-phone traffic on 5 GHz when possible, away from the 2.4 GHz band the two AirPods links need. It requires iPhone 12 or later and a Wi-Fi radio that is switched on.
- BLE L2CAP works on every device and with Wi-Fi off, at the lowest power, but iOS controls the 15 to 30 ms connection interval and it shares the 2.4 GHz radio with the AirPods eSCO link on each phone.

Neither transport keeps the process alive on its own. Both survive only because the app is a genuine, continuously running audio session.

## Decision

1. Primary: Wi-Fi Aware, UDP, `performanceMode = .realtime`, `serviceClass(.interactiveVoice)`, the same mode on both sides. Log `currentPath.wifiAware.performance` on every session. On iOS 27 use `WAPerformanceForecast` to set the bitrate ceiling.
2. Fallback: Core Bluetooth L2CAP channel, dynamic PSM exchanged over a GATT characteristic, `withEncryption: true`, bounded sender queue of one frame. Used when Wi-Fi Aware is unsupported, the Wi-Fi radio is off, or Wi-Fi Aware fails twice in a session.
3. MultipeerConnectivity and Network framework over AWDL are not used.
4. Both live behind one `Link` protocol in `SottoTransport` so the audio pipeline does not know which is active.

## Consequences

- Two transports to build and test rather than one, but the BLE path is also the answer to "cabin crew said turn Wi-Fi off".
- Wi-Fi Aware has no published iPhone-to-iPhone latency figures yet. Phase 0 produces ours.
- Battery is higher on Wi-Fi Aware real-time mode. Estimated 6 to 12 percentage points over a 90-minute session versus 2 to 4 for BLE. Measured in phase 5.
