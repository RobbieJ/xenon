# Sotto

**Talk normally in a loud room.** Sotto is an iPhone app that lets two people, each
wearing their own AirPods, hold a natural conversation in a noisy restaurant or on an
aircraft with no Wi-Fi and no mobile signal. Each phone picks up its owner's voice
from their AirPods, sends it straight to the other phone over a local radio link, and
plays it into the other person's ears with noise cancelling still on.

Think of it as a phone call with the phone network taken out.

> This repository was previously a fork of VMware's Xenon Java framework. That code has
> been removed and the repository re-purposed for this project. The old history remains
> in git for reference.

## Status

Phase 1 in progress: the pure-Swift core (wire protocol, session state machine, jitter buffer, codec
abstraction, in-process loopback link) is written and unit-tested. The device-only code (AVAudioEngine
pipeline, Opus wrapper, BLE L2CAP and Wi-Fi Aware links, SwiftUI app) is written but **not yet built or
run on a device**. The first on-device milestone is the loopback self-test: capture from your AirPods,
pass it through a simulated poor link, and hear it back. Start with:

| Document | What it is |
| --- | --- |
| [docs/PLAN.md](docs/PLAN.md) | The approach, architecture, roadmap and open questions. Read this first. |
| [docs/research/01-transport.md](docs/research/01-transport.md) | Phone-to-phone link options: BLE L2CAP, MultipeerConnectivity, AWDL, Wi-Fi Aware. |
| [docs/research/02-airpods-audio.md](docs/research/02-airpods-audio.md) | AirPods microphone path, audio session, voice processing, interfering AirPods features. |
| [docs/research/03-codec-and-latency.md](docs/research/03-codec-and-latency.md) | Codec choice, packet format, jitter buffer, mouth-to-ear latency budget. |
| [docs/research/04-ios27-platform.md](docs/research/04-ios27-platform.md) | What iOS 27 and WWDC26 changed, call frameworks, background rules, App Store review. |
| [docs/research/05-product-ux-prior-art.md](docs/research/05-product-ux-prior-art.md) | Competing apps, Apple's built-in alternatives, pairing UX, aircraft constraints. |
| [docs/adr/](docs/adr/) | Architecture decision records. One file per decision. |

## Target platform

- iOS 27 (iOS 26 minimum deployment target), Swift 6, SwiftUI, Xcode 27.
- AirPods Pro 2, AirPods Pro 3 and AirPods 4 (ANC) are the priority headsets.
- Real devices only. The simulator has no Bluetooth or peer-to-peer Wi-Fi.

## Repository layout

```
project.yml                 XcodeGen spec; `xcodegen generate` produces Sotto.xcodeproj (git-ignored)
Sotto/                      SwiftUI app target: session coordinator, real-time pipeline, views
Packages/SottoKit/          One Swift package, three libraries:
  Sources/SottoCore/        Wire format, control messages, stream framer, session reducer, pairing race, latency probe
  Sources/SottoAudio/       Jitter buffer, codec protocol (PCM passthrough, Opus when linked), level meter,
                            PCM ring buffer, AVAudioEngine controller and AVAudioSession policy
  Sources/SottoTransport/   Link protocol, deterministic loopback pair, BLE L2CAP link, Wi-Fi Aware link
  Tests/                    Swift Testing suites (run with `swift test`, no device needed)
Scripts/                    build-opus-xcframework.sh and the C shim for libopus
docs/                       Plan, research and decisions
.github/workflows/ci.yml    Linux and macOS package tests; advisory iOS app build
```

## Building

On a Mac with Xcode 27:

```bash
brew install xcodegen cmake
Scripts/build-opus-xcframework.sh      # optional: without it the app uses raw PCM (fine for measurement)
xcodegen generate
open Sotto.xcodeproj                   # set your team, run on two iPhones
```

Package tests anywhere with a Swift 6.3 toolchain (install libopus first, `brew install opus` or
`apt install libopus-dev`, so the Opus wrapper is tested for real rather than the PCM stand-in):

```bash
cd Packages/SottoKit && swift test
```
