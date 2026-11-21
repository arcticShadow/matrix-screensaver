//
//  Naming.swift
//  Everything that decides what a session is CALLED on screen:
//  - `DisplayNamer.name(for:)`: the single decision point for a session's
//    display name: the real repo name on a trusted network (`NetworkTrust`,
//    see Network.swift), otherwise a codename (fail closed).
//  - `Codename`: stable `WORD-WORD` from a salted HMAC of the cwd.
//  - `RepoName`: the real repo name shown on a trusted network.
//  - `ProfileTags`: config dir basename -> 3-letter tag, so no folder name
//    reaches the screen.
//

import Foundation
import CommonCrypto

struct DisplayNamer {
    /// Codename salt: the config's `codenameSalt`, else a per-run random salt.
    let salt: String
    /// The network trust this namer applies. Defaults to fail closed; the
    /// core hands out namers carrying its current decision.
    var trust: NetworkTrust = .unverified

    init(salt: String?, trust: NetworkTrust = .unverified) {
        self.salt = salt ?? UUID().uuidString
        self.trust = trust
    }

    /// THE display name decision: real repo name only on a trusted network.
    func name(for session: SessionRecord) -> String {
        if trust.isTrusted, let real = RepoName.make(cwd: session.cwd) { return real }
        return Codename.make(cwd: session.cwd, salt: salt)
    }
}

enum RepoName {
    /// Same width budget as the longest codename, so roster rows still fit.
    static let maxLength = (Codename.first.map(\.count).max() ?? 6) + 1 + (Codename.second.map(\.count).max() ?? 6)

    /// The repo directory's name; for a `<repo>/.claude/worktrees/<wt>`
    /// worktree, the repo's. Cut to `maxLength` with an ellipsis. nil when
    /// there is no usable name (callers fall back to the codename).
    static func make(cwd: String) -> String? {
        var parts = cwd.split(separator: "/").map(String.init)
        if let i = parts.lastIndex(of: ".claude"), i > 0, i + 1 < parts.count, parts[i + 1] == "worktrees" {
            parts = Array(parts[..<i])
        }
        guard let last = parts.last else { return nil }
        let clean = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        guard !clean.isEmpty else { return nil }
        return clean.count <= maxLength ? clean : String(clean.prefix(maxLength - 1)) + "…"
    }
}

enum Codename {
    /// HMAC-SHA256(key: salt, msg: cwd); first two bytes pick the words.
    /// Strangers can't confirm a guessed repo without the salt.
    static func make(cwd: String, salt: String) -> String {
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let key = Array(salt.utf8), msg = Array(cwd.utf8)
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key, key.count, msg, msg.count, &mac)
        return first[Int(mac[0]) % first.count] + "-" + second[Int(mac[1]) % second.count]
    }

    // 64 + 64 words, each ≤ 6 letters so a roster row fits the panel width.
    static let first = [
        "IRON", "NEON", "CHROME", "VOID", "BLACK", "ZERO", "NULL", "CYBER",
        "STATIC", "SILVER", "COBALT", "CARBON", "RUST", "ACID", "GLASS", "BINARY",
        "DARK", "NIGHT", "ROGUE", "SHADOW", "PHASE", "PRISM", "QUARTZ", "ONYX",
        "VECTOR", "PIXEL", "FLUX", "NOVA", "ECHO", "DELTA", "OMEGA", "SIGMA",
        "RAZOR", "STEEL", "TITAN", "VAPOR", "PLASMA", "LASER", "SONIC", "ULTRA",
        "HYPER", "MICRO", "NANO", "OPTIC", "SYNTH", "ATOMIC", "RADIUM", "XENON",
        "ARGON", "COPPER", "NICKEL", "ZINC", "COBRA", "VIPER", "RAVEN", "WOLF",
        "LYNX", "HAWK", "FALCON", "ORBIT", "LUNAR", "SOLAR", "CRYPT", "FERRIC",
    ]
    static let second = [
        "MATRIX", "GRID", "NEXUS", "CORE", "NODE", "RELAY", "SPIRE", "VAULT",
        "ENGINE", "CIPHER", "SHARD", "BLADE", "DRIFT", "PULSE", "SPIKE", "FORGE",
        "HELIX", "KERNEL", "SOCKET", "RUNNER", "WRAITH", "SPRITE", "ORACLE", "ANCHOR",
        "BEACON", "BRIDGE", "CLOUD", "COMET", "CRANE", "CROWN", "DAGGER", "DYNAMO",
        "EMBER", "FRAME", "GATE", "HALO", "HARBOR", "HAVEN", "HOUND", "LANCE",
        "LENS", "LOOP", "MANTIS", "MIRROR", "MONK", "NEEDLE", "ORCHID", "PILOT",
        "QUILL", "RAPTOR", "ROTOR", "SABER", "SCRIPT", "SENTRY", "SPHINX", "SWITCH",
        "TEMPLE", "THREAD", "TOWER", "TRACE", "WARDEN", "ZENITH", "LATCH", "PRIMER",
    ]
}

enum ProfileTags {
    static let maxLength = 3

    /// `.claude` → WRK; config `profileTags` overrides by basename; otherwise
    /// the first three letters after `.claude-`, uppercased (AUX if none).
    static func tag(configDir: String, overrides: [String: String]) -> String {
        if let o = overrides[configDir] {
            let t = o.uppercased().filter { $0.isLetter || $0.isNumber }
            if !t.isEmpty { return String(t.prefix(maxLength)) }
        }
        if configDir == ".claude" { return "WRK" }
        let rest = configDir.dropFirst(".claude".count).filter { $0.isLetter }
        return rest.isEmpty ? "AUX" : String(rest.prefix(maxLength)).uppercased()
    }
}
