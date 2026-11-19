import Foundation

/// Turns raw finger frames into pointer, click, scroll and gesture actions.
///
/// Pure logic with no system calls, so it can be driven by recorded or invented frames in tests.
/// Time only moves when the caller passes it in, through `process` or `advance`.
public final class GestureEngine {
    public var tuning: Tuning
    /// Seconds since the last key press. Lets the engine ignore palms that brush the pad mid-typing.
    public var secondsSinceKeystroke: () -> Double = { .infinity }

    public init(tuning: Tuning = Tuning()) { self.tuning = tuning }

    private struct Track {
        let id: Int
        let start: Vec
        var position: Vec
        var previous: Vec
        /// Where this finger was when the current gesture decision started.
        var origin: Vec
        var travel = 0.0
        var palm: Bool
    }

    private enum Mode: Equatable {
        case idle, pending, pointing, dragging
        /// Two fingers doing any mix of scrolling, zooming and rotating.
        case transforming
        case swiping(SwipeAxis)
        /// A multi-finger gesture just ended with fingers still down; ignore them until `until`.
        case settling(until: Double)
    }

    private enum AxisLock { case free, horizontal, vertical }

    private var tracks: [Int: Track] = [:]
    private var mode = Mode.idle
    private var fingerCount = 0
    private var lastTime = 0.0
    private var buttons: UInt8 = 0

    private var sessionStart = 0.0
    private var sessionMaxFingers = 0
    private var sessionMaxTravel = 0.0
    private var sessionGestured = false
    private var sessionSuspect = false
    private var pendingSince = 0.0
    private var scrollMayBegin = false

    /// A tap just happened; a touch that lands before this time may become a drag.
    private var armedUntil: Double?
    private var dragCandidate = false
    /// We are holding the left button after a drag lift, until this time.
    private var dragReleaseAt: Double?
    /// A two-finger tap happened; it becomes a right click at this time unless a second tap
    /// turns the pair into a smart zoom first.
    private var rightClickAt: Double?
    private var lastRadius = 0.0
    private var radiusFingers = 0

    private var gestureStart = 0.0
    private var smoothedSpeed = 0.0
    private var axisLock = AxisLock.free
    private var offAxis = 0.0
    private var samples: [(time: Double, delta: Vec)] = []
    private var lastDistance = 0.0
    private var lastAngle = 0.0

    // Which parts of a two-finger gesture are live. Each starts on its own once the fingers
    // clearly mean it, and then runs alongside the others until the fingers lift.
    private var scrolling = false
    private var zooming = false
    private var rotating = false
    private var pair: [Int] = []
    /// Recent pan, spread and twist in millimetres. They fade over about half a second, so slow
    /// drift never adds up to a gesture but a deliberate motion does.
    private var recentPan = Vec.zero
    private var recentStretch = 0.0
    private var recentArc = 0.0

    // MARK: Input

    public func process(_ frame: Frame) -> [Action] {
        var out = advance(to: frame.time)
        let dt = min(max(frame.time - lastTime, 0.004), 0.05)
        lastTime = frame.time

        updateButtons(frame.buttons, &out)

        var landed = false
        var seen = Set<Int>()
        for contact in frame.contacts where contact.touching {
            seen.insert(contact.id)
            if var track = tracks[contact.id] {
                track.previous = track.position
                track.position = contact.position
                track.travel = max(track.travel, (contact.position - track.start).length)
                if !contact.confident { track.palm = true }
                tracks[contact.id] = track
            } else {
                tracks[contact.id] = Track(id: contact.id, start: contact.position, position: contact.position,
                                           previous: contact.position, origin: contact.position,
                                           palm: !contact.confident)
                if contact.confident { landed = true }
            }
        }
        for id in tracks.keys where !seen.contains(id) { tracks[id] = nil }

        let active = activeTracks
        if landed { out.append(.touchBegan) }
        sessionMaxTravel = max(sessionMaxTravel, active.map(\.travel).max() ?? 0)

        if active.count != fingerCount {
            fingerCountChanged(to: active.count, time: frame.time, &out)
        }
        if !active.isEmpty { step(active, time: frame.time, dt: dt, &out) }
        return out
    }

    /// Runs anything that is due by `time` even though no finger report arrived.
    public func advance(to time: Double) -> [Action] {
        var out: [Action] = []
        if let release = dragReleaseAt, time >= release {
            dragReleaseAt = nil
            out.append(.buttonUp(.left))
        }
        if dragCandidate, mode == .pending, fingerCount == 1, time - sessionStart > tuning.tapMaxDuration {
            beginDrag(&out)
        }
        if let due = rightClickAt, time >= due, !secondTapUnderway(at: time) {
            rightClickAt = nil
            out.append(.click(.right))
        }
        return out
    }

    /// Fingers are down again after a two-finger tap and could still turn out to be a second tap.
    private func secondTapUnderway(at time: Double) -> Bool {
        fingerCount > 0 && !sessionGestured && sessionMaxFingers <= 2
            && time - sessionStart <= tuning.tapMaxDuration + 0.05
            && sessionMaxTravel <= tuning.tapSlop * 1.5
    }

    /// When `advance` next needs to be called, if no report arrives first.
    public var nextDeadline: Double? {
        var deadlines: [Double] = []
        if let release = dragReleaseAt { deadlines.append(release) }
        if dragCandidate, mode == .pending, fingerCount == 1 {
            deadlines.append(sessionStart + tuning.tapMaxDuration + 0.001)
        }
        if let due = rightClickAt {
            deadlines.append(fingerCount > 0 ? max(due, sessionStart + tuning.tapMaxDuration + 0.06) : due)
        }
        return deadlines.min()
    }

    /// The pad went away: end whatever is in flight and let go of every button.
    public func reset() -> [Action] {
        var out: [Action] = []
        endGesture(time: lastTime, fingersLeft: 0, &out)
        if mode == .dragging || dragReleaseAt != nil { out.append(.buttonUp(.left)) }
        updateButtons(0, &out)
        tracks = [:]
        mode = .idle
        fingerCount = 0
        dragReleaseAt = nil
        armedUntil = nil
        rightClickAt = nil
        dragCandidate = false
        return out
    }

    // MARK: Finger count changes

    private var activeTracks: [Track] {
        tracks.values.filter { !$0.palm }.sorted { $0.id < $1.id }
    }

    private func fingerCountChanged(to count: Int, time: Double, _ out: inout [Action]) {
        let previous = fingerCount
        fingerCount = count

        if previous == 0 {
            startSession(count: count, time: time, &out)
            return
        }
        sessionMaxFingers = max(sessionMaxFingers, count)
        if count != 1 { dragCandidate = false }

        if count == 0 {
            endSession(time: time, &out)
            return
        }

        switch mode {
        case .idle, .pending, .pointing:
            enterPending(count: count, time: time, &out)
        case .dragging:
            break
        case .transforming:
            let scrollOnly = scrolling && !zooming && !rotating
            if count < 2 {
                endGesture(time: time, fingersLeft: count, &out)
                // After a plain scroll the remaining finger may carry on pointing.
                mode = .settling(until: scrollOnly ? time + 0.15 : .infinity)
            } else if count >= 3, scrollOnly, time - gestureStart < 0.1 {
                // A third finger landed just after two started moving: it was a swipe all along.
                out.append(.scroll(phase: .ended, dx: 0, dy: 0, velocity: .zero))
                scrolling = false
                enterPending(count: count, time: time, &out)
            }
        case .swiping:
            if count < 3 {
                endGesture(time: time, fingersLeft: count, &out)
                mode = .settling(until: .infinity)
            }
        case .settling(let until):
            if count >= 2, until.isFinite { enterPending(count: count, time: time, &out) }
        }
    }

    private func startSession(count: Int, time: Double, _ out: inout [Action]) {
        sessionStart = time
        sessionMaxFingers = count
        sessionMaxTravel = 0
        sessionGestured = false
        sessionSuspect = secondsSinceKeystroke() < tuning.typingGuard

        if dragReleaseAt != nil {
            dragReleaseAt = nil
            if count == 1 {
                // Finger came back during the grace period: carry on dragging.
                mode = .dragging
                sessionGestured = true
                smoothedSpeed = 0
                return
            }
            out.append(.buttonUp(.left))
        }

        dragCandidate = count == 1 && (armedUntil.map { time <= $0 } ?? false)
        armedUntil = nil
        mode = .idle
        enterPending(count: count, time: time, &out)
    }

    private func enterPending(count: Int, time: Double, _ out: inout [Action]) {
        if scrollMayBegin, count != 2 { cancelMayBegin(&out) }
        mode = .pending
        pendingSince = time
        for id in tracks.keys { tracks[id]!.origin = tracks[id]!.position }
        if count == 2, !scrollMayBegin {
            scrollMayBegin = true
            out.append(.scroll(phase: .mayBegin, dx: 0, dy: 0, velocity: .zero))
        }
    }

    private func cancelMayBegin(_ out: inout [Action]) {
        guard scrollMayBegin else { return }
        scrollMayBegin = false
        out.append(.scroll(phase: .cancelled, dx: 0, dy: 0, velocity: .zero))
    }

    private func endSession(time: Double, _ out: inout [Action]) {
        endGesture(time: time, fingersLeft: 0, &out)
        cancelMayBegin(&out)

        var tapFingers = 0
        if mode != .dragging, !sessionGestured, !sessionSuspect, secondsSinceKeystroke() >= tuning.typingGuard {
            let multi = sessionMaxFingers > 1
            let quick = time - sessionStart <= tuning.tapMaxDuration + (multi ? 0.05 : 0)
            let still = sessionMaxTravel <= tuning.tapSlop * (multi ? 1.5 : 1)
            if quick, still { tapFingers = sessionMaxFingers }
        }
        // An earlier two-finger tap that this touch did not complete is a right click after all.
        if rightClickAt != nil, tapFingers != 2 {
            rightClickAt = nil
            out.append(.click(.right))
        }

        if mode == .dragging {
            dragReleaseAt = time + tuning.dragReleaseDelay
        }
        switch tapFingers {
        case 1:
            out.append(.click(.left))
            armedUntil = time + tuning.tapDragWindow
        case 2:
            if rightClickAt != nil {
                rightClickAt = nil
                out.append(.smartZoom)
            } else {
                rightClickAt = time + tuning.doubleTapWindow
            }
        case 3:
            out.append(.lookUp)
        default:
            break
        }
        dragCandidate = false
        mode = .idle
    }

    /// Closes the scroll, pinch, rotate or swipe in progress, if any.
    private func endGesture(time: Double, fingersLeft: Int, _ out: inout [Action]) {
        switch mode {
        case .transforming:
            if scrolling {
                // Coasting after a zoom or a twist would slide the picture away, so only a plain scroll coasts.
                let velocity = zooming || rotating ? Vec.zero : recentVelocity(at: time)
                out.append(.scroll(phase: .ended, dx: 0, dy: 0, velocity: velocity))
            }
            if zooming { out.append(.magnify(phase: .ended, delta: 0)) }
            if rotating { out.append(.rotate(phase: .ended, degrees: 0)) }
            scrolling = false; zooming = false; rotating = false
        case .swiping(let axis):
            let v = recentVelocity(at: time)
            out.append(.swipe(axis: axis, phase: .ended, delta: 0, velocity: axis == .vertical ? v.y : v.x))
        default:
            break
        }
    }

    // MARK: Per-frame work

    private func step(_ active: [Track], time: Double, dt: Double, _ out: inout [Action]) {
        let delta = meanDelta(active)
        smoothedSpeed = 0.5 * smoothedSpeed + 0.5 * (delta.length / dt)

        switch mode {
        case .idle:
            break

        case .pending:
            decide(active, time: time, &out)
            // Use this frame's motion right away if a pointer mode was just chosen.
            if mode == .pointing || mode == .dragging { movePointer(delta, &out) }

        case .pointing, .dragging:
            movePointer(delta, &out)

        case .transforming:
            transform(active, delta: delta, time: time, dt: dt, &out)

        case .swiping(.pinch):
            let radius = Self.radius(active.map(\.position))
            if active.count != radiusFingers {
                radiusFingers = active.count
                lastRadius = radius
            }
            let amount = (radius - lastRadius) / tuning.spreadScale
            lastRadius = radius
            samples.append((time, Vec(amount, 0)))
            if amount != 0 { out.append(.swipe(axis: .pinch, phase: .changed, delta: amount, velocity: 0)) }

        case .swiping(let axis):
            let progress = delta * (1 / tuning.swipeScale)
            let amount = axis == .horizontal ? progress.x : progress.y
            samples.append((time, progress))
            if amount != 0 { out.append(.swipe(axis: axis, phase: .changed, delta: amount, velocity: 0)) }

        case .settling(let until):
            if active.count == 1, time >= until { enterPending(count: 1, time: time, &out) }
        }
    }

    private func decide(_ active: [Track], time: Double, _ out: inout [Action]) {
        let waited = time - pendingSince
        let displacement = active.map { $0.position - $0.origin }
        let pan = displacement.reduce(Vec.zero, +) * (1 / Double(active.count))

        switch active.count {
        case 1:
            if dragCandidate {
                if pan.length > 0.8 { beginDrag(&out) }
                return
            }
            let typing = secondsSinceKeystroke() < tuning.typingGuard
            // After more fingers were down, the last one is usually on its way off the pad too.
            let minimumWait = sessionMaxFingers > 1 ? 0.08 : 0.012
            if waited >= minimumWait, pan.length > 0.4 || waited > 0.1, !typing {
                mode = .pointing
                smoothedSpeed = 0
            }

        case 2:
            guard waited >= 0.025 else { return }
            let before = active[1].origin - active[0].origin
            let now = active[1].position - active[0].position
            let stretch = abs(now.length - before.length)
            let turn = Self.wrap(Self.angle(now) - Self.angle(before))
            let arc = abs(turn) * before.length / 2

            let startsScroll = pan.length >= tuning.scrollStart && stretch < 1.5 * pan.length && arc < 1.5 * pan.length
            let startsZoom = stretch >= tuning.pinchStart && stretch >= 1.5 * pan.length && stretch >= arc
            let startsRotate = arc >= tuning.rotateStart && arc > stretch && arc >= 1.5 * pan.length
            guard startsScroll || startsZoom || startsRotate else { return }

            beginGesture(.transforming, time: time)
            pair = [active[0].id, active[1].id]
            lastDistance = now.length
            lastAngle = Self.angle(now)
            recentPan = .zero; recentStretch = 0; recentArc = 0
            if startsScroll {
                scrollMayBegin = false
                scrolling = true
                if abs(pan.y) >= 2 * abs(pan.x) { axisLock = .vertical }
                else if abs(pan.x) >= 2 * abs(pan.y) { axisLock = .horizontal }
                else { axisLock = .free }
                offAxis = 0
                emitScroll(pan, phase: .began, time: time, &out)
            } else {
                cancelMayBegin(&out)
                if startsZoom {
                    zooming = true
                    out.append(.magnify(phase: .began, delta: 0))
                } else {
                    rotating = true
                    out.append(.rotate(phase: .began, degrees: 0))
                }
            }

        default:
            guard waited >= 0.02 else { return }
            var spread = 0.0
            if active.count >= 4 {
                let radius = Self.radius(active.map(\.position))
                spread = radius - Self.radius(active.map(\.origin))
                if abs(spread) >= 3, abs(spread) > pan.length {
                    beginGesture(.swiping(.pinch), time: time)
                    lastRadius = radius
                    radiusFingers = active.count
                    let amount = spread / tuning.spreadScale
                    samples.append((time, Vec(amount, 0)))
                    out.append(.swipe(axis: .pinch, phase: .began, delta: 0, velocity: 0))
                    out.append(.swipe(axis: .pinch, phase: .changed, delta: amount, velocity: 0))
                    return
                }
            }
            guard pan.length >= tuning.swipeStart, pan.length > abs(spread) else { return }
            let axis: SwipeAxis = abs(pan.x) >= abs(pan.y) ? .horizontal : .vertical
            beginGesture(.swiping(axis), time: time)
            let progress = pan * (1 / tuning.swipeScale)
            samples.append((time, progress))
            out.append(.swipe(axis: axis, phase: .began, delta: 0, velocity: 0))
            out.append(.swipe(axis: axis, phase: .changed,
                              delta: axis == .horizontal ? progress.x : progress.y, velocity: 0))
        }
    }

    /// One frame of a two-finger gesture: feed the live parts, and let the others join in.
    private func transform(_ active: [Track], delta: Vec, time: Double, dt: Double, _ out: inout [Action]) {
        guard active.count >= 2 else { return }
        let between = active[1].position - active[0].position
        let ids = [active[0].id, active[1].id]
        if ids != pair {
            // A different pair of fingers: measure from here rather than jump.
            pair = ids
            lastDistance = between.length
            lastAngle = Self.angle(between)
        }
        let spread = between.length - lastDistance
        let turn = Self.wrap(Self.angle(between) - lastAngle)
        lastDistance = between.length
        lastAngle = Self.angle(between)

        let fade = exp(-dt / 0.4)
        recentPan = recentPan * fade + delta
        recentStretch = recentStretch * fade + spread
        recentArc = recentArc * fade + turn * between.length / 2
        let pan = recentPan.length, stretch = abs(recentStretch), arc = abs(recentArc)

        // Zoom and rotate run together, as on a Magic Trackpad. Scrolling does not mix with them:
        // apps stop following a pinch or a twist while a scroll is also in flight. So a deliberate
        // pinch or twist ends the scroll, and the scroll stays out until the fingers lift.
        // Taking over from a scroll takes a clearer motion than starting from rest, so a scroll
        // with fingers drifting apart stays a scroll.
        let need = scrolling ? 3.5 : 2.0
        let joinZoom = !zooming && stretch >= need && stretch >= max(scrolling ? 0.5 * pan : 0, 0.25 * arc)
        let joinRotate = !rotating && arc >= need && arc >= max(scrolling ? 0.5 * pan : 0, 0.25 * stretch)
        if scrolling, joinZoom || joinRotate {
            scrolling = false
            out.append(.scroll(phase: .ended, dx: 0, dy: 0, velocity: .zero))
        }
        if joinZoom {
            zooming = true
            out.append(.magnify(phase: .began, delta: 0))
        }
        if joinRotate {
            rotating = true
            out.append(.rotate(phase: .began, degrees: 0))
        }

        if scrolling { emitScroll(delta, phase: .changed, time: time, &out) }
        if zooming, spread != 0 {
            out.append(.magnify(phase: .changed, delta: spread / tuning.pinchScale))
        }
        // The pad's y axis points down, so a positive angle change is clockwise on the pad.
        if rotating, turn != 0 {
            out.append(.rotate(phase: .changed, degrees: -turn * 180 / .pi))
        }
    }

    private func beginGesture(_ newMode: Mode, time: Double) {
        mode = newMode
        sessionGestured = true
        gestureStart = time
        samples = []
        smoothedSpeed = 0
    }

    private func beginDrag(_ out: inout [Action]) {
        dragCandidate = false
        sessionGestured = true
        mode = .dragging
        smoothedSpeed = 0
        out.append(.buttonDown(.left))
    }

    private func movePointer(_ delta: Vec, _ out: inout [Action]) {
        guard delta != .zero else { return }
        let gain = Curves.pointerGain(speed: smoothedSpeed, setting: tuning.pointerSpeed)
        out.append(.move(dx: delta.x * gain, dy: delta.y * gain))
    }

    private func emitScroll(_ delta: Vec, phase: Phase, time: Double, _ out: inout [Action]) {
        var d = delta
        switch axisLock {
        case .vertical:
            offAxis += d.x
            if abs(offAxis) > 6 { axisLock = .free } else { d.x = 0 }
        case .horizontal:
            offAxis += d.y
            if abs(offAxis) > 6 { axisLock = .free } else { d.y = 0 }
        case .free:
            break
        }
        let gain = Curves.scrollGain(speed: smoothedSpeed, setting: tuning.scrollSpeed)
        let points = d * gain
        samples.append((time, points))
        if points != .zero || phase == .began {
            out.append(.scroll(phase: phase, dx: points.x, dy: points.y, velocity: .zero))
        }
    }

    /// Average movement of the fingers that were also down last frame.
    private func meanDelta(_ active: [Track]) -> Vec {
        guard !active.isEmpty else { return .zero }
        return active.reduce(Vec.zero) { $0 + ($1.position - $1.previous) } * (1 / Double(active.count))
    }

    /// Speed over the last few hundredths of a second, in whatever unit `samples` holds, per second.
    /// Zero if the fingers had already come to rest.
    private func recentVelocity(at time: Double) -> Vec {
        let window = 0.07
        guard let last = samples.last(where: { $0.delta != .zero }), time - last.time <= 0.05 else { return .zero }
        let recent = samples.filter { $0.time > time - window }
        let span = max(0.016, min(window, time - gestureStart))
        return recent.reduce(Vec.zero) { $0 + $1.delta } * (1 / span)
    }

    private func updateButtons(_ new: UInt8, _ out: inout [Action]) {
        guard new != buttons else { return }
        for (bit, button) in [MouseButton.left, .right, .middle].enumerated() {
            let mask = UInt8(1 << bit)
            if new & mask != 0, buttons & mask == 0 { out.append(.buttonDown(button)) }
            if new & mask == 0, buttons & mask != 0 { out.append(.buttonUp(button)) }
        }
        buttons = new
    }

    /// Average distance of the fingers from their common centre.
    private static func radius(_ points: [Vec]) -> Double {
        let centre = points.reduce(Vec.zero, +) * (1 / Double(points.count))
        return points.reduce(0) { $0 + ($1 - centre).length } / Double(points.count)
    }

    private static func angle(_ v: Vec) -> Double { atan2(v.y, v.x) }
    private static func wrap(_ a: Double) -> Double {
        var r = a
        while r > .pi { r -= 2 * .pi }
        while r < -.pi { r += 2 * .pi }
        return r
    }
}
