# Plan: peer-to-peer AirPods conversation app for iOS 27

*Working title: Sotto (placeholder, not trademark-checked). Written 10 September 2026 from the five research reports in `docs/research/`. Decisions are recorded in `docs/adr/`.*

## 1. The problem in one paragraph

Two people at a loud restaurant table or in adjacent aircraft seats each have an iPhone and AirPods. There is no Wi-Fi network and no mobile signal. They want to talk at a normal volume and hear each other clearly, with noise cancelling on, without touching their phones once the conversation has started. It should feel like a phone call with the network removed.

## 2. What the research settled

| Question | Answer | Confidence | Source |
| --- | --- | --- | --- |
| Can a third-party app talk Bluetooth Classic phone-to-phone? | No. HFP, A2DP and SPP are closed. Only BLE (GATT and L2CAP channels) is available. | High | research/01 §6 |
| Best phone-to-phone link | **Wi-Fi Aware** (iOS 26+, iPhone 12+) in `.realtime` mode with the `.interactiveVoice` class. Apple's DTS now points real-time peer apps here. | High on API, low on measured numbers | research/01 §4 |
| Fallback link | **BLE L2CAP channel**. Works with Wi-Fi off, lowest power, ~36 to 140 kbps measured, 15 to 30 ms connection interval set by iOS. | Medium | research/01 §1 |
| MultipeerConnectivity? | **Deprecated in Xcode 27**, and has an iOS 26 regression in exactly the no-access-point case. Do not use. | High | research/01 §2, research/04 §1 |
| AirPods microphone path | Any app taking AirPods input forces HFP. On H2 AirPods that is AAC-ELD at 24 kHz mono. ANC stays on. | High (24 kHz), medium (codec) | research/02 §1, §6 |
| iOS 26 studio-quality AirPods recording | Not usable for us: `.default` mode only, higher latency, not for real-time, not in the EU. | High | research/02 §2 |
| Voice pickup in noise | Apple voice processing (`setVoiceProcessingEnabled`) plus the user-selected Voice Isolation mic mode. Apps cannot switch Voice Isolation on themselves. | High | research/02 §3, §4 |
| Codec | **libopus** shipped as an xcframework. Apple's built-in Opus has no packet-loss or FEC control. | High | research/03 §2, §3 |
| Mouth-to-ear latency | ~105 ms best, **~230 ms typical**, ~550 ms worst. The two AirPods Bluetooth hops are half the budget. Usable, "phone-call-like", not transparent. | Medium | research/03 §4 |
| Keeping the app alive with the screen locked | The `audio` background mode with a live play-and-record engine. Neither transport survives suspension on its own. | High | research/01 §1, §4; research/04 §5 |
| Call lifecycle and lock-screen UI | **LiveCommunicationKit**, which WWDC26 names as the replacement for CallKit's CXProvider. No VoIP push needed for a local call. | High | research/04 §4 |
| Pairing | **DeviceDiscoveryUI** with Wi-Fi Aware: one PIN on first use, remembered by the system after that. | High | research/01 §4, research/05 §3 |
| Anything in iOS 27 that changes the design? | No. iOS 27 adds `WAPerformanceForecast` and formalises the deprecation of MultipeerConnectivity. No new AirPods, Core Audio or LE Audio APIs. | High | research/04 §1 |
| AirPods LE Audio / LC3? | Not on any AirPods model as of September 2026. Not exposed to apps. | Medium | research/04 §3 |

## 3. Product principles

1. **Zero taps to talk after the first time.** Pair once with the system PIN sheet. Every later session: open the app, and it is already connecting to the remembered partner.
2. **It is a call.** Reporting the session to the system as a call gives the lock-screen UI, Dynamic Island, AirPods stem-press to mute or end, and the audio session priority that keeps the app running in a pocket.
3. **Always-on full duplex, never push-to-talk.** One large mute button. No walkie-talkie metaphors.
4. **No app sidetone.** Own-voice delay is objectionable above 10 ms and any Bluetooth path is ten times that. Rely on the AirPods' own occlusion handling.
5. **Honest about latency.** We will measure before we build UI. If typical mouth-to-ear latency lands above 300 ms on real AirPods, the plan changes (see §8).
6. **Fewest settings possible.** Paired partners, auto-connect, captions, and a link to the AirPods checklist. That is the whole settings screen.

## 4. Architecture

```
┌──────────────────────── iPhone A ───────────────────────┐        ┌──────── iPhone B ────────┐
│ AirPods A mic ─HFP─▶ AVAudioEngine input (VPIO on)       │        │                          │
│    │ 24 kHz mono                                          │        │                          │
│    ▼                                                      │        │                          │
│ [optional 2nd-stage NS] ─▶ Opus enc (20 ms, ~20 kbps) ─▶ │ Wi-Fi  │ ─▶ jitter buffer ─▶ Opus │
│                                             framing ─────┼─Aware──┼─▶ dec ─▶ engine output   │
│                                                          │ (UDP)  │        │ HFP             │
│ AirPods A ear ◀─HFP─ engine output ◀─ Opus dec ◀─ jitter │  or    │        ▼                 │
│                                          buffer ◀────────┼─ BLE ──┼─ AirPods B ear / mic     │
│                                                          │ L2CAP  │                          │
│ LiveCommunicationKit conversation (lock screen, island)  │        │                          │
└──────────────────────────────────────────────────────────┘        └──────────────────────────┘
```

### 4.1 Packages

| Package | Responsibility | Testable off-device? |
| --- | --- | --- |
| `SottoCore` | Session state machine, partner records, wire protocol (framing, sequence numbers, timestamps, control messages), leader election for the "both tapped Pair" race. Pure Swift, no Apple frameworks beyond Foundation. | Yes, fully |
| `SottoAudio` | AVAudioSession configuration, AVAudioEngine graph, Opus wrapper (libopus xcframework), jitter buffer, clock-drift handling, level metering. | Codec and jitter buffer yes (synthetic traces); engine no |
| `SottoTransport` | `Link` protocol with two implementations: `WiFiAwareLink` (Network framework, `.realtime`, `.interactiveVoice`) and `BLEL2CAPLink` (Core Bluetooth, dynamic PSM over GATT). Link selection and failover. | Protocol logic yes; radios no |
| `Sotto` (app) | SwiftUI, Liquid Glass, onboarding, DeviceDiscoveryUI pairing, LiveCommunicationKit, Live Activity, captions. | UI tests on device only |

### 4.2 Audio pipeline

- Session: `.playAndRecord`, mode `.voiceChat`, options `[.allowBluetoothHFP]` only. Preferred sample rate 24 000 Hz, preferred IO buffer 10 ms. Activated by LiveCommunicationKit's audio session callback, not directly.
- Capture: `inputNode.setVoiceProcessingEnabled(true)` with the playback graph attached first. AGC on. Advanced ducking off. Prompt the user once to choose Voice Isolation in Control Centre via `showSystemUserInterface(.microphoneModes)`.
- Second-stage noise suppression is a **phase 2 experiment**, not v1: RNNoise (BSD, ~10 ms) first, DeepFilterNet3 or Krisp only if restaurant babble defeats Apple's processing.
- Encode: libopus 1.6.x, `OPUS_APPLICATION_VOIP`, 24 kHz input where the route reports it (16 kHz otherwise), 20 ms frames, constrained VBR around 20 kbps (floor 12, ceiling 32), complexity 6 to 8. PLC on the decoder. In-band FEC on over Wi-Fi Aware (lossy UDP) with a 5 to 10 % loss hint; off over BLE L2CAP (reliable stream) where a bounded sender queue drops stale frames instead.
- Jitter buffer: NetEQ-style arrival-delay histogram, 95th-percentile target, initial 40 ms, clamped 20 to 120 ms, accelerate and expand on low-energy frames to absorb clock drift between the two phones.
- Playback: mono source node into the voice-processing output at hardware rate.

### 4.3 Wire protocol

One Opus frame per packet, never bundled. Header of 10 bytes: version and flags, 16-bit sequence, 32-bit sample timestamp, 16-bit payload length. Total 60 to 90 bytes per 20 ms, about 35 kbps per direction with overhead, 70 kbps for both. A control channel (same link, distinct message type) carries mute state, talking indicator, battery, and the latency ping used to align clocks in test builds.

Encryption: Wi-Fi Aware pairs are encrypted at the link layer. The BLE fallback uses `publishL2CAPChannel(withEncryption: true)` plus a shared key derived at first pairing and kept in the Keychain.

### 4.4 Transport selection

1. If both phones support Wi-Fi Aware (`WACapabilities.supportedFeatures`) and the Wi-Fi radio is on: Wi-Fi Aware, `.realtime`, `.interactiveVoice`, UDP. Log `currentPath.wifiAware.performance` on every session for the field-trial dataset. On iOS 27, use `WAPerformanceForecast` to pick the Opus bitrate ceiling.
2. Otherwise (Wi-Fi off in Airplane Mode, older iPhone, or Wi-Fi Aware failed twice): BLE L2CAP. Lower bitrate profile (16 kbps), and show a quiet "Bluetooth only" badge with a one-tap route to turn Wi-Fi back on.
3. Never MultipeerConnectivity. Network framework over AWDL is not used either; its channel-hopping jitter has no supported real-time mode.

### 4.5 Session lifecycle

- LiveCommunicationKit `ConversationManager` with a `StartConversationAction` on the initiating phone and `JoinConversationAction` on the other, triggered by the invite that arrives over the link. Provides the lock-screen call UI, Dynamic Island, Recents, and AirPods stem-press handling. CallKit's `CXProvider` is the documented fallback if LiveCommunicationKit misbehaves on the lock screen in testing.
- `UIBackgroundModes`: `audio`, `bluetooth-central`, `bluetooth-peripheral`. The engine never stops during a session, so the process is never suspended. No silence-gating of the engine.
- Route changes (`AVAudioSession.routeChangeNotification`) for ear detection and AirPods automatic switching: re-select the AirPods input, and if the AirPods are gone for more than a few seconds, auto-mute and show it.

### 4.6 Pairing and the first-run race

- First use: both open the app. Each phone publishes and browses at the same time. One person taps **Pair**; the other phone shows the system PIN sheet. If both tap Pair, the phone with the lower random session nonce demotes itself to publisher and shows "Only one of you needs to tap".
- The system stores the `WAPairedDevice` under Settings › Privacy & Security › Paired Devices. Later sessions reconnect without a PIN.
- Guest without the app: QR code that opens an App Clip, with `WASharedSecret` (iOS 26.4+) carried in the code so the guest joins without the picker. Phase 4.
- BLE fallback pairing: exchange a long-term key over the first Wi-Fi Aware session, or over a GATT characteristic with a six-digit code shown on screen if Wi-Fi Aware was never available.

### 4.7 The AirPods checklist users must do themselves

None of these has an API. Show once at first session, and again if the route looks wrong.

- Noise Cancellation on (not Adaptive, not Transparency).
- Conversation Awareness off. It ducks the other person every time you speak.
- Adaptive Audio, Personalised Volume and Loud Sound Reduction off.
- Connect to This iPhone: "When Last Connected", so a Mac or iPad does not steal the AirPods mid-conversation.

### 4.8 Companion features (later phases)

- Live captions of the incoming voice using on-device `SpeechAnalyzer` (iOS 26). Also the accessibility story: never rely on sound alone.
- Post-conversation summary with the on-device Foundation Models framework, only if the user asks. Never stored by default.
- App Intent so the Action button starts a conversation with the last partner.

## 5. Latency budget and the go/no-go gate

| Stage | Best | Typical | Worst |
| --- | --- | --- | --- |
| AirPods mic → iPhone (HFP uplink) | 25 | 45 | 90 |
| iOS input and voice processing | 10 | 25 | 45 |
| Opus framing and encode | 12 | 27 | 47 |
| Link (Wi-Fi Aware realtime or BLE L2CAP) | 4 | 20 | 90 |
| Jitter buffer | 20 | 40 | 100 |
| Decode and output buffer | 5 | 15 | 30 |
| iPhone → AirPods ear (HFP downlink) | 30 | 60 | 150 |
| **Total (ms)** | **~105** | **~230** | **~550** |

ITU-T G.114 calls under 150 ms transparent and up to 400 ms acceptable. Our typical case is a good phone call, not a face-to-face conversation. The two AirPods hops are outside our control and are the first thing to measure.

**Why FaceTime feels natural at the same numbers.** A FaceTime audio call with AirPods on both ends goes through exactly the same two AirPods hops we do, plus 30 to 100 ms of internet in the middle, so its mouth-to-ear delay is if anything higher than ours. Two things hide it. First, turn-taking tolerates 200 ms: people only notice delay as occasional talk-overs, which is what G.114's "acceptable" band means. Second, and this is the part specific to us, a FaceTime listener has no reference copy of the voice. Our listener is sitting across the table, so the direct acoustic voice leaks through the ear tips and arrives first, and the delayed copy from the app arrives a fifth of a second later. That double arrival, not the absolute delay, is what would read as "lag". It matters least in exactly the places we target: in a loud restaurant or cabin the direct voice is masked by the noise and ANC, and the app's copy is the only intelligible one. It matters most in a quiet room, where the app has no reason to exist. So the phase 0 gate is really two measurements: absolute delay, and how audible the direct path is at typical restaurant and cabin noise levels with ANC on.

**Gate for phase 0:** measured typical mouth-to-ear latency on AirPods Pro 2, Pro 3 and AirPods 4 ANC ≤ 250 ms, and 95th percentile ≤ 350 ms, over Wi-Fi Aware. If we miss it, see §8.

## 6. Roadmap

Each phase ends with something a person can try on two phones.

### Phase 0: measure (1 to 2 weeks)
- Throwaway Xcode project on two iPhones. Wi-Fi Aware link, raw PCM or Opus, AirPods on both ends. No UI beyond a button.
- Measure per-hop timestamps and physical mouth-to-ear latency with a click track and a second recording device (method in research/03 §9). Repeat after 20 minutes because AirPods latency drifts.
- Measure the same over BLE L2CAP with both AirPods links active, to see coexistence stalls.
- Confirm the HFP route reports 24 kHz on each AirPods model, and whether Conversation Awareness ducks our audio.
- Try the zero-code baseline: cross-pair each person's AirPods to the other's phone and use Live Listen. It is the benchmark our app has to beat on quality and on friction.
- Output: `docs/measurements/phase0.md` with the numbers, and a go/no-go against §5.

### Phase 1: core packages (2 weeks)
- `SottoCore` protocol, framing, session state machine, leader election. Full unit tests.
- `SottoAudio` Opus wrapper (libopus xcframework built from source with CMake, vended as an SPM binary target) and the jitter buffer, tested against synthetic jitter, loss, 30 ms interval quantisation, 200 ms stalls and ±100 ppm drift. Objective quality checked with ViSQOL in CI.
- GitHub Actions on a macOS runner: build, unit tests, SwiftLint, SwiftFormat.

### Phase 2: transports (2 weeks)
- `WiFiAwareLink` with DeviceDiscoveryUI pairing and the performance report logging.
- `BLEL2CAPLink` with dual-role central and peripheral, dynamic PSM over GATT, bounded sender queue.
- Failover logic and the "Bluetooth only" state.

### Phase 3: the call (2 weeks)
- AVAudioEngine graph with voice processing, route-change handling, LiveCommunicationKit lifecycle, background survival with the screen locked for 90 minutes, Dynamic Island, stem-press mute and end.
- First internal TestFlight: two phones, real restaurant.

### Phase 4: product (3 weeks)
- Onboarding (five screens), AirPods checklist, Voice Isolation prompt, settings, Liquid Glass polish, accessibility pass, live captions, App Clip guest join.
- Privacy manifest, purpose strings, Wi-Fi Aware entitlement, App Store metadata that leads with "offline, AirPods to AirPods, full duplex" to clear guideline 4.3(b).

### Phase 5: field trials and release (2 to 3 weeks)
- Structured trials: restaurant, pub, aircraft cabin (Wi-Fi on in Airplane Mode, then Wi-Fi off to force BLE). Collect the performance logs.
- Second-stage noise suppression experiment if babble rejection is the top complaint.
- App Store submission.

## 7. Platform decisions

- **Minimum iOS 27.0**, Swift 6.4, Xcode 27, SwiftUI with Liquid Glass. The APIs we depend on span iOS 26.0 to 27.0, iOS 27 drops no devices that iOS 26 supported, and the app ships after iOS 27 has been out for months. See ADR-0001.
- Devices: iPhone 12 or later get Wi-Fi Aware. iPhone 11 gets the BLE path only.
- Real devices only. Nothing in this app runs in the simulator.
- Repo tooling: plain Xcode project checked in, local Swift packages for the three libraries, GitHub Actions macOS runners for CI. Fastlane later for TestFlight.

## 8. Risks and what we do about them

| Risk | Likelihood | Response |
| --- | --- | --- |
| Two AirPods HFP hops push typical latency above 300 ms | Medium | Phase 0 measures it first. Mitigations in order: shorter jitter buffer floor, 10 ms Opus frames, then offer "one wired earbud" or "phone on table with Voice Isolation" modes. Worst case the product becomes a hearing-assist remote mic rather than a two-way call. |
| Wi-Fi Aware is young and has iOS 26.x bugs | Medium | Gate on `supportedFeatures`, keep the BLE path production-quality, log everything, file Feedback Assistant reports early. |
| BLE L2CAP stalls under two eSCO links on the same band | Medium | Measured in phase 0. Bounded sender queue, PLC, and the "Bluetooth only" quality badge. |
| Conversation Awareness ducks the far voice | High if left on | Checklist card at first session; detect the HFP route but we cannot detect the toggle. |
| Cabin crew treat Wi-Fi Aware as "Wi-Fi" | Medium | BLE fallback plus a one-tap Wi-Fi toggle prompt. No regulator distinguishes peer-to-peer Wi-Fi. |
| App Store 4.3(b) "not distinguishable" rejection | Low to medium | Metadata leads with the differentiator; no walkie-talkie language. |
| LiveCommunicationKit lock-screen behaviour differs from session 226's description | Low | CallKit `CXProvider` as fallback, same audio-session pattern. China would then lose the lock-screen UI. |

## 9. Open questions to answer on devices

1. Real mouth-to-ear latency across two AirPods HFP hops per model, with and without voice processing.
2. Does the third-party `.voiceChat` route negotiate 24 kHz AAC-ELD on all three AirPods models, or drop to mSBC when other devices are paired?
3. Does Conversation Awareness duck our call audio or only media?
4. Does iOS inject own-voice sidetone during a third-party call session on AirPods, and can it be suppressed?
5. Wi-Fi Aware realtime jitter in a cabin full of other radios.
6. Does Voice Isolation reject the other participant sitting across the table, given that their voice arrives at the same microphones?
7. Battery drain for a 90-minute session on each transport.

## 10. What to try now, with no code

If you have two iPhones and two sets of AirPods to hand: pair each person's AirPods to the other person's iPhone, turn on Live Listen from Control Centre on both phones, and place each phone near its owner's mouth. That is the zero-code baseline. It shows what Apple's own ~150 ms one-way path feels like, and how much the phone microphone picks up compared with the AirPods microphones we will use. Everything the app adds is measured against that.
