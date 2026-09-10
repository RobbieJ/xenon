# Research: phone-to-phone transport for a full-duplex AirPods-to-AirPods voice link (iOS 26/27)

*Research date: 10 September 2026. Sources are linked inline. Confidence levels are the researcher's own.*

Scope note on what the payload actually needs: a full-duplex Opus voice stream at 16–24 kbps with 20 ms frames is ~50 packets/s each direction, roughly 60–80 bytes per packet including headers. Every transport below has more than enough raw bandwidth; the discriminating factors are jitter, background behaviour, radio coexistence with the AirPods HFP/eSCO link, pairing UX and battery.

---

## 1. Core Bluetooth BLE L2CAP connection-oriented channels (CBL2CAPChannel)

**Throughput (measured, iPhone-to-iPhone).** Apple's WWDC17 "What's New in Core Bluetooth" claimed 197 kbps for L2CAP + Extended Data Length, and 394 kbps at a 15 ms connection interval (scribd mirror of session 712: https://www.scribd.com/document/425363481/712-Whats-New-in-Core-Bluetooth). Real iPhone-to-iPhone tests posted on the Apple forums came in far lower and were asymmetric: iPhone SE→iPhone 7 ~48 kbps, iPhone 7 Plus→iPhone 7 ~138 kbps, iPhone 7→7 Plus ~82 kbps, iPhone SE→6 ~36 kbps (https://developer.apple.com/forums/thread/89644). Those are 2017-era radios, but I found no newer published iPhone-to-iPhone L2CAP numbers. A 2024/25 thread with an iPhone 16 Pro Max on iOS 18.2 (GATT, 2M PHY, MTU 244, EDL, 15 ms interval) reports 300–600 kbps and inconsistent, vs 1000–1200 kbps for Android on the same peripheral; the Apple engineer (Argun Tekant) confirmed iOS does not artificially cap writes per interval but "may reject or renegotiate connection parameters depending on device state and resource load" because the phone is "not a dedicated Bluetooth device" (https://developer.apple.com/forums/thread/770717). Even the pessimistic 36 kbps figure is above what a 24 kbps Opus stream needs, but with little headroom for FEC/redundancy.

**Connection interval / MTU.** When both ends are iPhones, iOS picks the connection parameters and the app cannot change them (https://devzone.nordicsemi.com/f/nordic-q-a/40597/maximizing-nrf52-ios-ble-throughput-in-both-directions). Apple's Accessory Design Guidelines require intervals of 15 ms minimum in multiples of 15 ms (11.25 ms only for HID) (https://docs.silabs.com/bluetooth/9.1.1/mobile-apps-suitable-connection-parameters/, https://developer.apple.com/library/archive/qa/qa1931/_index.html). Expect the iPhone-iPhone link to sit at 15–30 ms, so one-way transport latency of roughly one to two intervals plus 20 ms codec framing, i.e. on the order of 40–80 ms. That is a design estimate, not a measurement; I found no published iPhone-to-iPhone L2CAP latency figures (low confidence on the exact number, high confidence it is well under the 150 ms conversational threshold). L2CAP SDUs on iOS work up to about 2048 bytes before fragmentation kicks in (https://developer.apple.com/forums/thread/81120). PSMs are always dynamically assigned on iOS and must be exchanged via a GATT characteristic (https://github.com/bluekitchen/CBL2CAPChannel-Demo/blob/master/README.md).

**Background / screen locked.** This is the critical fact: Apple DTS states plainly that an L2CAP channel "will not keep a suspended app active or wake it from suspension"; it is designed for foreground use, and works in the background only if "the app has another legitimate background activity that keeps it unsuspended", explicitly naming audio via AVAudioSession as the example. Using a background mode solely to keep L2CAP alive violates App Review guideline 2.5.4 (https://developer.apple.com/forums/thread/746286). For this app that is fine: a live two-way voice app with `.playAndRecord` and the `audio` background mode is a legitimate always-running audio process, so the L2CAP channel will survive screen lock. State restoration (`bluetooth-central`/`bluetooth-peripheral` + restore identifiers) only relaunches you for GATT events, not L2CAP, so treat it as a reconnection aid, not a transport keep-alive (https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html).

**Airplane Mode.** Airplane Mode disables cellular; Wi-Fi and Bluetooth can be re-enabled and stay on across subsequent toggles (https://support.apple.com/en-mt/HT204234). Core Bluetooth works normally in that state (high confidence; it is the same mechanism AirPods use in flight).

**Coexistence with AirPods.** See section 8. The short version: the BLE link and the AirPods eSCO link share one radio and one band; iOS may renegotiate BLE parameters under load, and eSCO reserves periodic slots.

**Verdict:** Viable and the only option that works with Wi-Fi off. Bandwidth adequate but thin; jitter driven by 15–30 ms intervals; background OK thanks to the audio session. Confidence: high on background/API facts, medium on throughput on current hardware, low on measured latency.

---

## 2. MultipeerConnectivity

**Radios.** Apple's documentation still lists "infrastructure Wi-Fi, peer-to-peer Wi-Fi, and Bluetooth personal area networks" (https://developer.apple.com/tutorials/data/documentation/multipeerconnectivity.md), but Quinn (Apple DTS) is unambiguous: "Multipeer Connectivity hasn't worked over Bluetooth for 10-ish years. On modern systems its peer-to-peer support is based entirely on peer-to-peer Wi-Fi" (AWDL) (https://developer.apple.com/forums/thread/809565). It does work with Wi-Fi on and no access point, since AWDL needs no AP.

**Status.** "My advice is that you not use Multipeer Connectivity for new code. It's not officially deprecated, but I think you should treat it as such" (https://developer.apple.com/forums/thread/772554). TN3213 "Moving from Multipeer Connectivity to Network framework" lists the drawbacks: symmetric-peer-only model, "good latency but poor throughput", no flow control, obsolete UI, built on NSStream (slated for deprecation), always enables peer-to-peer Wi-Fi, and known bugs (https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework, https://developer.apple.com/forums/thread/776069). On iOS 26 there is a documented regression where "the system tears down the AWDL interface before MPC is able to fully establish the connection" when Wi-Fi is on but not associated to an AP, i.e. exactly our scenario (https://developer.apple.com/forums/thread/803339).

**Background.** Same rule as all networking: it runs only while the process runs; suspension kills the session (https://developer.apple.com/forums/thread/715118).

**Latency.** No hard measurements found; the AWDL jitter described in section 3 applies equally, and DTS confirmed "Multipeer Connectivity won't help. It uses the same peer-to-peer Wi-Fi infrastructure" (https://origin-devforums.apple.com/forums/thread/819926).

**Verdict:** Do not use. Confidence: high.

---

## 3. Network.framework peer-to-peer (includePeerToPeer / AWDL)

**Mechanism.** `NWParameters.includePeerToPeer` (or `.peerToPeerIncluded(true)` on the iOS 26 `NetworkListener`/`NetworkBrowser` structured-concurrency API) enables Bonjour over AWDL; it must be set on both listener and browser, and is off by default (https://developer.apple.com/forums/thread/808917?page=2, https://developer.apple.com/videos/play/wwdc2025/250/). Apple's sample is "Building a custom peer-to-peer protocol" (https://developer.apple.com/documentation/network/building-a-custom-peer-to-peer-protocol).

**Throughput / latency.** AWDL raw throughput is hardware-limited (hundreds of Mbps), but the protocol runs in 16 TU (16.4 ms) availability windows inside a 64 TU sequence, with a minimum 8 ms channel-switch cost and a ~13% throughput hit when also attached to an AP (https://ar5iv.labs.arxiv.org/html/1808.03156). The practical consequence reported by a developer streaming video: "30–50 ms of jitter approximately once per second" from AWDL channel hopping, "extremely choppy" until the system elevates the link to realtime mode; DTS answered "No" to whether any API can request that mode, and pointed at iOS 26's `WAPerformanceMode.realtime` in Wi-Fi Aware as the supported route (https://origin-devforums.apple.com/forums/thread/819926). AWDL's periodic hop to the social channels (6 on 2.4 GHz; 44/149 on 5 GHz) is the same thing that causes the well-known rhythmic stutter for Wi-Fi users (https://www.theregister.com/2025/10/23/apple_airdrop_awdl_latency_research/).

**Background.** Works while the process runs; nothing keeps the process alive (https://developer.apple.com/forums/thread/772637). Also an iOS 26 report of AWDL connections failing off-infrastructure on an iPhone 12 mini but not an iPhone 16 Pro, unresolved (thread 808917 above).

**Verdict:** Better than MPC but the jitter is uncontrollable and Apple now steers real-time use to Wi-Fi Aware. Suitable only as a stop-gap. Confidence: high.

---

## 4. Wi-Fi Aware framework (iOS 26+)

**Facts.** Introduced at WWDC25 session 228; the Wi-Fi Alliance NAN standard, encrypted and authenticated at the Wi-Fi layer, coexists with an infrastructure association, no AP required (https://developer.apple.com/videos/play/wwdc2025/228/, https://developer.apple.com/documentation/wifiaware). Device support: iPhone 12 and later, iPad 10th gen / Air 4 / mini 6 / recent Pros; check `WACapabilities.supportedFeatures` at runtime (https://developer.apple.com/forums/thread/787775). Not on macOS 26, no roadmap given (https://developer.apple.com/forums/thread/787701). Apple shipped it worldwide though it was a DMA obligation (https://www.macrumors.com/2025/06/21/ios-26-adding-two-new-wi-fi-features/).

**iPhone-to-iPhone.** Explicitly supported: DeviceDiscoveryUI is the path for "device-to-device and app-to-app use cases", AccessorySetupKit is the path for accessories. The publisher shows `DevicePairingView`, the subscriber shows `DevicePicker`, the system displays a PIN on one phone that is typed on the other, and the resulting `WAPairedDevice` is persisted in Settings → Privacy & Security → Paired Devices, so pairing is a one-time step (session 228; https://developer.apple.com/forums/thread/797170). Declare `WiFiAwareServices` in Info.plist (`_name._udp`, max 15 chars, `Publishable`/`Subscribable`) and the `com.apple.developer.wifi-aware` entitlement (https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.wifi-aware; I could not fetch the page body, so whether it is a self-service capability is medium confidence — the ESP-IDF and community samples build without special approval, which suggests it is).

**Real-time path.** `.wifiAware { $0.performanceMode = .realtime }` plus `.serviceClass(.interactiveVoice)` is the sanctioned low-latency mode; bulk mode is default and power-frugal. Apple warns realtime "can negatively impact battery". `connection.currentPath?.wifiAware?.performance` exposes signal strength, throughput and latency at runtime, which you should log in field tests (session 228).

**Numbers.** No published iPhone-to-iPhone throughput or latency measurements exist yet that I could find (Espressif's August 2026 ESP-to-iPhone guide has none either: https://developer.espressif.com/blog/2026/08/wifi-aware-esp-to-iphone/). Expect tens of Mbps and single-digit to low-tens of ms in realtime mode based on NAN design, but this is unmeasured (low confidence).

**Background.** Quinn: "Connections operate fine in the background as long as your app is executing. However, if your app gets suspended then the connection closes"; idle connections are garbage-collected after "a few minutes"; no state restoration; the audio background mode is the way to stay alive (https://developer.apple.com/forums/thread/787570). Same rule as L2CAP, same solution.

**Airplane Mode.** Uses the Wi-Fi radio with Wi-Fi re-enabled; AirDrop (AWDL) demonstrably works in Airplane Mode with Wi-Fi + BT on and Wi-Fi Aware sits on the same radio and rules (https://support.apple.com/en-mt/HT204234). Not directly verified for Wi-Fi Aware (medium confidence).

**Known bugs.** iOS 26 beta crashes in the sample app, Android interop pairing not persisting, and an unverified report that some devices reported "not supported" on iOS 26.5 and recovered on iOS 27 (https://developer.apple.com/forums/thread/796945, https://developer.apple.com/forums/thread/801280). Always gate on `supportedFeatures`.

**iOS 27 changes.** None found. No WWDC26 session on Wi-Fi Aware or Network framework appears in the WWDC26 catalogues I checked (https://wwdcnotes.com/documentation/wwdc26/, https://developer.apple.com/wwdc26/guides/ios/).

**Verdict:** Strongest candidate. Confidence: high on API/behaviour, low on measured performance.

---

## 5. What's new in iOS 27 / WWDC26 (confirmed vs rumoured)

Confirmed:
- Bluetooth Channel Sounding (session 369): `CBPeripheral.startChannelSoundingSession`, `CBCentralManager.supportsFeatures(.channelSounding)`, NearbyInteraction distance+direction; iPhone models with the N1 chip only; accessory must be Bluetooth 6.3 with mode-0/mode-2; foreground only; iOS throttles it when BT/Wi-Fi is busy (https://developer.apple.com/videos/play/wwdc2026/369/). Irrelevant to transport, and it is not usable phone-to-phone.
- AudioAccessoryKit (iOS 26.4+, EU-limited rollout) lets third-party headphone makers register for automatic switching; iOS 27 adds spatial-audio info (https://www.macobserver.com/news/apple-introduces-audioaccessorykit-for-third-party-headphones-on-iphone/). Not applicable to phone-to-phone.
- Apple's 250-change list mentions "Improved Bluetooth power management", faster AirDrop discovery/transfers, Connectivity Assist for Wi-Fi/cellular handoff (https://www.macrumors.com/2026/06/10/apple-lists-250-changes-ios-27-and-more/). No developer-facing Core Bluetooth or Network framework transport additions.

Not confirmed / rumoured:
- LE Audio/LC3 for third-party apps: community consensus is Apple still has not enabled LE Audio or Auracast even on iPhone 17 (https://discussions.apple.com/thread/256142011). Some blogs claim LC3 use inside AirPods Pro 3; treat as unverified. No Core Bluetooth ISO/LE Audio API exists.
- Bluetooth 6.3 radios in fall-2026 iPhones: reported but unconfirmed at the time of writing (https://www.techbuzz.ai/articles/apple-s-ios-27-adds-bluetooth-6-3-tracking-with-a-catch).
- Wi-Fi Aware on macOS 27: no announcement found.

---

## 6. Bluetooth Classic profiles for third-party apps

Unchanged: there is no public API for HFP, A2DP or SPP. ExternalAccessory only talks to MFi-authenticated accessories (https://developer.apple.com/library/archive/qa/qa1657/_index.html, https://developer.apple.com/forums/thread/734537). The iOS 26.3 DMA changes give third-party headphones AirPods-style pairing/switching via AccessorySetupKit/AudioAccessoryKit, but that is system-level; apps still cannot open a Classic profile themselves (https://www.macrumors.com/2025/12/22/ios-26-3-dma-airpods-pairing/). Phone-to-phone Classic is impossible. Confidence: high.

---

## 7. Battery for a 90-minute session (estimates, not measurements)

No published per-transport mW figures exist for iPhone. Qualitative ordering from Apple's own statements and the AWDL literature:
- BLE L2CAP: lowest incremental cost; the AirPods eSCO call will dominate (a 90-minute AirPods voice call is the baseline for all options).
- Wi-Fi Aware bulk mode: designed low-power; realtime mode: Apple explicitly warns of battery impact (session 228). Expect the Wi-Fi radio to stay awake through the session.
- AWDL (Network framework/MPC): the protocol "sacrificed energy efficiency for more reliable operation" and keeps at least 25% airtime allocated even in low-power state (https://ar5iv.labs.arxiv.org/html/1808.03156).
Rough expectation for a 90-minute session on a recent iPhone: baseline call ~8–12% drain; add roughly 2–4 points for BLE L2CAP and 6–12 points for Wi-Fi Aware realtime. Treat these as planning numbers to validate (low confidence).

---

## 8. Radio coexistence

The iPhone uses a combo 2.4 GHz BT/Wi-Fi chip with hardware coexistence arbitration (the "packet traffic arbitration" mechanisms documented in https://arxiv.org/pdf/2112.05719). Relevant consequences:
- AirPods mic requires HFP/eSCO, which reserves periodic slots and limits codec bitrate (https://discussions.apple.com/thread/256097737). Those reserved slots are taken out of the same 2.4 GHz airtime a BLE L2CAP link needs; iOS may renegotiate the BLE interval when loaded (thread 770717). SCO coexistence losses of up to one third of packets are documented in the cellular/VoLTE case (https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8864548/).
- AWDL/Wi-Fi Aware on 2.4 GHz (channel 6) co-channels with Bluetooth; on 5 GHz (44/149) it does not (https://community.fortinet.com/t5/Blogs/AppleTV-AirPlay-and-AWDL-protocol-with-Wi-Fi-hard-to-diagnose/ba-p/238440). A 5 GHz Wi-Fi Aware link therefore leaves the 2.4 GHz band to the two AirPods eSCO links, which is the strongest coexistence argument for Wi-Fi Aware. You cannot pick the band directly; verify via the performance report.
- Both phones also each carry their own AirPods link, so the restaurant scenario has four BT audio links plus one phone-to-phone link within a few metres.

---

## Ranked recommendation

**(a) Primary: Wi-Fi Aware over UDP, `performanceMode = .realtime`, `serviceClass(.interactiveVoice)`, kept alive by the `audio` background mode.** Reasons: it is the only Apple-sanctioned low-latency P2P mode (DTS explicitly redirects realtime AWDL requests to it); bandwidth headroom allows a higher-quality Opus profile plus FEC; link-layer encryption and a one-time PIN pairing UX come free; it moves phone-to-phone traffic off the 2.4 GHz band that the AirPods eSCO links need; it works with no AP and in Airplane Mode with Wi-Fi re-enabled. Costs: iPhone 12+/iOS 26+ only, higher battery than BLE, no measured performance data yet, and a young framework with iOS 26.x bugs. Gate on `WACapabilities.supportedFeatures` and log `currentPath.wifiAware.performance`.

**(b) Fallback: Core Bluetooth L2CAP CoC (dynamic PSM exchanged over GATT), Opus at 16–24 kbps, 20 ms frames, same audio background mode.** Reasons: works on every iOS 26 device (covers iPhone 11), works when Wi-Fi is off or disallowed, lowest power, and even the worst measured iPhone-to-iPhone figure (36 kbps) carries the stream. Costs: 15–30 ms iOS-controlled intervals, same-radio contention with two eSCO links, tiny headroom for redundancy, no encryption unless you add it (use `publishL2CAPChannel(withEncryption: true)` plus your own key exchange).

**Not recommended:** MultipeerConnectivity (treat as deprecated; iOS 26 AWDL teardown regression in exactly the no-AP case) and raw Network.framework AWDL (uncontrollable ~30–50 ms/sec jitter, no realtime API). If you need an interim path before Wi-Fi Aware is field-proven, Network.framework AWDL with the `.interactiveVoice` service class is the only acceptable third option.

Both chosen transports share the same architectural requirement: the app must be a genuine always-running audio process, which this app is, so neither Core Bluetooth state restoration nor any special networking background mode is needed or available.
