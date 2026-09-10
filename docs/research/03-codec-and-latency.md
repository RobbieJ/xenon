# Research: codec, packetisation, jitter buffer and mouth-to-ear latency budget

*Research date: 10 September 2026. Target iOS 27 (minimum iOS 26). Sources are linked inline. The researcher's web-search budget was exhausted near the end, so a few items (notably LE Audio status and BLE/HFP radio coexistence) rest on fewer sources and are flagged with lower confidence.*

## 1. Codec choice for a 30-100 kbps BLE link

| Codec | Useful rate (mono speech) | Algorithmic delay | CPU (phone-class) | Loss tools | Licence | Verdict |
|---|---|---|---|---|---|---|
| Opus (SILK/hybrid, VoIP mode) | 16-20 kbps WB, 24-32 kbps SWB/FB ([RFC 6716](https://www.rfc-editor.org/rfc/rfc6716)) | 20 ms frame + 5 ms SILK look-ahead + up to 1.5 ms resampling = ~26.5 ms; CELT-only 22.5 ms; RESTRICTED_LOWDELAY down to 5 ms (RFC 6716; [Hydrogenaudio](https://wiki.hydrogenaudio.org/index.php?title=Opus)) | ~30 MFLOPS float at 44.1 kHz for enc+dec (Hydrogenaudio) — well under 5% of one A-series core at complexity 10 | In-band FEC (LBRR), PLC, Deep PLC (~1% core), DRED, LACE/NoLACE post-filter (100-400 MFLOPS) ([Opus 1.5](https://opus-codec.org/demo/opus-1.5/)) | BSD-3 + royalty-free patent grant | Recommended |
| LC3 | 16-32 kbps WB; 24 kbps 10 ms ≈ CVSD/mSBC quality; 32 kbps ≈ SBC 66 kbps ([Bluetooth SIG LC3 characterisation WP](https://www.bluetooth.com/wp-content/uploads/2023/07/LC3Characterization_WP.pdf)) | 7.5 or 10 ms frames; ~2.5 ms look-ahead, i.e. ~10-12.5 ms ([Bluetooth SIG overview](https://www.bluetooth.com/blog/a-technical-overview-of-lc3/)); GMAP system delay "close to 30 ms" | Lower than Opus; encoder ≈ 2/3, decoder ≈ 1/3 of total (WP) | Spec PLC is weak ("FhG Adv PLC" significantly better at all loss rates in the WP's P.800 test) | Spec is SIG-licensed; liblc3 (Google) Apache-2.0 | Good latency, but no Apple API and the LC3-vs-Opus quality claim used Opus 1.1.4 at complexity 0 ([HN discussion](https://news.ycombinator.com/item?id=21982964)) |
| AAC-ELD (+SBR) | Fraunhofer recommends 32-64 kbps mono; SBR recommended at ≤48 kbps ([Fraunhofer AAC-ELD on iOS](https://www.iis.fraunhofer.de/content/dam/iis/de/doc/ame/wp/FraunhoferIIS_Application-Bulletin_AAC-ELD-on-iOS.pdf)) | ~15 ms core at 48 kHz per the Opus AES paper ([Valin et al.](https://jmvalin.ca/papers/aes135_opus_celt.pdf)); 512-sample frames on iOS | Low | No FEC; PLC is implementation-defined and not exposed by Apple | Patent-licensed; free to use via Apple's built-in codec | Native on iOS, but too hungry at <32 kbps and no loss tooling |
| Speex | 8-24 kbps | ~30 ms (20 ms frame + 10 ms look-ahead) | Very low | PLC | BSD | Obsolete; Xiph says use Opus |
| Codec 2 | 0.45-3.2 kbps, 8 kHz only ([Wikipedia](https://en.wikipedia.org/wiki/Codec_2)) | 20-40 ms frames | Very low | None | LGPL-2.1 | Radio-quality; only if the link collapses to a few kbps |
| Lyra v2 (ML) | 3.2/6/9.2 kbps ≈ Opus at 10/13/14 kbps; 20 ms frames; 0.57 ms per frame on Pixel 6 Pro ([Google](https://opensource.googleblog.com/2022/09/lyra-v2-a-better-faster-and-more-versatile-speech-codec.html)) | ~20 ms + framing | Moderate (TFLite) | None | Apache-2.0 | Unnecessary at ≥16 kbps; Opus 1.5+ with NoLACE is "perfectly usable down to 6 kb/s" |

Confidence: high for Opus/AAC-ELD/Codec 2/Lyra figures; medium for LC3 delay (the WP gives the GMAP system figure, not a bare algorithmic figure).

## 2. What Apple ships natively

- `kAudioFormatOpus` constant exists since iOS 11 ([Apple docs JSON](https://developer.apple.com/tutorials/data/documentation/coreaudiotypes/kaudioformatopus.json)). An Apple engineer confirmed Opus *decode* is "only supported beginning in iOS 17, and only in MP4 files" for playback ([thread 759210](https://developer.apple.com/forums/thread/759210)). In Dec 2024 an Apple engineer posted a working AVAudioConverter PCM-to-Opus *encoder* example: 48 kHz, mono, `mFramesPerPacket = 960` (20 ms), `bitRateStrategy = Constant`, output in `AVAudioCompressedBuffer` ([thread 763362](https://developer.apple.com/forums/thread/763362)); an earlier 60 ms/2880-frame attempt produced corrupted audio ([thread 127317](https://developer.apple.com/forums/thread/127317)). So: encode and decode exist on iOS 17+ (medium confidence), but only 48 kHz input and 20 ms packets are demonstrated to work.
- Critical restriction: there is no way to signal packet loss or request FEC decoding through AVAudioConverter; passing empty input or nil does not trigger PLC, and the thread is unanswered from 2022 to May 2025 ([thread 699929](https://developer.apple.com/forums/thread/699929)). That alone disqualifies Apple's Opus for a lossy real-time link.
- AAC-ELD: `kAudioFormatMPEG4AAC_ELD` / `_ELD_V2` (with SBR) encode and decode via AudioConverter, in place since iOS 5 era (Fraunhofer bulletin above). High confidence.
- LC3: no public `kAudioFormatLC3` or AudioToolbox LC3 codec was found in any Apple documentation, and AirPods Pro 3 tech specs list only "Bluetooth 5.3" with no LC3/LE Audio ([Apple](https://support.apple.com/en-us/125135)). Apple has not opened LE Audio/Auracast to third parties as of 2025 ([Apple Community](https://discussions.apple.com/thread/256142011)). Medium-low confidence there is nothing new in iOS 26/27; verify in the iOS 27 SDK headers.
- iOS 26 audio-session changes that matter: `allowBluetooth` is deprecated in favour of `allowBluetoothHFP` ([docs](https://developer.apple.com/tutorials/data/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetooth.json)); new `bluetoothHighQualityRecording` gives full-bandwidth AirPods mic capture but "may increase input latency ... isn't recommended for real-time communication" and is unavailable in the EU ([docs](https://developer.apple.com/tutorials/data/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/bluetoothhighqualityrecording.json)). Use HFP.

## 3. Shipping libopus

- Apple's Opus is not good enough (no PLC/FEC control, undocumented frame-size support), so ship libopus. Current release: 1.6 (Dec 2025) / 1.6.1 (Jan 2026), BSD-3-Clause, RFC 6716-compatible ([release notes](https://opus-codec.org/release/stable/2025/12/15/libopus-1_6.html)).
- Options: (a) build your own xcframework from libopus 1.6.1 with CMake for ios-arm64 + ios-arm64-simulator and vend it as an SPM `binaryTarget` (cleanest, lets you pass `--enable-deep-plc`); (b) [sbooth/opus-binary-xcframework](https://github.com/sbooth/opus-binary-xcframework) (SPM binary, iOS 15+, includes opusfile/libopusenc and needs Ogg — heavier than needed); (c) [alta/swift-opus](https://github.com/alta/swift-opus) (BSD-3, Swift API over a libopus submodule, maintenance uncertain). Recommend (a) with a thin Swift wrapper; keep `opus_decode(..., decode_fec)` and `nil`-data PLC paths exposed. Add ~1 MB if Deep PLC is enabled; skip DRED (~2 MB, not needed on a reliable link).

## 4. Mouth-to-ear latency budget

Key evidence: AVAudioSession latency properties are "least reliable with Bluetooth" and real AirPods output latency drifts 193-260 ms in a minute on A2DP ([thread 126277](https://developer.apple.com/forums/thread/126277), [thread 679274](https://developer.apple.com/forums/thread/679274)); switching AirPods to HFP reports `outputLatency` ≈ 9 ms vs ≈ 163 ms on A2DP but a developer measured only ~30 ms real improvement ([Apple Community](https://discussions.apple.com/thread/256097737)); generic HFP/eSCO link delay is quoted around 40 ms; AirPods with Apple hosts use AAC-ELD at 24 kHz + SBR in both directions over the HFP path ([AppleInsider](https://appleinsider.com/articles/22/02/01/apple-quietly-improved-call-audio-quality-on-airpods-pro-airpods-3)); iOS BLE connection intervals are 15 ms multiples (often scaled to 30 ms), and apps cannot set them ([thread 822187](https://developer.apple.com/forums/thread/822187)).

| Stage | Best | Typical | Worst | Notes / confidence |
|---|---|---|---|---|
| A: AirPods mic DSP + AAC-ELD/mSBC encode + eSCO uplink + iPhone BT stack | 25 | 45 | 90 | Medium-low; HFP-class link ~40 ms, Apple's ELD path unmeasured |
| A: iOS input (VPIO with `.voiceChat`, 10-20 ms IO buffer, AEC/NS) | 10 | 25 | 45 | Medium; VPIO "adds latency" but Apple does not quantify |
| A: Opus framing (20 ms) + 6.5 ms look-ahead + encode | 12 (10 ms frames) | 27 | 47 (40 ms) | High |
| A→B: packetise + L2CAP queue + wait for connection event + air time + LL retries | 4 | 20 | 90 | Medium; 15-30 ms interval, plus HFP coexistence stalls |
| B: jitter buffer target | 20 | 40 | 100 | Design choice |
| B: decode/PLC + IO output buffer | 5 | 15 | 30 | High |
| B: iPhone → AirPods HFP downlink (ELD encode, eSCO, AirPods decode + DSP) | 30 | 60 | 150 | Low-medium; the ~30 ms-better-than-A2DP measurement suggests worst case could be much higher |
| Total | ~105 | ~230 | ~550 | |

Against ITU-T G.114 (≤150 ms "essentially transparent", >400 ms "unacceptable" — [ITU](https://www.itu.int/rec/dologin_pub.asp?lang=e&id=T-REC-G.114-200305-I!!PDF-E&type=items)): the typical case sits around 200-250 ms, i.e. clearly usable, slightly "phone-call-like", with two Bluetooth hops (not the codec or BLE) consuming half the budget. Natural turn-taking is achievable; 150 ms is not achievable with AirPods over HFP unless Apple's ELD path is much faster than generic HFP. The two AirPods hops are the item to measure first (see 9). If measurements show >300 ms typical, fall back to iPhone speaker/mic or wired earbuds on one side.

## 5. Jitter buffer and loss concealment

- The link is *reliable* (L2CAP CoC with link-layer retransmission), so "loss" appears as delay spikes and, if you bound the sender queue, as deliberate drops. Design for jitter first, loss second.
- Adopt NetEQ's approach ([WebRTC NetEQ](https://webrtchacks.com/how-webrtcs-neteq-jitter-buffer-provides-smooth-audio/)): histogram of relative arrival delay over a ~2 s window (forget factor 0.983), target = 95th percentile, and per-10 ms decisions among normal / accelerate / pre-emptive expand / expand(PLC) / merge. Typical VoIP targets 80-100 ms; on BLE you should start at 2 frames (40 ms) and clamp to 20-120 ms.
- A lighter alternative to port is speexdsp's `jitter.c` (BSD): cost = delay + late_factor × late frames, 40-entry timing window, handles drift by inserting/dropping whole packets ([source](https://github.com/xiph/speexdsp/blob/master/libspeexdsp/jitter.c)). Mumble uses it and could not add Opus FEC because it cannot peek at the next packet ([Mumble #4519](https://github.com/mumble-voip/mumble/issues/4519)) — design yours to expose N+1 so `opus_decode(..., decode_fec=1)` is possible. Jamulus uses a timing histogram against the audio clock ([issue 545](https://github.com/corrados/jamulus/issues/545)).
- Opus FEC: RFC 7587 notes the decoder recovers frame N from packet N+1's LBRR, so playout must lag one packet (+20 ms) ([RFC 7587](https://www.rfc-editor.org/rfc/rfc7587)). Recommend FEC off by default; enable `OPUS_SET_INBAND_FEC(1)` with `PACKET_LOSS_PERC` 5-10 only when the sender is dropping stale frames.
- Clock drift: two iPhones' audio clocks differ by tens of ppm (50 ppm = 3 ms/min); the AirPods' own clock is hidden by iOS. Handle it in the jitter buffer via accelerate/expand on low-energy frames (NetEQ) or drop/insert of whole frames in silence (speex). Avoid a fractional resampler unless you already have one.
- Sequence numbers: 16-bit seq + 32-bit timestamp in samples; detect reorder (impossible on a stream, but keep it for a future datagram transport), duplicates and gaps.

## 6. Framing over CBL2CAPChannel

- `CBL2CAPChannel` exposes `InputStream`/`OutputStream` ([Apple docs](https://developer.apple.com/tutorials/data/documentation/corebluetooth/cbl2capchannel.json)); SDU boundaries are not surfaced, so treat it as a byte stream and self-frame. Apple devices support SDUs up to 2048 bytes, but throughput and MTU/PHY are auto-negotiated with no app control ([thread 723218](https://developer.apple.com/forums/thread/723218), [thread 774300](https://developer.apple.com/forums/thread/774300)).
- Recommended frame: `magic/version(1) | flags(1) | seq(2) | timestamp(4) | payload_len(2) | Opus packet (40-80 B)` ≈ 60-90 bytes. Fits inside one DLE link-layer PDU (251 B) so a single frame never straddles connection events. One 20 ms Opus frame per packet; never bundle.
- Head-of-line: the stream is FIFO and reliable, so a radio stall delays everything behind it. Bound the sender: if `hasSpaceAvailable` is false for more than one frame, drop the oldest queued frame (and let FEC/PLC cover it). Write each frame in one `write` call; on the receiver, parse incrementally and discard frames whose timestamp is already behind playout.

## 7. Bandwidth

- Per direction at 24 kbps: 60 B Opus + 10 B app header + 4 B L2CAP basic + 2 B CoC SDU length + LL overhead (~10 B incl. MIC) ≈ 86 B/20 ms ≈ 34 kbps; two directions ≈ 70 kbps; at 16 kbps ≈ 55 kbps total.
- Capacity: Apple's WWDC 2017 figures are 197 kbps (L2CAP + DLE) and 394 kbps at 15 ms interval; iPhone-to-iPhone tests reached 47-138 kbps on 2017 hardware ([thread 89644](https://developer.apple.com/forums/thread/89644)), and recent reports give 36-60 KB/s (290-480 kbps) with iPhone as central and ~100 KB/s as peripheral ([thread 723218](https://developer.apple.com/forums/thread/723218)). So 70 kbps is 2-5x inside capacity.
- Coexistence: each iPhone also runs an eSCO link to its AirPods on the same radio; SCO/eSCO reservations "significantly reduce" ACL throughput in Classic BT, and BLE shares the antenna. No iOS-specific measurement was found (low confidence). Plan for connection intervals to be scaled to 30 ms and occasional 100-300 ms stalls; the budget above assumes that. Wi-Fi Aware (iOS 26, iPhone 12+, "high-bandwidth, low-latency", Network framework) is the escape hatch if BLE proves too tight ([Apple](https://developer.apple.com/tutorials/data/documentation/wifiaware.json)).

## 8. Existing projects

- [ST FP-AUD-BVLINK2](https://www.st.com/en/embedded-software/fp-aud-bvlink2.html): full-duplex Opus voice over BLE on STM32 — proof the topology works at BLE rates (ST licence; design reference only).
- WebRTC NetEQ (BSD-3) and the Rust [`neteq` crate](https://lib.rs/crates/neteq): reference jitter buffer; port the delay manager and decision logic.
- speexdsp `jitter.c` (BSD-3): ~700 lines, easy Swift port; Mumble iOS/MumbleKit (BSD) shows Opus + speex jitter buffer in a shipping iOS client, but it is client-server.
- Jamulus (GPL-2+): good jitter ideas, licence unsuitable.
- [bitchat](https://github.com/permissionlesstech/bitchat) (public domain): dual-role CoreBluetooth central+peripheral, GATT with ~469 B fragmentation, Noise encryption — reuse its peer discovery/dual-role pattern and Noise handshake; not audio.
- [paulw11/L2Cap](https://github.com/paulw11/L2Cap) (MIT): minimal CBL2CAPChannel central/peripheral wrapper.
- Talky (PolyForm Noncommercial), RockyTalkie, "Walkie Talkie Offline": Multipeer/peer-to-peer PTT apps; none are full-duplex or open under a permissive licence.
- Signal-iOS bundles libopus via its own pod (GPL app; only the packaging pattern is reusable).

## 9. Test and measurement

- Physical mouth-to-ear: play a repeating click/chirp from a speaker at A's AirPod mic; record simultaneously (a) the speaker feed and (b) a measurement mic pressed to B's AirPod on a two-channel interface; cross-correlate (Android's loopback tool uses noise bursts + normalised correlation, [AOSP](https://source.android.com/docs/core/audio/latency/measure)). Repeat 20-30 min in, since AirPods latency settles over time ([thread 679274](https://developer.apple.com/forums/thread/679274)).
- Per-hop: log host timestamps (`mach_absolute_time`) at capture callback, encode, send, receive, decode, render, and exchange a BLE ping to align the two phones' clocks; that isolates the AirPods hops from the app path. Measure the output hop with a Larsen loopback on one phone (play click to AirPods, record with the built-in mic held to the earbud, subtract the known built-in-mic latency). Do not trust `inputLatency`/`outputLatency` for Bluetooth.
- Automated (no hardware): host-side Swift tests running libopus + jitter buffer against synthetic traces — Gilbert-Elliott loss, Gaussian/Pareto jitter, 30 ms interval quantisation with 4 PDUs/event, 200 ms stalls, ±100 ppm drift — asserting no underruns, playout delay percentiles, conceal/stretch counts, and objective quality via ViSQOL (Apache-2.0) or PESQ in CI. Seed all RNGs.

## Recommendation

- Codec: libopus 1.6.1, `OPUS_APPLICATION_VOIP`, input 16 kHz (HFP route; 24 kHz if iOS reports AirPods at 24 kHz), `OPUS_BANDWIDTH_WIDEBAND`, 20 ms frames, VBR constrained at 20 kbps (floor 12, ceiling 32), complexity 6-8, DTX off initially, FEC off unless sender-side drops occur; decoder with PLC (Deep PLC optional).
- Packet: one Opus frame per `[ver|flags|seq16|ts32|len16]` frame (~10 B header) over CBL2CAPChannel; sender queue bounded at 1 frame.
- Jitter buffer: NetEQ-style histogram (95th percentile, 2 s window), initial target 40 ms, range 20-120 ms, accelerate/expand on low-energy frames for drift, FEC-aware lookahead.
- Audio session: `.playAndRecord`, `.voiceChat`, `[.allowBluetoothHFP]`, preferred IO buffer 10 ms; avoid `bluetoothHighQualityRecording`.
- Expect ~230 ms typical mouth-to-ear (105 best, 550 worst), dominated by the two AirPods HFP hops; measure those first, and keep Wi-Fi Aware (iOS 26) as the bandwidth fallback.
