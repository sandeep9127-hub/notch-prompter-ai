import Foundation

/// Appends timestamped lines to ~/Library/Logs/NotchCoach.log so problems can be diagnosed.
enum Log {
    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NotchCoach.log")
    private static let queue = DispatchQueue(label: "notchcoach.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

/// Restarts speech recognition after a session ends, backing off when it keeps failing straight
/// away (for example when dictation is unavailable) instead of spinning.
struct RecognitionBackoff {
    private(set) var failures = 0
    private var startedAt = Date()

    mutating func started() { startedAt = Date() }

    mutating func heardSpeech() { failures = 0 }

    /// Returns the delay before the next attempt, or nil to give up.
    mutating func nextDelay() -> TimeInterval? {
        if Date().timeIntervalSince(startedAt) < 2 { failures += 1 } else { failures = 0 }
        if failures >= 8 { return nil }
        return min(5, 0.2 * pow(2, Double(failures)))
    }
}
