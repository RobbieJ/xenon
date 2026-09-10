import Foundation

/// RMS level in dBFS and a simple energy voice-activity detector with hangover.
public struct LevelMeter: Sendable {
    public var thresholdDBFS: Double
    public var hangoverFrames: Int
    private var hangover = 0
    public private(set) var lastLevelDBFS: Double = -120
    public private(set) var isActive = false

    public init(thresholdDBFS: Double = -45, hangoverFrames: Int = 8) {
        self.thresholdDBFS = thresholdDBFS
        self.hangoverFrames = hangoverFrames
    }

    public static func rmsDBFS(_ frame: PCMFrame) -> Double {
        guard !frame.isEmpty else { return -120 }
        var acc = 0.0
        for s in frame { let v = Double(s) / 32768.0; acc += v * v }
        let rms = (acc / Double(frame.count)).squareRoot()
        return rms > 0 ? max(-120, 20 * log10(rms)) : -120
    }

    /// Feed one frame; returns whether voice is considered active after this frame.
    @discardableResult
    public mutating func process(_ frame: PCMFrame) -> Bool {
        lastLevelDBFS = Self.rmsDBFS(frame)
        if lastLevelDBFS >= thresholdDBFS {
            hangover = hangoverFrames
            isActive = true
        } else if hangover > 0 {
            hangover -= 1
            isActive = true
        } else {
            isActive = false
        }
        return isActive
    }
}
