//
//  CollectorLog.swift
//  The collector logs only errors and state changes (never tokens, keychain
//  service names or account folder names: accounts appear by profile tag).
//  When the file passes `maxBytes` (1 MB) it is truncated before the next
//  line is appended. `lines` keeps this run's lines in memory for tests.
//

import Foundation

final class CollectorLog {
    static let defaultMaxBytes = 1_000_000

    let path: String?
    let maxBytes: Int
    private let now: () -> Date
    private(set) var lines: [String] = []

    init(path: String?, maxBytes: Int = CollectorLog.defaultMaxBytes, now: @escaping () -> Date) {
        self.path = path
        self.maxBytes = maxBytes
        self.now = now
    }

    static func defaultPath(home: String) -> String {
        (home as NSString).appendingPathComponent("Library/Logs/matrix-diag/collector.log")
    }

    func error(_ message: String) { append("ERROR " + message) }
    func change(_ message: String) { append("STATE " + message) }

    private func append(_ message: String) {
        let f = ISO8601DateFormatter()
        let line = "\(f.string(from: now())) \(message)"
        lines.append(line)
        guard let path else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        var text = line + "\n"
        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        if size > maxBytes {
            text = "\(f.string(from: now())) STATE log truncated (was \(size) bytes)\n" + text
            fm.createFile(atPath: path, contents: Data(text.utf8))
            return
        }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            h.closeFile()
        } else {
            fm.createFile(atPath: path, contents: Data(text.utf8))
        }
    }
}
