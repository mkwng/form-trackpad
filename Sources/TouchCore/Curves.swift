import Foundation

public enum Curves {
    static func smoothstep(_ t: Double) -> Double {
        let c = min(max(t, 0), 1)
        return c * c * (3 - 2 * c)
    }

    /// Screen points per millimetre of finger travel, as a function of finger speed (mm/s).
    /// Slow fingers get fine control; fast flicks cross the screen.
    public static func pointerGain(speed: Double, setting: Double) -> Double {
        let slow = 4.5, fast = 26.0
        return (slow + (fast - slow) * smoothstep((speed - 8) / 300)) * setting
    }

    public static func scrollGain(speed: Double, setting: Double) -> Double {
        let slow = 7.0, fast = 26.0
        return (slow + (fast - slow) * smoothstep((speed - 15) / 250)) * setting
    }
}

/// Coasting after a scroll: speed decays as dv/dt = -k·v^p, which matches how a real trackpad
/// glides (fast flicks travel far, slow ones stop quickly).
public struct MomentumCurve {
    public let initialSpeed: Double
    static let k = 30.0
    static let p = 0.7
    public static let stopSpeed = 12.0
    public static let minimumStartSpeed = 60.0

    public init(initialSpeed: Double) { self.initialSpeed = initialSpeed }

    public func speed(at t: Double) -> Double {
        let q = 1 - Self.p
        let base = pow(initialSpeed, q) - Self.k * q * t
        return base <= 0 ? 0 : pow(base, 1 / q)
    }

    /// Distance covered from the start until time `t`.
    public func distance(at t: Double) -> Double {
        let r = 2 - Self.p
        return (pow(initialSpeed, r) - pow(speed(at: t), r)) / (Self.k * r)
    }

    public var duration: Double {
        let q = 1 - Self.p
        return (pow(initialSpeed, q) - pow(Self.stopSpeed, q)) / (Self.k * q)
    }
}
