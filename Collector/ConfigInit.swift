//
//  ConfigInit.swift — first-run creation of the user's config file
//  (`matrix-diag-collector --init-config`, called by the bootstrap task in
//  mise.collector.toml). Creates it with defaults and a fresh random codename
//  salt ONLY if it doesn't exist: an existing file (even a malformed one) is
//  never touched, so reinstalling keeps the user's salt and codenames.
//

import Foundation

enum ConfigInitializer {
    enum Outcome: Equatable { case created, alreadyExists }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// 16 random bytes as 32 lowercase hex chars (SystemRandomNumberGenerator is
    /// cryptographically secure on Darwin).
    static func randomSalt() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng)) }.joined()
    }

    /// The default config, as written on first install. Keys mirror `DiagConfig`.
    static func defaultContents(salt: String) -> String {
        let escaped = salt.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "overlay": true,
          "trustedSSIDs": [],
          "codenameSalt": "\(escaped)",
          "profileTags": {}
        }

        """
    }

    /// Creates `path` (and its directory) with mode 0600 unless it already
    /// exists. O_EXCL makes "only if missing" race-free: a file that appears
    /// concurrently is reported as `.alreadyExists`, never overwritten.
    static func createIfMissing(path: String, salt: () -> String = randomSalt) throws -> Outcome {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return .alreadyExists }
        let dir = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 {
            if errno == EEXIST { return .alreadyExists }
            throw Failure(description: "cannot create config (errno \(errno))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(defaultContents(salt: salt()).utf8))
        } catch {
            try? fm.removeItem(atPath: path)
            throw Failure(description: "cannot write config: \(error)")
        }
        return .created
    }
}
