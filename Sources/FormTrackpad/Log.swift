import Foundation

/// A plain text log at ~/Library/Logs/FormTrackpad.log, for working out what the pad did.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/FormTrackpad.log")
    /// Also record every raw finger report and every action. Turn on with
    /// `defaults write com.mkwng.FormTrackpad logFrames -bool YES` and relaunch.
    static let frames = UserDefaults.standard.bool(forKey: "logFrames")

    private static let handle: FileHandle? = {
        let limit = 20_000_000
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > limit {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        try? handle?.write(contentsOf: Data(line.utf8))
    }
}
