import Foundation

/// Appends to ~/Library/Application Support/ClipboardAnnotator/debug.log.
/// Unified logging swallows too much for a menu-bar agent; a plain file does not.
/// Once per launch, a log past `maxBytes` is moved aside to debug.log.1, so the
/// pair never grows beyond roughly twice that.
enum Diag {
    private static let queue = DispatchQueue(label: "com.texoport.ClipboardAnnotator.diag")
    private static let maxBytes = 2_000_000

    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipboardAnnotator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("debug.log")
        rotateIfLarge(url)
        return url
    }()

    private static func rotateIfLarge(_ url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int, size > maxBytes else { return }
        let previous = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
    }

    static func log(_ message: String) {
        let line = "\(stamp()) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
