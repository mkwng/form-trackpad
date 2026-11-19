import Foundation

public struct Vec: Equatable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let zero = Vec(0, 0)
    public var length: Double { (x * x + y * y).squareRoot() }
    public static func + (a: Vec, b: Vec) -> Vec { Vec(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec, b: Vec) -> Vec { Vec(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec, s: Double) -> Vec { Vec(a.x * s, a.y * s) }
    public static func += (a: inout Vec, b: Vec) { a = a + b }
}

/// One finger in one report. Position is in millimetres from the pad's top-left corner.
public struct Contact: Equatable {
    public var id: Int
    public var position: Vec
    public var touching: Bool
    /// False when the pad itself thinks this is a palm.
    public var confident: Bool
    public init(id: Int, position: Vec, touching: Bool = true, confident: Bool = true) {
        self.id = id; self.position = position; self.touching = touching; self.confident = confident
    }
}

public struct Frame: Equatable {
    /// Seconds on a monotonic clock.
    public var time: Double
    public var contacts: [Contact]
    /// Physical button bits (bit 0 = left, 1 = right, 2 = middle).
    public var buttons: UInt8
    public init(time: Double, contacts: [Contact], buttons: UInt8 = 0) {
        self.time = time; self.contacts = contacts; self.buttons = buttons
    }
}

public enum Phase: Equatable { case mayBegin, began, changed, ended, cancelled }
public enum MouseButton: Equatable, CaseIterable { case left, right, middle }
public enum SwipeAxis: Equatable { case horizontal, vertical }

/// What the engine wants done. Distances are in screen points; x grows right and y grows down,
/// following the fingers.
public enum Action: Equatable {
    /// A finger landed. Stops any coasting scroll.
    case touchBegan
    case move(dx: Double, dy: Double)
    case buttonDown(MouseButton)
    case buttonUp(MouseButton)
    case click(MouseButton)
    /// `velocity` (points per second) is only meaningful on `.ended`, where it seeds momentum.
    case scroll(phase: Phase, dx: Double, dy: Double, velocity: Vec)
    /// `delta` is the fraction to zoom by; +1.0 over a gesture roughly doubles.
    case magnify(phase: Phase, delta: Double)
    /// Degrees, counterclockwise positive.
    case rotate(phase: Phase, degrees: Double)
    /// `delta` is progress, where 1.0 is a full swipe. Positive is fingers moving right or down.
    /// `velocity` is progress per second, meaningful on `.ended`.
    case swipe(axis: SwipeAxis, phase: Phase, delta: Double, velocity: Double)
}

public struct Tuning: Equatable {
    public var pointerSpeed = 1.0
    public var scrollSpeed = 1.0

    public var tapMaxDuration = 0.22
    /// How far (mm) a finger may wander and still count as a tap.
    public var tapSlop = 1.3
    /// After a tap, a new touch inside this window can turn into a drag or a double click.
    public var tapDragWindow = 0.30
    /// After lifting during a drag, the button stays down this long so the finger can reposition.
    public var dragReleaseDelay = 0.25
    /// Touches that land this soon after a keystroke are treated as accidental for a moment.
    public var typingGuard = 0.30

    public var scrollStart = 0.7
    public var pinchStart = 2.0
    public var rotateStart = 2.5
    public var swipeStart = 2.5
    /// Millimetres of finger spread that count as a magnification of 1.0.
    public var pinchScale = 45.0
    /// Millimetres of travel that count as one full swipe.
    public var swipeScale = 55.0

    public init() {}
}
