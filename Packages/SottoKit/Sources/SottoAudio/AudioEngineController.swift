#if canImport(AVFAudio)
import Foundation
import AVFAudio
import SottoCore

/// Owns the AVAudioEngine graph: AirPods (HFP) microphone in, voice processing on, and a
/// pull-based output fed from `PCMRingBuffer`. Produces 20 ms mono Int16 frames at the
/// configured sample rate via `onCaptureFrame`.
///
/// Device-only. Compiles on macOS for CI; behaviour has NOT yet been verified on hardware
/// (see docs/PLAN.md phase 0). Session configuration lives in `AudioSessionConfigurator`.
public final class AudioEngineController: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var sampleRate: Double = 24000
        public var frameDurationMilliseconds: Int = 20
        public var voiceProcessing = true
        public var automaticGainControl = true
        /// Output ring holds this many milliseconds before overwriting.
        public var outputRingMilliseconds = 400
        public init() {}
        public var samplesPerFrame: Int { Int(sampleRate) * frameDurationMilliseconds / 1000 }
    }

    public let configuration: Configuration
    public let outputRing: PCMRingBuffer
    /// Called on the audio tap queue with exactly `samplesPerFrame` samples. Keep it cheap: hand off to an actor.
    public var onCaptureFrame: (@Sendable (PCMFrame) -> Void)?

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var converter: AVAudioConverter?
    private var pending: [Int16] = []
    private let pendingLock = NSLock()
    private var scratch: UnsafeMutableBufferPointer<Int16>
    public private(set) var isRunning = false

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.outputRing = PCMRingBuffer(capacity: Int(configuration.sampleRate) * configuration.outputRingMilliseconds / 1000)
        self.scratch = .allocate(capacity: 4096)
    }

    deinit { scratch.deallocate() }

    public var targetFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: configuration.sampleRate, channels: 1, interleaved: true)!
    }

    public func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let output = engine.outputNode
        let mixer = engine.mainMixerNode

        // Playback graph first, then voice processing (Apple's own ordering advice).
        let renderFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: configuration.sampleRate, channels: 1, interleaved: false)!
        let ring = outputRing
        let source = AVAudioSourceNode(format: renderFormat) { [scratch] _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let out = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let n = Int(frameCount)
            let chunk = UnsafeMutableBufferPointer(start: scratch.baseAddress, count: min(n, scratch.count))
            ring.read(into: chunk)
            for i in 0..<n { out[i] = i < chunk.count ? Float(chunk[i]) / 32768 : 0 }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: mixer, format: renderFormat)
        engine.connect(mixer, to: output, format: nil)
        sourceNode = source

        if configuration.voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingAGCEnabled = configuration.automaticGainControl
            if #available(iOS 17.0, macOS 14.0, *) {
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .default)
            }
        }

        let hardwareFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: hardwareFormat, to: targetFormat)
        let frameSamples = configuration.samplesPerFrame
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(max(256, frameSamples / 2)), format: hardwareFormat) { [weak self] buffer, _ in
            self?.handleCapture(buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let s = sourceNode { engine.detach(s) }
        sourceNode = nil
        converter = nil
        outputRing.clear()
        isRunning = false
    }

    /// Call when the audio route changed so the input converter matches the new hardware format.
    public func routeDidChange() {
        guard isRunning else { return }
        stop()
        try? start()
    }

    private func handleCapture(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = configuration.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let data = out.int16ChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        var frames: [PCMFrame] = []
        pendingLock.lock()
        pending.append(contentsOf: samples)
        let n = configuration.samplesPerFrame
        while pending.count >= n {
            frames.append(Array(pending[0..<n]))
            pending.removeFirst(n)
        }
        pendingLock.unlock()
        for f in frames { onCaptureFrame?(f) }
    }
}

#if os(iOS)
/// AVAudioSession policy for the conversation. See ADR-0003.
public enum AudioSessionConfigurator {
    public static func configureForConversation(preferredSampleRate: Double = 24000, ioBufferDuration: TimeInterval = 0.01) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try session.setPreferredSampleRate(preferredSampleRate)
        try session.setPreferredIOBufferDuration(ioBufferDuration)
    }

    public static func activate() throws {
        try AVAudioSession.sharedInstance().setActive(true, options: [])
    }

    public static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// True when the current input is a Bluetooth HFP port (the AirPods microphone path).
    public static var inputIsBluetoothHFP: Bool {
        AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
    }

    public static var currentRouteSummary: String {
        let r = AVAudioSession.sharedInstance().currentRoute
        let ins = r.inputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        let outs = r.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        return "in: \(ins) | out: \(outs) | rate: \(AVAudioSession.sharedInstance().sampleRate)"
    }
}
#endif
#endif
