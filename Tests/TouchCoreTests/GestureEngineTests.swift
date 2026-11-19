import XCTest
@testable import TouchCore

/// Drives the engine with invented finger paths, one report every 8 ms like the real pad.
private final class Pad {
    let engine = GestureEngine()
    var time = 10.0
    var actions: [Action] = []
    private var fingers: [Int: Vec] = [:]

    func down(_ id: Int, _ x: Double, _ y: Double) { fingers[id] = Vec(x, y); report() }

    func up(_ ids: Int...) {
        for id in ids { fingers[id] = nil }
        report()
    }

    /// Moves the given fingers by `by` in total, spread over `duration` seconds.
    func drag(_ moves: [Int: Vec], over duration: Double) {
        let steps = max(1, Int(duration / 0.008))
        for _ in 0..<steps {
            for (id, by) in moves { fingers[id] = fingers[id]! + by * (1 / Double(steps)) }
            report()
        }
    }

    func wait(_ seconds: Double) {
        time += seconds
        actions += engine.advance(to: time)
    }

    private func report() {
        time += 0.008
        let contacts = fingers.sorted { $0.key < $1.key }.map { Contact(id: $0.key, position: $0.value) }
        actions += engine.process(Frame(time: time, contacts: contacts))
    }

    var moved: Vec {
        actions.reduce(Vec.zero) { sum, action in
            if case .move(let dx, let dy) = action { return sum + Vec(dx, dy) }
            return sum
        }
    }

    var scrolled: Vec {
        actions.reduce(Vec.zero) { sum, action in
            if case .scroll(_, let dx, let dy, _) = action { return sum + Vec(dx, dy) }
            return sum
        }
    }

    var scrollPhases: [Phase] {
        actions.compactMap { if case .scroll(let phase, _, _, _) = $0 { return phase } else { return nil } }
    }

    func count(_ action: Action) -> Int { actions.filter { $0 == action }.count }
}

final class GestureEngineTests: XCTestCase {
    func testOneFingerMovesThePointer() {
        let pad = Pad()
        pad.down(0, 20, 20)
        pad.drag([0: Vec(10, -5)], over: 0.2)
        pad.up(0)
        XCTAssertGreaterThan(pad.moved.x, 30)
        XCTAssertLessThan(pad.moved.y, -15)
        XCTAssertEqual(pad.count(.click(.left)), 0)
    }

    func testFastMovementCoversMoreScreenThanSlow() {
        let slow = Pad(), fast = Pad()
        slow.down(0, 10, 10); slow.drag([0: Vec(30, 0)], over: 1.5); slow.up(0)
        fast.down(0, 10, 10); fast.drag([0: Vec(30, 0)], over: 0.12); fast.up(0)
        XCTAssertGreaterThan(fast.moved.x, slow.moved.x * 2)
    }

    func testTapClicks() {
        let pad = Pad()
        pad.down(0, 30, 30)
        pad.wait(0.06)
        pad.up(0)
        XCTAssertEqual(pad.actions.filter { $0 != .touchBegan }, [.click(.left)])
    }

    func testLongPressIsNotATap() {
        let pad = Pad()
        pad.down(0, 30, 30)
        pad.wait(0.5)
        pad.up(0)
        XCTAssertEqual(pad.count(.click(.left)), 0)
    }

    func testTapWhileTypingIsIgnored() {
        let pad = Pad()
        pad.engine.secondsSinceKeystroke = { 0.1 }
        pad.down(0, 30, 30)
        pad.wait(0.06)
        pad.up(0)
        XCTAssertEqual(pad.count(.click(.left)), 0)
    }

    func testDoubleTapClicksTwice() {
        let pad = Pad()
        pad.down(0, 30, 30); pad.wait(0.05); pad.up(0)
        pad.wait(0.1)
        pad.down(0, 30, 30); pad.wait(0.05); pad.up(0)
        XCTAssertEqual(pad.count(.click(.left)), 2)
        XCTAssertEqual(pad.count(.buttonDown(.left)), 0)
    }

    func testTapThenDragHoldsTheButtonUntilAfterTheLift() {
        let pad = Pad()
        pad.down(0, 30, 30); pad.wait(0.05); pad.up(0)
        pad.wait(0.1)
        pad.down(0, 30, 30)
        pad.drag([0: Vec(15, 0)], over: 0.2)
        XCTAssertEqual(pad.count(.buttonDown(.left)), 1)
        XCTAssertGreaterThan(pad.moved.x, 20)
        pad.up(0)
        XCTAssertEqual(pad.count(.buttonUp(.left)), 0, "the button stays down briefly so the finger can reposition")
        pad.wait(0.3)
        XCTAssertEqual(pad.count(.buttonUp(.left)), 1)
    }

    func testDragContinuesWhenTheFingerComesBackQuickly() {
        let pad = Pad()
        pad.down(0, 30, 30); pad.wait(0.05); pad.up(0)
        pad.wait(0.1)
        pad.down(0, 30, 30)
        pad.drag([0: Vec(15, 0)], over: 0.2)
        pad.up(0)
        pad.wait(0.1)
        pad.down(0, 10, 30)
        pad.drag([0: Vec(15, 0)], over: 0.2)
        XCTAssertEqual(pad.count(.buttonUp(.left)), 0)
        pad.up(0)
        pad.wait(0.3)
        XCTAssertEqual(pad.count(.buttonDown(.left)), 1)
        XCTAssertEqual(pad.count(.buttonUp(.left)), 1)
    }

    func testTapThenHoldStillPressesTheButton() {
        let pad = Pad()
        pad.down(0, 30, 30); pad.wait(0.05); pad.up(0)
        pad.wait(0.1)
        pad.down(0, 30, 30)
        XCTAssertNotNil(pad.engine.nextDeadline)
        pad.wait(0.3)
        XCTAssertEqual(pad.count(.buttonDown(.left)), 1)
    }

    func testTwoFingerTapRightClicks() {
        let pad = Pad()
        pad.down(0, 30, 30); pad.down(1, 45, 30)
        pad.wait(0.05)
        pad.up(0); pad.up(1)
        XCTAssertEqual(pad.count(.click(.right)), 1)
        XCTAssertEqual(pad.count(.click(.left)), 0)
        XCTAssertEqual(pad.scrollPhases, [.mayBegin, .cancelled])
    }

    func testThreeFingerTapMiddleClicks() {
        let pad = Pad()
        pad.down(0, 20, 30); pad.down(1, 35, 30); pad.down(2, 50, 30)
        pad.wait(0.05)
        pad.up(0, 1, 2)
        XCTAssertEqual(pad.count(.click(.middle)), 1)
    }

    func testTwoFingersScrollAndCoast() {
        let pad = Pad()
        pad.down(0, 30, 20); pad.down(1, 45, 20)
        pad.drag([0: Vec(0, 25), 1: Vec(0, 25)], over: 0.15)
        pad.up(0, 1)
        XCTAssertEqual(pad.scrollPhases.first, .mayBegin)
        XCTAssertEqual(pad.scrollPhases.dropFirst().first, .began)
        XCTAssertEqual(pad.scrollPhases.last, .ended)
        XCTAssertGreaterThan(pad.scrolled.y, 150)
        XCTAssertEqual(pad.scrolled.x, 0)
        XCTAssertEqual(pad.moved, .zero)
        guard case .scroll(.ended, _, _, let velocity) = pad.actions.last else { return XCTFail("no scroll end") }
        XCTAssertGreaterThan(velocity.y, 500, "a flick should leave speed for momentum")
        XCTAssertEqual(pad.count(.click(.right)), 0)
    }

    func testScrollThatStopsBeforeLiftingDoesNotCoast() {
        let pad = Pad()
        pad.down(0, 30, 20); pad.down(1, 45, 20)
        pad.drag([0: Vec(0, 25), 1: Vec(0, 25)], over: 0.3)
        pad.wait(0.3)
        pad.up(0, 1)
        guard case .scroll(.ended, _, _, let velocity) = pad.actions.last else { return XCTFail("no scroll end") }
        XCTAssertEqual(velocity, .zero)
    }

    func testMostlyVerticalScrollStaysVertical() {
        let pad = Pad()
        pad.down(0, 30, 20); pad.down(1, 45, 20)
        pad.drag([0: Vec(2, 25), 1: Vec(2, 25)], over: 0.3)
        XCTAssertEqual(pad.scrolled.x, 0)
    }

    func testLiftingOneFingerAfterScrollDoesNotJerkThePointer() {
        let pad = Pad()
        pad.down(0, 30, 20); pad.down(1, 45, 20)
        pad.drag([0: Vec(0, 25), 1: Vec(0, 25)], over: 0.2)
        pad.up(1)
        pad.drag([0: Vec(1, 1)], over: 0.05)
        pad.up(0)
        XCTAssertEqual(pad.moved, .zero)
    }

    func testSpreadingTwoFingersZoomsIn() {
        let pad = Pad()
        pad.down(0, 25, 40); pad.down(1, 40, 40)
        pad.drag([0: Vec(-10, 0), 1: Vec(10, 0)], over: 0.25)
        pad.up(0, 1)
        let total = pad.actions.reduce(0.0) { sum, action in
            if case .magnify(_, let delta) = action { return sum + delta }
            return sum
        }
        XCTAssertGreaterThan(total, 0.25)
        XCTAssertEqual(pad.count(.magnify(phase: .began, delta: 0)), 1)
        XCTAssertEqual(pad.count(.magnify(phase: .ended, delta: 0)), 1)
        XCTAssertFalse(pad.scrollPhases.contains(.began))
    }

    func testPinchWithARestingThumbStillZooms() {
        let pad = Pad()
        pad.down(0, 20, 50); pad.down(1, 35, 35)
        pad.drag([1: Vec(12, -12)], over: 0.25)
        XCTAssertEqual(pad.count(.magnify(phase: .began, delta: 0)), 1)
        XCTAssertFalse(pad.scrollPhases.contains(.began))
    }

    func testTwistingTwoFingersRotates() {
        let pad = Pad()
        pad.down(0, 25, 40); pad.down(1, 45, 40)
        // Finger 0 goes down the pad and finger 1 goes up: counterclockwise as seen from above.
        pad.drag([0: Vec(0, 8), 1: Vec(0, -8)], over: 0.25)
        let total = pad.actions.reduce(0.0) { sum, action in
            if case .rotate(_, let degrees) = action { return sum + degrees }
            return sum
        }
        XCTAssertGreaterThan(total, 15)
    }

    func testThreeFingersSwipeSideways() {
        let pad = Pad()
        pad.down(0, 15, 30); pad.down(1, 30, 30); pad.down(2, 45, 30)
        pad.drag([0: Vec(-30, 2), 1: Vec(-30, 2), 2: Vec(-30, 2)], over: 0.15)
        pad.up(0, 1, 2)
        let swipes = pad.actions.compactMap { action -> (Phase, Double, Double)? in
            if case .swipe(.horizontal, let phase, let delta, let velocity) = action { return (phase, delta, velocity) }
            return nil
        }
        XCTAssertEqual(swipes.first?.0, .began)
        XCTAssertEqual(swipes.last?.0, .ended)
        XCTAssertEqual(swipes.reduce(0) { $0 + $1.1 }, -30 / 55, accuracy: 0.05)
        XCTAssertLessThan(swipes.last!.2, -1, "ending velocity carries the direction")
        XCTAssertFalse(pad.scrollPhases.contains(.began))
        XCTAssertEqual(pad.moved, .zero)
    }

    func testFingersLandingOneAfterAnotherStillSwipe() {
        let pad = Pad()
        pad.down(0, 15, 30)
        pad.down(1, 30, 30)
        pad.down(2, 45, 30)
        pad.drag([0: Vec(0, -25), 1: Vec(0, -25), 2: Vec(0, -25)], over: 0.15)
        pad.up(0); pad.up(1); pad.up(2)
        XCTAssertEqual(pad.count(.swipe(axis: .vertical, phase: .began, delta: 0, velocity: 0)), 1)
        XCTAssertFalse(pad.scrollPhases.contains(.began))
        XCTAssertEqual(pad.moved, .zero)
        XCTAssertEqual(pad.count(.click(.left)), 0)
    }

    func testPalmIsIgnored() {
        let pad = Pad()
        _ = pad.engine.process(Frame(time: 1, contacts: [Contact(id: 0, position: Vec(5, 5), confident: false)]))
        let actions = pad.engine.process(Frame(time: 1.05, contacts: []))
        XCTAssertEqual(actions, [])
    }

    func testDisconnectLetsGoOfTheButton() {
        let pad = Pad()
        pad.down(0, 30, 30); pad.wait(0.05); pad.up(0)
        pad.wait(0.1)
        pad.down(0, 30, 30)
        pad.drag([0: Vec(15, 0)], over: 0.2)
        XCTAssertEqual(pad.engine.reset(), [.buttonUp(.left)])
    }
}

final class FormReportTests: XCTestCase {
    func testParsesTwoFingers() {
        var bytes = [UInt8](repeating: 0, count: 24)
        bytes[0] = 8
        // Slot 0: confident, touching, contact 1, at x 123, y 456.
        bytes[1] = 0b0000_0111
        bytes[2] = 123; bytes[3] = 0
        bytes[4] = UInt8(456 & 0xff); bytes[5] = UInt8(456 >> 8)
        // Slot 1: not confident, touching, contact 2.
        bytes[6] = 0b0000_1010
        bytes[7] = 10; bytes[9] = 20
        bytes[21] = 0x34; bytes[22] = 0x12
        bytes[23] = 0x12 // two contacts, left button down
        let parsed = FormReport.parse(bytes)
        XCTAssertEqual(parsed?.contacts, [
            Contact(id: 1, position: Vec(12.3, 45.6)),
            Contact(id: 2, position: Vec(1, 2), confident: false),
        ])
        XCTAssertEqual(parsed?.scanTime, 0x1234)
        XCTAssertEqual(parsed?.buttons, 1)
    }

    func testRejectsOtherReports() {
        XCTAssertNil(FormReport.parse([5, 0, 0, 0]))
    }
}

final class MomentumCurveTests: XCTestCase {
    func testCoastsToAStop() {
        let curve = MomentumCurve(initialSpeed: 2000)
        XCTAssertGreaterThan(curve.duration, 0.5)
        XCTAssertLessThan(curve.duration, 4)
        XCTAssertLessThan(curve.speed(at: curve.duration), MomentumCurve.stopSpeed + 0.01)
        XCTAssertGreaterThan(curve.distance(at: curve.duration), 300)
        XCTAssertLessThan(curve.distance(at: 0.1), curve.distance(at: 0.2))
    }
}
