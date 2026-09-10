import Foundation

/// Nanoseconds from an arbitrary monotonic origin. Used for timestamps in latency probes and
/// jitter measurement. Never compare values across devices without an offset estimate.
public enum MonotonicClock {
    public static func now() -> UInt64 {
        let t = DispatchTime.now().uptimeNanoseconds
        return t
    }
}
