//
//  RefreshTests.swift — token refresh via `claude -p` (#10).
//  Collector side: FakeCollector (settable clock, fake keychain/HTTP and a fake
//  process runner that plays Claude Code refreshing its own token) in; the
//  state file, the launched process specs and the log out. Saver side: a
//  collector state listing refresh session ids + session files in; the AGENTS
//  panel out. No real `claude` is ever run here.
//

import Foundation

extension FakeCollector {
    /// One healthy fetch now, with a token that expires in `expiresIn`.
    func freshAccount(_ dir: String, token: String, expiresIn: TimeInterval = 600) {
        addAccount(dir, token: token, expiresIn: expiresIn)
        responses[token] = (200, usageBody(five: 40, seven: 20))
    }
    func refreshSessions() -> [RefreshSession] { state()?.refresh?.sessions ?? [] }
}

func refreshTests() {
    let hour: TimeInterval = 3600

    test("refresh: none while usage data is under 2 h stale, even with an expired token") {
        let w = FakeCollector("ref-young")
        w.freshAccount(".claude", token: "tok-w")
        w.run()
        let fetched = w.account(".claude")?.generatedAt
        // Token expires after 10 min; keep running the collector every ~5 min.
        while w.now < fetched!.addingTimeInterval(2 * hour - 301) {
            w.advance(301); w.run()
        }
        expectEqual(w.account(".claude")?.token, .expired)
        expectEqual(w.processes.count, 0)
        expectEqual(w.refreshSessions(), [])
    }

    test("refresh: past 2 h stale, claude -p refreshes and usage recovers in the same run") {
        let w = FakeCollector("ref-due")
        w.freshAccount(".claude", token: "tok-w")
        w.run()
        w.advance(2 * hour + 1)
        let r = w.run()
        expectEqual(r.failed, [])
        expectEqual(w.processes.count, 1)
        let a = w.account(".claude")
        expectEqual(a?.token, .ok)
        expectEqual(a?.fiveHour?.utilization, 55)
        expectEqual(a?.generatedAt, w.state()?.usage?.generatedAt)
        expect(a!.generatedAt! > w.now.addingTimeInterval(-60), "fresh data after the refresh")
        // The command: print mode, small model, trivial prompt, chosen id, no
        // tools/MCP/hooks, nothing persisted.
        let p = w.processes[0]
        expectEqual(p.executable, "/opt/fake/bin/claude")
        let args = p.arguments
        expectEqual(args.first, "-p")
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        expectEqual(value("--model"), "haiku")
        expectEqual(value("--session-id"), "00000000-0000-4000-8000-000000000001")
        expectEqual(value("--tools"), "")
        for flag in ["--no-session-persistence", "--strict-mcp-config", "--safe-mode"] {
            expect(args.contains(flag), "missing \(flag)")
        }
        expect(!args.contains("--bare"), "--bare skips keychain reads")
        expect(p.timeout > 0 && p.timeout <= 180, "bounded run time")
        expectEqual(p.workingDirectory, (w.statePath as NSString).deletingLastPathComponent)
    }

    test("refresh: never treats a still-fresh account or one without a token as due") {
        let w = FakeCollector("ref-healthy")
        w.addAccount(".claude", token: "tok-w", expiresIn: 30 * hour)
        w.responses["tok-w"] = (200, usageBody(five: 1, seven: 1))
        w.addAccount(".claude-idle")
        for _ in 0..<40 { w.run(); w.advance(301) }
        expectEqual(w.processes.count, 0)
    }

    test("refresh: a valid-looking token the endpoint rejects (401) is refreshed once data is 2 h stale") {
        let w = FakeCollector("ref-401")
        w.freshAccount(".claude", token: "tok-w", expiresIn: 30 * hour)
        w.run()
        w.responses["tok-w"] = (401, "{}")
        w.advance(hour); w.run()
        expectEqual(w.processes.count, 0)
        w.advance(hour + 1); w.run()
        expectEqual(w.processes.count, 1)
        expectEqual(w.account(".claude")?.token, .ok)
    }

    test("refresh: a network outage is not a token problem, so no refresh") {
        let w = FakeCollector("ref-network")
        w.freshAccount(".claude", token: "tok-w", expiresIn: 30 * hour)
        w.run()
        w.networkDown = true
        w.advance(3 * hour); w.run(force: true)
        expectEqual(w.processes.count, 0)
    }

    test("refresh: at most once per hour per account") {
        let w = FakeCollector("ref-hourly")
        w.freshAccount(".claude", token: "tok-w")
        w.run()
        w.onRefresh = { _ in ProcessResult(status: 1, timedOut: false) }   // refresh fails
        w.advance(2 * hour + 1); w.run()
        expectEqual(w.processes.count, 1)
        let first = w.refreshSessions().first!.startedAt
        while w.now < first.addingTimeInterval(hour - 301) {
            w.advance(301); w.run(force: true)
        }
        expectEqual(w.processes.count, 1)
        w.advance(301); w.run(force: true)
        expectEqual(w.processes.count, 2)
        expectEqual(w.refreshSessions().map(\.outcome), ["exit 1", "exit 1"])
        expectEqual(w.account(".claude")?.token, .expired)
    }

    test("refresh: each account is refreshed with its own config dir; the default dir leaves CLAUDE_CONFIG_DIR unset") {
        let w = FakeCollector("ref-dirs")
        w.inheritedEnv = ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": "/elsewhere/.claude-beta",
                          "ANTHROPIC_API_KEY": "sk-x", "CLAUDE_CODE_OAUTH_TOKEN": "x", "CLAUDECODE": "1",
                          "LANG": "en_NZ.UTF-8"]
        w.freshAccount(".claude", token: "tok-w")
        w.freshAccount(".claude-alpha", token: "tok-a")
        w.freshAccount(".claude-beta", token: "tok-b", expiresIn: 30 * hour)
        w.run()
        w.advance(2 * hour + 1); w.run()
        expectEqual(w.processes.count, 2)
        let byDir = Dictionary(uniqueKeysWithValues: w.processes.map { (w.dir(of: $0), $0.environment) })
        expectEqual(Set(byDir.keys), [".claude", ".claude-alpha"])
        expectEqual(byDir[".claude-alpha"]?["CLAUDE_CONFIG_DIR"], "\(w.home)/.claude-alpha")
        expectEqual(byDir[".claude"]?["CLAUDE_CONFIG_DIR"], nil)
        for env in byDir.values {
            // gws incident rule: USER and HOME always passed through.
            expectEqual(env["HOME"], w.home)
            expectEqual(env["USER"], "someone")
            expectEqual(env["LOGNAME"], "someone")
            expectEqual(env["PATH"], "/usr/bin:/bin")
            expectEqual(env["LANG"], "en_NZ.UTF-8")
            for k in ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDECODE"] {
                expect(env[k] == nil, "\(k) must not reach the refresh run")
            }
        }
        expectEqual(w.account(".claude-alpha")?.token, .ok)
        expectEqual(w.account(".claude")?.token, .ok)
    }

    test("refresh: a minimal launchd environment still gets HOME, USER and a PATH") {
        let w = FakeCollector("ref-minenv")
        w.inheritedEnv = [:]
        w.freshAccount(".claude", token: "tok-w")
        w.run()
        w.advance(2 * hour + 1); w.run()
        let env = w.processes.first?.environment ?? [:]
        expectEqual(env["HOME"], w.home)
        expectEqual(env["USER"], "someone")
        expect((env["PATH"] ?? "").contains("/usr/bin"), "PATH defaulted")
    }

    test("refresh: the session id is in the state file before claude starts, then kept with its outcome") {
        let w = FakeCollector("ref-record")
        w.freshAccount(".claude-alpha", token: "tok-a")
        w.run()
        w.advance(2 * hour + 1); w.run()
        let id = "00000000-0000-4000-8000-000000000001"
        let atLaunch = w.stateAtLaunch.first??.refresh?.sessions ?? []
        expectEqual(atLaunch.map(\.sessionId), [id])
        expectEqual(atLaunch.first?.outcome, "running")
        // The saver polls the state file every 5 s: wait longer than that
        // before launching so the id is known before the session file appears.
        expect(w.sleeps.contains { $0 > 5 }, "lead time before launch: \(w.sleeps)")
        let rec = w.refreshSessions()
        expectEqual(rec.map(\.sessionId), [id])
        expectEqual(rec.first?.dir, ".claude-alpha")
        expectEqual(rec.first?.outcome, "ok")
        expect(rec.first?.finishedAt != nil)
    }

    test("refresh: timeouts are recorded; no claude binary means no run (still rate limited)") {
        let w = FakeCollector("ref-fail")
        w.freshAccount(".claude", token: "tok-w")
        w.run()
        w.onRefresh = { _ in ProcessResult(status: 15, timedOut: true) }
        w.advance(2 * hour + 1); w.run()
        expectEqual(w.refreshSessions().last?.outcome, "timeout")

        let n = FakeCollector("ref-nobin")
        n.claudePath = nil
        n.freshAccount(".claude", token: "tok-w")
        n.run()
        n.advance(2 * hour + 1); n.run()
        expectEqual(n.processes.count, 0)
        expectEqual(n.refreshSessions().map(\.outcome), ["no claude"])
        expect(n.log.lines.contains { $0.contains("claude not found") }, "missing binary logged")
        let logged = n.log.lines.count
        n.advance(301); n.run()
        expectEqual(n.log.lines.count, logged)
    }

    test("refresh: old session records are pruned after 7 days") {
        let w = FakeCollector("ref-prune")
        w.freshAccount(".claude", token: "tok-w")
        w.run()
        w.advance(2 * hour + 1); w.run()
        expectEqual(w.refreshSessions().count, 1)
        // Token keeps working for 8 h; then it expires and stays unused.
        w.advance(8 * 86400); w.run(force: true)
        let recs = w.refreshSessions()
        expect(!recs.contains { $0.sessionId.hasSuffix("000000000001") }, "week-old record pruned")
    }

    test("refresh: logged by profile tag only, never session ids, dirs or tokens") {
        let w = FakeCollector("ref-log")
        w.config.profileTags = [".claude-alpha": "ZED"]
        w.freshAccount(".claude-alpha", token: "tok-secret")
        w.run()
        w.advance(2 * hour + 1); w.run()
        let text = w.log.lines.joined(separator: "\n")
        expect(text.contains("ZED token refresh ok"), text)
        for banned in ["00000000-", ".claude", "tok-", w.home] {
            expect(!text.contains(banned), "log must not contain \(banned)")
        }
    }

    // MARK: Saver side

    test("agents: sessions listed as collector refresh sessions are excluded from totals and roster") {
        let w = FakeWorld("agents-refresh-hidden")
        let hidden = "11111111-2222-4333-8444-555555555555"
        w.writeSession(FakeSession(pid: 41, status: "busy"))
        w.writeSession(FakeSession(dir: ".claude-alpha", pid: 42, status: "busy", kind: "print",
                                   entrypoint: "sdk-cli", sessionId: hidden))
        var st = w.collectorState([])
        st.refresh = RefreshSection(sessions: [
            RefreshSession(sessionId: hidden, dir: ".claude-alpha", startedAt: w.now.addingTimeInterval(-3),
                           outcome: "running"),
        ])
        w.writeCollectorState(st)
        let p = w.agentsPanel()
        expectEqual(p.value(of: "RUNNING"), "1")
        expectEqual(p.value(of: "ACTIVE"), "1")
        expectEqual(rosterRows(p).count, 1)

        // Without the collector record the same session would be counted.
        let v = FakeWorld("agents-refresh-visible")
        v.writeSession(FakeSession(pid: 41, status: "busy"))
        v.writeSession(FakeSession(dir: ".claude-alpha", pid: 42, status: "busy", kind: "print",
                                   entrypoint: "sdk-cli", sessionId: hidden))
        v.writeCollectorState(v.collectorState([]))
        expectEqual(v.agentsPanel().value(of: "RUNNING"), "2")
    }
}
