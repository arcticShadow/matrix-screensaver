//
//  ProfileTag.swift
//  Config dir basename -> short profile tag shown on screen (and used in the
//  collector's log) instead of the folder name, which may be personal.
//  `.claude` -> WRK; `.claude-<name>` -> first three letters of <name>,
//  uppercased; the config file's `profileTags` overrides either.
//

import Foundation

enum ProfileTag {
    static func tag(forDir dir: String, config: DiagConfig) -> String {
        if let t = config.profileTags[dir], !t.isEmpty { return t }
        if dir == ".claude" { return "WRK" }
        var rest = Substring(dir)
        if rest.hasPrefix(".claude") { rest = rest.dropFirst(".claude".count) }
        let letters = rest.filter { $0.isLetter || $0.isNumber }
        return letters.isEmpty ? "CLD" : String(letters.prefix(3)).uppercased()
    }
}
