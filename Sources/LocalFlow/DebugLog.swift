import Foundation

/// A small local log of shortcut and state events, for diagnosing missed
/// presses: ~/Library/Logs/LocalFlow.log. Never records transcribed text.
enum DebugLog {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/LocalFlow.log")
    private static let queue = DispatchQueue(label: "localflow.log")
    private static let maxBytes = 512 * 1024

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
                try? fm.removeItem(at: url.appendingPathExtension("old"))
                try? fm.moveItem(at: url, to: url.appendingPathExtension("old"))
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        }
    }
}
