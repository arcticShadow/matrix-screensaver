//
//  TrustTests.swift — trusted-network names through the core's top seam: a
//  config with `trustedSSIDs`, an injected Wi-Fi reader and fake sessions in;
//  the AGENTS roster names, the `NET` tag and `networkTrust()` out.
//  SSIDs here are made up.
//

import Foundation

extension FakeWorld {
    /// Two live sessions: a repo and a worktree of another repo.
    func writeTrustSessions() {
        writeSession(FakeSession(pid: 1, cwd: "/home/someone/code/alpha-app", status: "busy", statusAgo: 10))
        writeSession(FakeSession(dir: ".claude-alpha", pid: 2, cwd: "/home/someone/code/beta-lib/.claude/worktrees/w1",
                                 status: "waiting", waitingFor: "approve Bash: make deploy", statusAgo: 40))
    }
    func trustCore() -> DiagnosticsCore {
        let core = DiagnosticsCore(env: agentsEnv(), polling: .manual)
        core.pollNow()
        return core
    }
}

func agents(_ core: DiagnosticsCore) -> Panel { core.panels().first { $0.title == "AGENTS" }! }
/// The display name of each roster row (first word of the label).
func rosterNames(_ p: Panel) -> [String] { rosterRows(p).map { String($0.label.split(separator: " ")[0]) } }
func isCodename(_ n: String) -> Bool {
    let parts = n.split(separator: "-").map(String.init)
    return parts.count == 2 && Codename.first.contains(parts[0]) && Codename.second.contains(parts[1])
}
let trustedConfig = #"{ "codenameSalt": "s", "trustedSSIDs": ["TrustedNet", "Lab 5G"] }"#

func trustTests() {
    test("trust: on a trusted Wi-Fi the roster shows real repo names, no NET tag") {
        let w = FakeWorld("trust-trusted")
        w.writeConfig(trustedConfig)
        w.wifi = "TrustedNet"
        w.writeTrustSessions()
        let core = w.trustCore()
        expectEqual(core.networkTrust(), .trusted)
        let p = agents(core)
        // Attention first; a worktree shows its repo's name.
        expectEqual(rosterNames(p), ["beta-lib", "alpha-app"])
        expectEqual(p.value(of: "NET"), nil)
    }

    test("trust: any trusted SSID in the list counts (exact match)") {
        let w = FakeWorld("trust-second")
        w.writeConfig(trustedConfig)
        w.writeTrustSessions()
        w.wifi = "Lab 5G"
        expectEqual(w.trustCore().networkTrust(), .trusted)
        w.wifi = "lab 5g"
        expectEqual(w.trustCore().networkTrust(), .untrusted)
        w.wifi = "TrustedNet-Guest"
        expectEqual(w.trustCore().networkTrust(), .untrusted)
    }

    test("trust: a readable but untrusted Wi-Fi gives codenames and no NET tag") {
        let w = FakeWorld("trust-untrusted")
        w.writeConfig(trustedConfig)
        w.wifi = "CoffeeShop"
        w.writeTrustSessions()
        let core = w.trustCore()
        expectEqual(core.networkTrust(), .untrusted)
        let p = agents(core)
        expect(rosterNames(p).allSatisfy(isCodename), "\(rosterNames(p))")
        expectEqual(p.value(of: "NET"), nil)
    }

    test("trust: an unreadable Wi-Fi name gives codenames plus NET: UNVERIFIED") {
        let w = FakeWorld("trust-unreadable")
        w.writeConfig(trustedConfig)
        w.wifi = nil
        w.writeTrustSessions()
        let core = w.trustCore()
        expectEqual(core.networkTrust(), .unverified)
        let p = agents(core)
        expect(rosterNames(p).allSatisfy(isCodename), "\(rosterNames(p))")
        expectEqual(p.line("NET"), .field("NET", "UNVERIFIED", .warn))
    }

    test("trust: an empty Wi-Fi name counts as unreadable") {
        let w = FakeWorld("trust-empty-name")
        w.writeConfig(trustedConfig)
        w.wifi = ""
        expectEqual(w.trustCore().networkTrust(), .unverified)
    }

    test("trust: a reader error gives codenames plus NET: UNVERIFIED, even after a trusted read") {
        let w = FakeWorld("trust-error")
        w.writeConfig(trustedConfig)
        w.wifi = "TrustedNet"
        w.writeTrustSessions()
        let core = w.trustCore()
        expectEqual(core.networkTrust(), .trusted)
        w.wifiFail = true
        w.advance(30)
        core.pollNow()
        expectEqual(core.networkTrust(), .unverified)
        let p = agents(core)
        expect(rosterNames(p).allSatisfy(isCodename), "\(rosterNames(p))")
        expectEqual(p.value(of: "NET"), "UNVERIFIED")
    }

    test("trust: before the first Wi-Fi read the core fails closed (UNVERIFIED)") {
        let w = FakeWorld("trust-first")
        w.writeConfig(trustedConfig)
        w.wifi = "TrustedNet"
        let core = DiagnosticsCore(env: w.agentsEnv(), polling: .manual)
        expectEqual(core.networkTrust(), .unverified)
        expectEqual(w.wifiCalls, 0)
    }

    test("trust: a Wi-Fi reading older than two poll intervals no longer counts") {
        let w = FakeWorld("trust-stale")
        w.writeConfig(trustedConfig)
        w.wifi = "TrustedNet"
        let core = w.trustCore()
        expectEqual(core.networkTrust(), .trusted)
        w.advance(59)
        expectEqual(core.networkTrust(), .trusted)
        w.advance(2)   // poller stalled: nothing re-read the name for 61 s
        expectEqual(core.networkTrust(), .unverified)
    }

    test("trust: empty trustedSSIDs means codenames always, and no NET tag") {
        for wifi in ["TrustedNet", nil] as [String?] {
            let w = FakeWorld("trust-no-list")
            w.writeConfig(#"{ "codenameSalt": "s", "trustedSSIDs": [] }"#)
            w.wifi = wifi
            w.writeTrustSessions()
            let core = w.trustCore()
            expectEqual(core.networkTrust(), .untrusted)
            let p = agents(core)
            expect(rosterNames(p).allSatisfy(isCodename), "\(rosterNames(p))")
            expectEqual(p.value(of: "NET"), nil)
        }
        // No config file at all behaves the same.
        let w = FakeWorld("trust-no-config")
        w.wifi = "TrustedNet"
        expectEqual(w.trustCore().networkTrust(), .untrusted)
    }

    test("trust: Wi-Fi going away switches to codenames within one 30 s poll") {
        let w = FakeWorld("trust-toggle")
        w.writeConfig(trustedConfig)
        w.wifi = "TrustedNet"
        w.writeTrustSessions()
        let core = w.trustCore()
        expectEqual(rosterNames(agents(core)), ["beta-lib", "alpha-app"])
        w.wifi = nil   // Wi-Fi turned off
        for _ in 0..<30 { w.advance(1); core.pollNow() }
        expectEqual(w.wifiCalls, 2)
        expect(rosterNames(agents(core)).allSatisfy(isCodename))
        expectEqual(agents(core).value(of: "NET"), "UNVERIFIED")
        w.wifi = "TrustedNet"   // and back on
        for _ in 0..<30 { w.advance(1); core.pollNow() }
        expectEqual(rosterNames(agents(core)), ["beta-lib", "alpha-app"])
        expectEqual(agents(core).value(of: "NET"), nil)
    }

    test("trust: Wi-Fi is polled every 30 s on the shared poller registry") {
        let w = FakeWorld("trust-interval")
        let src = PollSources.standard(w.env).first { $0.id == SourceIDs.wifi }
        expectEqual(src?.baseInterval, 30)
        expect(PollSources.order.contains(SourceIDs.wifi))
    }

    test("trust: the core's namer carries the trust decision (for other name consumers)") {
        let w = FakeWorld("trust-namer")
        w.writeConfig(trustedConfig)
        w.wifi = "TrustedNet"
        let core = w.trustCore()
        let rec = SessionRecord.fixture(cwd: "/home/someone/code/gamma")
        expectEqual(core.namer.name(for: rec), "gamma")
        w.wifi = "CoffeeShop"
        w.advance(30)
        core.pollNow()
        expect(isCodename(core.namer.name(for: rec)))
    }

    test("trust: long repo names are cut to the codename width; command text and paths still hidden") {
        let w = FakeWorld("trust-privacy")
        w.writeConfig(trustedConfig)
        w.wifi = "TrustedNet"
        w.writeSession(FakeSession(pid: 1, cwd: "/home/someone/code/an-extremely-long-repository-name",
                                   status: "waiting", waitingFor: "approve Bash: curl https://acme.example/tok",
                                   name: "fix acme billing"))
        w.writeSession(FakeSession(pid: 2, cwd: "/", status: "busy"))
        let p = agents(w.trustCore())
        let names = rosterNames(p)
        expectEqual(names.first, "an-extremely…")
        expect(names.allSatisfy { $0.count <= RepoName.maxLength }, "\(names)")
        let text = p.lines.map { "\($0.label) \($0.value)" }.joined(separator: "\n").lowercased()
        for leak in ["curl", "acme", "tok", "billing", "someone", "worktree", "/", "trustednet"] {
            expect(!text.contains(leak), "panel leaks '\(leak)':\n\(text)")
        }
    }

    test("trust: the Wi-Fi reading never prints its name") {
        let s = Sample(value: WiFiStatus(ssid: "TrustedNet"), fetchedAt: Date())
        expect(!"\(s)".contains("TrustedNet") && !String(reflecting: s).contains("TrustedNet"), "\(s)")
    }
}

extension SessionRecord {
    static func fixture(cwd: String) -> SessionRecord {
        SessionRecord(pid: 1, sessionId: "s-1", cwd: cwd, configDir: ".claude", kind: "interactive",
                      entrypoint: "cli", status: "busy", waitCategory: nil, statusSince: nil,
                      startedAt: nil, alive: true)
    }
}
