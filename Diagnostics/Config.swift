//
//  Config.swift
//  The user's config file (~/.config/matrix-diag/config.json). Shared by the
//  saver and (later) the collector. Never committed; private values live only
//  in the user's file. Missing or malformed -> built-in defaults.
//

import Foundation

struct DiagConfig: Equatable {
    /// `"overlay": false` turns the diagnostic overlay off without a rebuild.
    var overlay: Bool = true
    /// Wi-Fi names that count as trusted (real names shown). Empty = always codenames.
    var trustedSSIDs: [String] = []
    /// Salt for codenames. nil = none configured (callers pick a per-run random salt).
    var codenameSalt: String? = nil
    /// Config-dir basename -> profile tag (e.g. ".claude" -> "WRK").
    var profileTags: [String: String] = [:]
}

enum ConfigStatus: Equatable {
    case loaded
    case missing
    /// File exists but isn't a JSON object; defaults are used.
    case malformed
}

struct ConfigLoadResult: Equatable {
    var config: DiagConfig
    var status: ConfigStatus
}

enum ConfigLoader {
    /// Relative to the real home directory.
    static let relativePath = ".config/matrix-diag/config.json"

    static func defaultPath(home: String) -> String {
        (home as NSString).appendingPathComponent(relativePath)
    }

    static func load(path: String) -> ConfigLoadResult {
        guard let data = FileManager.default.contents(atPath: path) else {
            return ConfigLoadResult(config: DiagConfig(), status: .missing)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return ConfigLoadResult(config: DiagConfig(), status: .malformed)
        }
        var cfg = DiagConfig()
        // Each key is optional and type-checked on its own: one bad value keeps
        // its default rather than discarding the whole file.
        if let v = dict["overlay"] as? Bool { cfg.overlay = v }
        if let v = dict["trustedSSIDs"] as? [String] { cfg.trustedSSIDs = v }
        if let v = dict["codenameSalt"] as? String, !v.isEmpty { cfg.codenameSalt = v }
        if let v = dict["profileTags"] as? [String: String] { cfg.profileTags = v }
        return ConfigLoadResult(config: cfg, status: .loaded)
    }
}
