//
//  ConfigTests.swift — the config loader seam: path in, config + status out.
//

func configTests() {
    test("missing config file yields built-in defaults") {
        let home = makeTempDir("cfg-missing")
        let result = ConfigLoader.load(path: home + "/.config/matrix-diag/config.json")
        expectEqual(result.status, .missing)
        expectEqual(result.config, DiagConfig())
        expectEqual(result.config.overlay, true)
        expectEqual(result.config.trustedSSIDs, [])
    }

    test("\"overlay\": false turns the overlay off") {
        let path = makeTempDir("cfg-off") + "/config.json"
        writeFile(path, #"{ "overlay": false }"#)
        let result = ConfigLoader.load(path: path)
        expectEqual(result.status, .loaded)
        expectEqual(result.config.overlay, false)
    }

    test("malformed config falls back to defaults") {
        for (i, body) in ["{ not json", "[1, 2, 3]", "", "\"overlay\""].enumerated() {
            let path = makeTempDir("cfg-bad\(i)") + "/config.json"
            writeFile(path, body)
            let result = ConfigLoader.load(path: path)
            expectEqual(result.status, .malformed)
            expectEqual(result.config, DiagConfig())
        }
    }

    test("all spec keys are read") {
        let path = makeTempDir("cfg-full") + "/config.json"
        writeFile(path, #"""
        { "overlay": true,
          "trustedSSIDs": ["TrustedNet", "OtherNet"],
          "codenameSalt": "test-salt",
          "profileTags": { ".claude": "WRK", ".claude-home": "HOM" },
          "someFutureKey": 42 }
        """#)
        let result = ConfigLoader.load(path: path)
        expectEqual(result.status, .loaded)
        expectEqual(result.config, DiagConfig(overlay: true,
                                              trustedSSIDs: ["TrustedNet", "OtherNet"],
                                              codenameSalt: "test-salt",
                                              profileTags: [".claude": "WRK", ".claude-home": "HOM"]))
    }

    test("wrong-typed keys keep their defaults instead of failing the file") {
        let path = makeTempDir("cfg-types") + "/config.json"
        writeFile(path, #"{ "overlay": "no", "trustedSSIDs": "TrustedNet", "profileTags": [1] }"#)
        let result = ConfigLoader.load(path: path)
        expectEqual(result.status, .loaded)
        expectEqual(result.config, DiagConfig())
    }

    test("config path is under the given home") {
        expectEqual(ConfigLoader.defaultPath(home: "/home/tester"),
                    "/home/tester/.config/matrix-diag/config.json")
    }
}
