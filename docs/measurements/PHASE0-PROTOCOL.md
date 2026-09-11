# Phase 0 measurement protocol

The plan's go/no-go gate (docs/PLAN.md §5) needs numbers that only two real iPhones and two sets of
AirPods can produce. This is the protocol. Results go in `docs/measurements/phase0-results.md`.

## Kit

- Two iPhones on iOS 27 (one of them iPhone 12 or later for Wi-Fi Aware; ideally both).
- AirPods Pro 2, AirPods Pro 3 and AirPods 4 (ANC). Measure each model on the same phone pair.
- A laptop with a two-input audio interface, or a third iPhone running a stereo recorder, plus a
  small speaker and a lapel or measurement microphone. Audacity or any waveform editor.
- A restaurant, or a noise recording played through a speaker at 75 to 85 dB(A) measured with a
  phone SPL app.

## Build

The Sotto app's loopback self-test is the measurement build: capture from the AirPods, through the
codec and an in-process link, back to the AirPods. For phone-to-phone numbers use the Wi-Fi Aware
and BLE builds once phase 2 lands; the protocol is identical.

## Measurement 1: mouth-to-ear latency (the gate)

1. Person A wears AirPods paired to phone A. Place the speaker 10 cm from A's mouth position and
   play a click track: 1 ms click every 2 s.
2. Press the measurement microphone against the outside of B's AirPod (or A's, in loopback).
3. Record the speaker feed on channel 1 and the measurement mic on channel 2.
4. Cross-correlate or measure by eye: the delay between the click on channel 1 and its copy on
   channel 2 is mouth-to-ear latency. Take 20 clicks. Record median and 95th percentile.
5. Repeat after 20 minutes of continuous use; AirPods latency drifts as the link settles.
6. Repeat with Voice Processing off (a build flag) to isolate Apple's processing cost.

Gate: median ≤ 250 ms, 95th percentile ≤ 350 ms over Wi-Fi Aware.

## Measurement 2: per-hop breakdown

The app logs monotonic timestamps at capture, encode, send, receive, decode and render for every
packet, plus the ping/pong clock offset (`LatencyEstimator`). Export the CSV from the app's
measurement screen. The difference between total (measurement 1) and the app's own capture-to-render
span is the sum of the two AirPods Bluetooth hops. That number decides whether there is anything we
can do about latency in software.

## Measurement 3: direct-path audibility

Sit A and B across a restaurant table. B wears AirPods with ANC on and the app running. A speaks at
normal level. B rates on a five-point scale whether they hear A twice (direct plus app), and whether
the direct copy is intelligible on its own. Repeat at three noise levels: quiet room, 70 dB(A), 80
dB(A). We expect the double arrival to vanish above ~75 dB(A); that is the environment the product
is for.

## Measurement 4: route and codec facts

From the app's route summary (shown on the conversation screen): input port type, sample rate
reported by the session, whether the route stays `bluetoothHFP` when a Mac is nearby with automatic
switching on. Note which AirPods model reports 24 000 Hz and which falls back to 16 000 Hz.

## Measurement 5: Conversation Awareness and Adaptive Audio

Leave Conversation Awareness on. A speaks; does B's app audio duck? Leave Adaptive Audio on in a
loud room; does the wearer's mode flap between ANC and Transparency? Record yes/no per model. This
decides how prominent the AirPods checklist card must be.

## Measurement 6: link behaviour (phase 2 builds)

- Wi-Fi Aware: jitter statistics from the app (target buffer, concealed, accelerated, expanded) over
  a 30-minute session, in a quiet room and in a cabin or crowded room. Also the performance report
  the link logs (signal strength, interactive-voice transmit latency).
- BLE L2CAP with both AirPods links active: the same statistics, plus dropped sender frames. Expect
  stalls; record how long and how often.
- Airplane Mode with Wi-Fi off: confirm the BLE path connects and how long pairing takes.

## Measurement 7: battery

Start both phones at a known percentage, run a 90-minute session on each transport, note the drain.
Compare with a 90-minute FaceTime audio call as the baseline.

## Reporting

One table per measurement, one row per AirPods model. Put the raw CSVs alongside. Finish with a
plain go/no-go against the gate and the two numbers the plan cares about: typical mouth-to-ear
latency, and the noise level at which the direct path stops being audible.
