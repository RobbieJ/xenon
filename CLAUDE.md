# Sotto: notes for Claude Code sessions

Sotto is an iOS 27 app that lets two AirPods wearers talk over a direct phone-to-phone link with no
network. Read `docs/PLAN.md` first; decisions live in `docs/adr/`, research in `docs/research/`.

## Conventions

- British English in docs, comments, commit messages and user-facing strings.
- Swift 6 strict concurrency everywhere. No `nonisolated(unsafe)` without a comment saying why.
- Pure logic lives in `Packages/SottoKit` and must be unit-tested with Swift Testing. Anything that
  needs an Apple framework is guarded with `#if canImport(...)` so `swift test` runs on Linux.
- The Xcode project is generated: edit `project.yml`, run `xcodegen generate`, commit both.
- Never use MultipeerConnectivity (deprecated) or `bluetoothHighQualityRecording` (not real-time).
- One Opus frame per packet, never bundled. The wire format is in `SottoCore/WireFormat.swift`.
- No synthesised sidetone (ADR-0007).

## Building and testing here (Linux, no Xcode)

```bash
export PATH=/home/user/toolchain/swift-6.3-RELEASE-ubuntu24.04/usr/bin:$PATH   # if the toolchain is present
cd Packages/SottoKit && swift test
```

If the toolchain is missing, download the Swift 6.3 Ubuntu 24.04 tarball from swift.org into
`/home/user/toolchain`. XcodeGen builds from source on Linux with
`USER=x LOGNAME=x xcodegen generate` (it needs a username set).

## CI as the compiler for Apple-only code

GitHub Actions (`.github/workflows/ci.yml`) runs the package tests on Linux and macOS, and an
advisory iOS build on the newest Xcode the runner has. That iOS job prints the SDK's Swift
interface declarations for WiFiAware, DeviceDiscoveryUI, LiveCommunicationKit and the relevant
Network types before building. Read that log through the GitHub job-logs tool when an Apple API
question comes up; it is the ground truth, not memory. Xcode Cloud (`docs/XCODE-CLOUD.md`) is the
real build and TestFlight path once the owner has connected it.

## Where things are

| Area | Path |
| --- | --- |
| Wire format, control messages, session reducer, pairing race, latency probe | `Packages/SottoKit/Sources/SottoCore/` |
| Jitter buffer, codec protocol, Opus wrapper, level meter, ring buffer, AVAudioEngine | `Packages/SottoKit/Sources/SottoAudio/` |
| Link protocol, loopback pair with impairments, BLE L2CAP, Wi-Fi Aware | `Packages/SottoKit/Sources/SottoTransport/` |
| App: coordinator, real-time pipeline, views | `Sotto/Sources/` |
| Opus xcframework build | `Scripts/build-opus-xcframework.sh` |
| Xcode Cloud driver | `Scripts/xcode-cloud.py` |
| Measurement protocol for phase 0 | `docs/measurements/PHASE0-PROTOCOL.md` |
