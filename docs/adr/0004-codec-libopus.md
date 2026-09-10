# ADR-0004: libopus shipped as an xcframework, one 20 ms frame per packet

**Status:** Proposed. **Date:** 2026-09-10.

## Context

See `docs/research/03-codec-and-latency.md`. Apple's AudioToolbox exposes an Opus encoder and decoder from iOS 17, but only 48 kHz input and 20 ms packets are demonstrated to work, and there is no way to signal packet loss, request FEC decoding or trigger concealment. AAC-ELD is native but needs 32 kbps or more and has no loss tooling. LC3 has no Apple API. libopus 1.6.x is BSD-licensed, has in-band FEC, PLC and optional Deep PLC, and costs a few percent of one core.

## Decision

- Build libopus 1.6.x from source with CMake for `ios-arm64` and `ios-arm64-simulator`, vend as a Swift Package binary target, wrap in a small Swift API that exposes `decode_fec` and the nil-data PLC path.
- Encoder: `OPUS_APPLICATION_VOIP`, 24 kHz input where the route reports it (16 kHz otherwise), 20 ms frames, constrained VBR at 20 kbps (floor 12, ceiling 32), complexity 6 to 8, DTX off in v1.
- In-band FEC on with a 5 to 10 % loss hint over Wi-Fi Aware UDP. Off over BLE L2CAP, where the stream is reliable and a bounded sender queue drops stale frames instead.
- Wire format: 10-byte header (version and flags, 16-bit sequence, 32-bit sample timestamp, 16-bit payload length) followed by exactly one Opus frame. Never bundle frames. 60 to 90 bytes per packet, about 35 kbps per direction with overhead.
- Jitter buffer: NetEQ-style arrival-delay histogram, 95th-percentile target, initial 40 ms, clamped 20 to 120 ms, accelerate and expand on low-energy frames for clock drift. Written in Swift in `SottoAudio`, tested against synthetic traces with ViSQOL scoring in CI.

## Consequences

- About 1 MB added to the binary (2 MB more if Deep PLC is enabled; DRED is not needed).
- Full control over loss behaviour and framing on both transports.
- 10 ms frames remain available as a latency lever if phase 0 measurements demand it.
