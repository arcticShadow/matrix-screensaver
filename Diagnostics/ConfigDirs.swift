//
//  ConfigDirs.swift
//  The ONE rule for which Claude Code config dirs exist: every `~/.claude*`
//  entry under the real home that is a DIRECTORY (`.claude`, `.claude-alpha`,
//  `.claudework`, …). Files such as `.claude.json` / `.claude.json.backup`
//  never count. Shared by the saver's session scan and the collector's usage
//  accounts, so both always see the same set.
//

import Foundation

enum ConfigDirs {
    struct HomeUnreadable: Error, CustomStringConvertible {
        var description: String { "home not listable" }
    }

    /// Basenames, `.claude` first, then sorted. Throws when the home itself
    /// can't be listed (callers decide whether that is SIGNAL LOST or empty).
    static func discover(home: String) throws -> [String] {
        let fm = FileManager.default
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: home) } catch { throw HomeUnreadable() }
        return names.filter { name in
            guard name.hasPrefix(".claude") else { return false }
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: (home as NSString).appendingPathComponent(name), isDirectory: &isDir)
                && isDir.boolValue
        }.sorted { a, b in a == ".claude" ? b != ".claude" : b == ".claude" ? false : a < b }
    }
}
