import AppKit
import CHIDEvent
import TouchCore

/// Carries out the engine's actions by posting the same events a Magic Trackpad produces.
///
/// Pointer, click and scroll events use public CoreGraphics API. Pinch, rotate and the Dock swipes
/// (Mission Control, Spaces) have no public way to be created, so those are assembled field by
/// field in the layout macOS itself uses. That layout is undocumented and can change between
/// macOS versions; everything that depends on it lives in this file.
final class EventSynth {
    // MARK: Undocumented event layout

    private enum EventType {
        static let gesture = CGEventType(rawValue: 29)!
        static let dockControl = CGEventType(rawValue: 30)!
    }

    /// CGEvent field numbers that have no public names.
    private enum Field {
        static let gestureSubtype = CGEventField(rawValue: 110)!
        static let gesturePhase = CGEventField(rawValue: 132)!
        static let magnification = CGEventField(rawValue: 113)!
        static let rotation = CGEventField(rawValue: 114)!
        static let gestureScrollX = CGEventField(rawValue: 116)!
        static let gestureScrollY = CGEventField(rawValue: 119)!
        static let scrollInvertedFromDevice = CGEventField(rawValue: 137)!
    }

    /// IOHIDEvent types, from IOHIDFamily's IOHIDEventTypes.h.
    private enum HIDType {
        static let rotation: UInt32 = 5
        static let scroll: UInt32 = 6
        static let zoom: UInt32 = 8
        static let zoomToggle: UInt32 = 22
        static let velocity: UInt32 = 9
        static let dockSwipe: UInt32 = 23
    }

    private enum HIDField {
        static let dockSwipeMotion = HIDType.dockSwipe << 16 | 1
        static let dockSwipeProgress = HIDType.dockSwipe << 16 | 2
        static let dockSwipeFlavor = HIDType.dockSwipe << 16 | 5
        static let velocityX = HIDType.velocity << 16 | 0
        static let velocityY = HIDType.velocity << 16 | 1
        static let dockFlavorPrimary = 3
        static let phaseShift: UInt32 = 24
    }

    private static func hidPhase(_ phase: Phase) -> Int64 {
        switch phase {
        case .began: return 1
        case .changed: return 2
        case .ended: return 4
        case .cancelled: return 8
        case .mayBegin: return 128
        }
    }

    /// Attaches a low-level HID event to a CGEvent. Lives in the private SkyLight framework.
    private static let attachHIDEvent: (@convention(c) (CGEvent, CFTypeRef) -> Void)? = {
        guard let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let symbol = dlsym(skylight, "SLEventSetIOHIDEvent") else {
            Log.write("SLEventSetIOHIDEvent is missing; Mission Control and Spaces swipes will not work")
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) (CGEvent, CFTypeRef) -> Void).self)
    }()

    // MARK: State

    private var position = CGPoint.zero
    private var moveRemainder = CGPoint.zero
    private var held: Set<MouseButton> = []
    private var lastDown: (button: MouseButton, time: TimeInterval, at: CGPoint, count: Int64)?
    private var displays: [CGRect] = []

    private var naturalScroll = true
    private var scrollRemainder = Vec.zero
    private var momentum: Momentum?
    private var swipeOffset = 0.0
    private var swipeResend: [DispatchWorkItem] = []

    init() {
        refreshDisplays()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.refreshDisplays() }
    }

    func perform(_ action: Action) {
        if Log.frames { Log.write("action \(action)") }
        switch action {
        case .touchBegan:
            stopMomentum()
        case .move(let dx, let dy):
            move(dx, dy)
        case .buttonDown(let button):
            press(button)
        case .buttonUp(let button):
            release(button)
        case .click(let button):
            press(button)
            release(button)
        case .scroll(let phase, let dx, let dy, let velocity):
            scroll(phase, Vec(dx, dy), velocity)
        case .magnify(let phase, let delta):
            postGesture(subtype: HIDType.zoom, phase: phase, field: Field.magnification, value: delta)
        case .rotate(let phase, let degrees):
            postGesture(subtype: HIDType.rotation, phase: phase, field: Field.rotation, value: degrees)
        case .smartZoom:
            guard let event = CGEvent(source: nil) else { return }
            event.type = EventType.gesture
            event.setIntegerValueField(Field.gestureSubtype, value: Int64(HIDType.zoomToggle))
            event.post(tap: .cgSessionEventTap)
        case .lookUp:
            lookUp()
        case .swipe(let axis, let phase, let delta, let velocity):
            swipe(axis, phase, delta, velocity)
        }
    }

    // MARK: Pointer

    private func refreshDisplays() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        displays = ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    private func clamp(_ point: CGPoint, from old: CGPoint) -> CGPoint {
        func inside(_ r: CGRect, _ p: CGPoint) -> Bool {
            p.x >= r.minX && p.x <= r.maxX - 1 && p.y >= r.minY && p.y <= r.maxY - 1
        }
        if displays.contains(where: { inside($0, point) }) { return point }
        guard let home = displays.first(where: { inside($0, old) }) ?? displays.first else { return point }
        return CGPoint(x: min(max(point.x, home.minX), home.maxX - 1),
                       y: min(max(point.y, home.minY), home.maxY - 1))
    }

    private func currentFlags() -> CGEventFlags {
        CGEventSource.flagsState(.combinedSessionState)
    }

    private func syncPosition() {
        guard let actual = CGEvent(source: nil)?.location else { return }
        // Something else moved the cursor (another mouse, an app): start from where it really is.
        if abs(actual.x - position.x) > 1.5 || abs(actual.y - position.y) > 1.5 { position = actual }
    }

    private func move(_ dx: Double, _ dy: Double) {
        syncPosition()
        let target = clamp(CGPoint(x: position.x + dx, y: position.y + dy), from: position)
        position = target

        let type: CGEventType, button: CGMouseButton
        if held.contains(.left) { (type, button) = (.leftMouseDragged, .left) }
        else if held.contains(.right) { (type, button) = (.rightMouseDragged, .right) }
        else if held.contains(.middle) { (type, button) = (.otherMouseDragged, .center) }
        else { (type, button) = (.mouseMoved, .left) }

        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: target, mouseButton: button) else { return }
        moveRemainder.x += dx
        moveRemainder.y += dy
        let whole = CGPoint(x: moveRemainder.x.rounded(.towardZero), y: moveRemainder.y.rounded(.towardZero))
        moveRemainder.x -= whole.x
        moveRemainder.y -= whole.y
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(whole.x))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(whole.y))
        event.flags = currentFlags()
        event.post(tap: .cghidEventTap)
    }

    private func press(_ button: MouseButton) {
        guard !held.contains(button) else { return }
        syncPosition()
        let now = ProcessInfo.processInfo.systemUptime
        var count: Int64 = 1
        if let last = lastDown, last.button == button, now - last.time < NSEvent.doubleClickInterval,
           abs(last.at.x - position.x) < 4, abs(last.at.y - position.y) < 4 {
            count = last.count + 1
        }
        lastDown = (button, now, position, count)
        held.insert(button)
        postButton(button, down: true, clickCount: count)
    }

    private func release(_ button: MouseButton) {
        guard held.remove(button) != nil else { return }
        syncPosition()
        postButton(button, down: false, clickCount: lastDown?.button == button ? lastDown!.count : 1)
    }

    private func postButton(_ button: MouseButton, down: Bool, clickCount: Int64) {
        let type: CGEventType, cgButton: CGMouseButton
        switch button {
        case .left: (type, cgButton) = (down ? .leftMouseDown : .leftMouseUp, .left)
        case .right: (type, cgButton) = (down ? .rightMouseDown : .rightMouseUp, .right)
        case .middle: (type, cgButton) = (down ? .otherMouseDown : .otherMouseUp, .center)
        }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: position, mouseButton: cgButton) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event.flags = currentFlags()
        event.post(tap: .cghidEventTap)
    }

    // MARK: Scrolling

    private func scroll(_ phase: Phase, _ delta: Vec, _ velocity: Vec) {
        if phase == .mayBegin || phase == .began {
            naturalScroll = CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString,
                                                      kCFPreferencesAnyApplication) as? Bool ?? true
            scrollRemainder = .zero
        }
        postScroll(points: wholePoints(delta), phase: Self.hidPhase(phase), momentumPhase: 0)
        if phase == .ended { startMomentum(velocity) }
    }

    /// Scroll events carry whole points; the fraction is kept for the next event.
    private func wholePoints(_ delta: Vec) -> Vec {
        scrollRemainder += delta
        let whole = Vec(scrollRemainder.x.rounded(.towardZero), scrollRemainder.y.rounded(.towardZero))
        scrollRemainder = scrollRemainder - whole
        return whole
    }

    /// `points` follows the fingers (x right, y down).
    private func postScroll(points: Vec, phase: Int64, momentumPhase: Int64) {
        let sign = naturalScroll ? 1.0 : -1.0
        let p = points * sign
        guard let event = CGEvent(source: nil) else { return }
        event.type = .scrollWheel
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(Field.scrollInvertedFromDevice, value: naturalScroll ? 1 : 0)

        func lines(_ points: Double) -> (exact: Double, whole: Int64) {
            let exact = points / 10
            let whole = abs(exact) <= 1 ? exact.rounded(.awayFromZero) : exact.rounded(.towardZero)
            return (exact, Int64(whole))
        }
        let ly = lines(p.y), lx = lines(p.x)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: ly.whole)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(p.y))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: ly.exact)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: lx.whole)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(p.x))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: lx.exact)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        event.flags = currentFlags()
        event.post(tap: .cgSessionEventTap)

        // A real trackpad pairs each finger-driven scroll with a gesture event. Apps use it for
        // swiping between pages.
        guard phase != 0, let gesture = CGEvent(source: nil) else { return }
        gesture.type = EventType.gesture
        gesture.setIntegerValueField(Field.gestureSubtype, value: Int64(HIDType.scroll))
        gesture.setDoubleValueField(Field.gestureScrollX, value: p.x * 1.67)
        gesture.setDoubleValueField(Field.gestureScrollY, value: p.y * 1.67)
        gesture.setIntegerValueField(Field.gesturePhase, value: phase)
        gesture.post(tap: .cgSessionEventTap)
    }

    // MARK: Momentum

    private final class Momentum {
        let curve: MomentumCurve
        let direction: Vec
        let start = ProcessInfo.processInfo.systemUptime
        var travelled = 0.0
        var began = false
        let timer = DispatchSource.makeTimerSource(queue: .main)
        init(velocity: Vec) {
            curve = MomentumCurve(initialSpeed: velocity.length)
            direction = velocity * (1 / velocity.length)
        }
    }

    private func startMomentum(_ velocity: Vec) {
        guard velocity.length >= MomentumCurve.minimumStartSpeed else { return }
        let m = Momentum(velocity: velocity)
        momentum = m
        scrollRemainder = .zero
        m.timer.schedule(deadline: .now() + 1.0 / 120, repeating: 1.0 / 120)
        m.timer.setEventHandler { [weak self] in self?.momentumTick() }
        m.timer.resume()
    }

    private func momentumTick() {
        guard let m = momentum else { return }
        let t = ProcessInfo.processInfo.systemUptime - m.start
        if t >= m.curve.duration {
            stopMomentum()
            return
        }
        let distance = m.curve.distance(at: t)
        let step = wholePoints(m.direction * (distance - m.travelled))
        m.travelled = distance
        guard step != .zero else { return }
        postScroll(points: step, phase: 0, momentumPhase: m.began ? 2 : 1)
        m.began = true
    }

    private func stopMomentum() {
        guard let m = momentum else { return }
        m.timer.cancel()
        momentum = nil
        if m.began { postScroll(points: .zero, phase: 0, momentumPhase: 3) }
    }

    /// Control-Command-D is the system shortcut for "look up the word under the pointer".
    private func lookUp() {
        let keyD: CGKeyCode = 2
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyD, keyDown: down) else { return }
            event.flags = [.maskControl, .maskCommand]
            event.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: Pinch and rotate

    private func postGesture(subtype: UInt32, phase: Phase, field: CGEventField, value: Double) {
        guard let event = CGEvent(source: nil) else { return }
        event.type = EventType.gesture
        event.setIntegerValueField(Field.gestureSubtype, value: Int64(subtype))
        event.setIntegerValueField(Field.gesturePhase, value: Self.hidPhase(phase))
        event.setDoubleValueField(field, value: value)
        event.post(tap: .cgSessionEventTap)
    }

    // MARK: Mission Control and Spaces

    /// Sign that makes "fingers right" and "fingers down" match what a Magic Trackpad sends.
    static let swipeSign = -1.0
    /// Same, for four fingers spreading apart.
    static let spreadSign = 1.0

    private func swipe(_ axis: SwipeAxis, _ phase: Phase, _ delta: Double, _ velocity: Double) {
        swipeResend.forEach { $0.cancel() }
        swipeResend = []

        var phase = phase
        if phase == .began { swipeOffset = 0 }
        let sign = axis == .pinch ? Self.spreadSign : Self.swipeSign
        swipeOffset += delta * sign
        let exitVelocity = velocity * sign
        // Let go while moving back toward where the swipe started: treat it as changing one's mind.
        if phase == .ended, exitVelocity != 0, (exitVelocity < 0) != (swipeOffset < 0) { phase = .cancelled }

        let options = UInt32(Self.hidPhase(phase)) << HIDField.phaseShift
        let hid = IOHIDEventCreate(kCFAllocatorDefault, HIDType.dockSwipe, 0, options)
        let motion: [SwipeAxis: Int] = [.horizontal: 1, .vertical: 2, .pinch: 3]
        IOHIDEventSetIntegerValue(hid, HIDField.dockSwipeMotion, motion[axis]!)
        IOHIDEventSetIntegerValue(hid, HIDField.dockSwipeFlavor, HIDField.dockFlavorPrimary)
        IOHIDEventSetFloatValue(hid, HIDField.dockSwipeProgress, swipeOffset)
        if phase == .ended || phase == .cancelled {
            let child = IOHIDEventCreate(kCFAllocatorDefault, HIDType.velocity, 0, 0)
            IOHIDEventSetFloatValue(child, HIDField.velocityX, exitVelocity)
            IOHIDEventSetFloatValue(child, HIDField.velocityY, exitVelocity)
            IOHIDEventAppendEvent(hid, child, 0)
        }

        guard let attach = Self.attachHIDEvent, let event = CGEvent(source: nil) else { return }
        event.type = EventType.dockControl
        attach(event, hid)
        event.post(tap: .cgSessionEventTap)

        // The Dock occasionally misses the end of a swipe and leaves the screen half way.
        // Repeating the final event is harmless and unsticks it.
        if phase == .ended || phase == .cancelled {
            for delay in [0.2, 0.5] {
                let item = DispatchWorkItem { event.post(tap: .cgSessionEventTap) }
                swipeResend.append(item)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            }
        }
    }
}
