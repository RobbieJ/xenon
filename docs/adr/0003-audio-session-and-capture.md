# ADR-0003: Play-and-record voice-chat session over HFP with Apple voice processing

**Status:** Proposed, pending phase 0 measurements. **Date:** 2026-09-10.

## Context

See `docs/research/02-airpods-audio.md`. Taking microphone input from AirPods forces the HFP profile. On H2 AirPods that path is AAC-ELD at 24 kHz mono in both directions and ANC stays active. iOS 26's high-quality Bluetooth recording option requires the `.default` mode, adds input latency, is documented as unsuitable for real-time communication, and is unavailable in the EU. The Voice Isolation microphone mode is chosen by the user in Control Centre; an app can only present the picker. Apple's voice-processing IO is the only route to Apple's noise suppression, AGC and the mic modes.

## Decision

- `AVAudioSession` category `.playAndRecord`, mode `.voiceChat`, options `[.allowBluetoothHFP]` only. No A2DP, no default-to-speaker. Preferred sample rate 24 000 Hz, preferred IO buffer 10 ms.
- `AVAudioEngine` with `inputNode.setVoiceProcessingEnabled(true)`, playback graph attached before enabling. AGC on. Advanced ducking off.
- Present `showSystemUserInterface(.microphoneModes)` once during onboarding, recommending Voice Isolation.
- `bluetoothHighQualityRecording` is not used for the live path.
- A second-stage noise suppressor (RNNoise first, then DeepFilterNet3 or Krisp) is a phase 2 experiment behind a flag, not part of v1.
- Route changes are observed; if the AirPods leave the route the session auto-mutes rather than falling back to the phone's speaker and microphone.

## Consequences

- Speech-quality mono audio at up to 12 kHz bandwidth, which is right for voice.
- We inherit two AirPods Bluetooth hops we cannot shorten. The latency gate in `docs/PLAN.md` §5 decides whether that is acceptable.
- Users must switch off Conversation Awareness and Adaptive Audio themselves; there is no API.
