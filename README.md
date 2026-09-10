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

Research and planning. No app code yet. Start with:

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

## Planned repository layout

```
Sotto/                      Xcode project (SwiftUI app target)
Packages/
  SottoCore/                Session state machine, pairing, protocol (pure Swift, unit-tested)
  SottoAudio/               AVAudioSession, AVAudioEngine capture and playback, codec, jitter buffer
  SottoTransport/           Wi-Fi Aware and BLE L2CAP links behind one protocol
docs/                       Plan, research and decisions
```
