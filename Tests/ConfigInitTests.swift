//
//  ConfigInitTests.swift — first-run config creation (`matrix-diag-collector
//  --init-config`, run by the collector's bootstrap task): create the config
//  with defaults and a random salt only if it is missing; never overwrite.
//

import Foundation

func configInitTests() {
    test("missing config is created with defaults and the given salt, readable by the loader") {
        let path = makeTempDir("cfginit-new") + "/nested/matrix-diag/config.json"
        let outcome = try ConfigInitializer.createIfMissing(path: path, salt: { "fixed-test-salt" })
        expectEqual(outcome, .created)
        let loaded = ConfigLoader.load(path: path)
        expectEqual(loaded.status, .loaded)
        expectEqual(loaded.config, DiagConfig(overlay: true, trustedSSIDs: [],
                                              codenameSalt: "fixed-test-salt", profileTags: [:]))
    }

    test("created config is private to the user (0600)") {
        let path = makeTempDir("cfginit-mode") + "/config.json"
        _ = try ConfigInitializer.createIfMissing(path: path, salt: { "s" })
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        expectEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    test("an existing config (and its salt) is never overwritten") {
        let path = makeTempDir("cfginit-keep") + "/config.json"
        let original = #"{ "codenameSalt": "users-own-salt", "trustedSSIDs": ["TrustedNet"] }"#
        writeFile(path, original)
        let outcome = try ConfigInitializer.createIfMissing(path: path, salt: { "other" })
        expectEqual(outcome, .alreadyExists)
        expectEqual(try String(contentsOfFile: path, encoding: .utf8), original)
    }

    test("even a malformed existing config is left alone") {
        let path = makeTempDir("cfginit-bad") + "/config.json"
        writeFile(path, "{ not json")
        expectEqual(try ConfigInitializer.createIfMissing(path: path, salt: { "x" }), .alreadyExists)
        expectEqual(try String(contentsOfFile: path, encoding: .utf8), "{ not json")
    }

    test("the default salt is random: 32 hex chars, different each time") {
        let a = ConfigInitializer.randomSalt(), b = ConfigInitializer.randomSalt()
        expectEqual(a.count, 32)
        expect(a.allSatisfy { $0.isHexDigit }, "salt is hex")
        expect(a != b, "two salts differ")
    }
}
