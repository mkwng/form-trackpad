import XCTest
@testable import TouchCore

/// Replays a recorded log (see Troubleshooting in the README) through the engine and prints what
/// each touch turned into. Run with `FORM_LOG=~/Library/Logs/FormTrackpad.log swift test --filter Replay`.
final class ReplayTests: XCTestCase {
    func testReplayRecordedLog() throws {
        guard let path = ProcessInfo.processInfo.environment["FORM_LOG"] else { throw XCTSkip("no FORM_LOG") }
        let text = try String(contentsOfFile: NSString(string: path).expandingTildeInPath, encoding: .utf8)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let engine = GestureEngine()
        var summary: [String] = []
        var touching = false
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: " report "), let date = formatter.date(from: String(line.prefix(23))) else { continue }
            let hex = Array(line[range.upperBound...])
            let bytes = stride(from: 0, to: hex.count - 1, by: 2).compactMap { UInt8(String(hex[$0...$0 + 1]), radix: 16) }
            guard let parsed = FormReport.parse(bytes) else { continue }
            let frame = Frame(time: date.timeIntervalSinceReferenceDate, contacts: parsed.contacts, buttons: parsed.buttons)
            for action in engine.process(frame) {
                switch action {
                case .scroll(.began, _, _, _): summary.append("scroll")
                case .magnify(.began, _): summary.append("zoom")
                case .rotate(.began, _): summary.append("rotate")
                case .swipe(_, .began, _, _): summary.append("swipe")
                case .click(let button): summary.append("click-\(button)")
                case .buttonDown: summary.append("drag")
                default: break
                }
            }
            let down = parsed.contacts.contains { $0.touching }
            if touching, !down { summary.append("|") }
            touching = down
        }
        let touches = summary.split(separator: "|").map { $0.joined(separator: "+") }
        print("REPLAY", Dictionary(touches.map { ($0, 1) }, uniquingKeysWith: +).sorted { $0.value > $1.value })
    }
}
