//
//  AlertsTests.swift — attention alerts through the core's top seam: fake
//  session files + injected clock in; the takeover banner decision
//  (`DiagnosticsCore.banner()`, asked once per frame) and the AGENTS panel's
//  pulse marks out. Drawing is verified with the snapshot harness.
//

import Foundation

extension FakeWorld {
    /// A manual-polling core with a fixed codename salt, polled once.
    func alertsCore(dead: Set<Int32> = []) -> DiagnosticsCore {
        writeConfig(#"{ "codenameSalt": "alerts-test" }"#)
        let core = DiagnosticsCore(env: agentsEnv(dead: dead), polling: .manual)
        core.pollNow()
        return core
    }

    /// Advance the clock in frame-sized steps (re-polling as the poller
    /// would), asking for the banner every step like the renderer does.
    /// Returns the banner seen at the last step.
    @discardableResult
    func run(_ core: DiagnosticsCore, for seconds: TimeInterval, step: TimeInterval = 0.25) -> AlertBanner? {
        var last: AlertBanner? = core.banner()
        var t = 0.0
        while t < seconds - 1e-9 {
            advance(step); t += step
            core.pollNow()
            last = core.banner()
        }
        return last
    }
}

func codename(_ cwd: String) -> String { Codename.make(cwd: cwd, salt: "alerts-test") }

func alertsTests() {
    test("alerts: no banner for a session that has waited < 30 s; banner once it reaches 30 s") {
        let w = FakeWorld("alerts-threshold")
        w.writeSession(FakeSession(pid: 1, cwd: "/work/one", status: "waiting",
                                   waitingFor: "permission prompt", statusAgo: 25))
        let core = w.alertsCore()
        expectEqual(core.banner(), nil)
        expectEqual(w.run(core, for: 4.5), nil)        // 29.5 s waited
        let b = w.run(core, for: 1.0)                   // 30.5 s waited
        expectEqual(b?.text, "⚠ OPERATOR REQUIRED — \(codename("/work/one")) — APPROVE")
    }

    test("alerts: banner shows for the configured duration, then hides until the next period") {
        let w = FakeWorld("alerts-period")
        w.writeSession(FakeSession(pid: 1, cwd: "/work/one", status: "waiting",
                                   waitingFor: "approve Bash: rm -rf /tmp/x", statusAgo: 45))
        let core = w.alertsCore()
        expect(core.banner() != nil, "eligible at the first frame: shown immediately")
        expect(w.run(core, for: AlertsCfg.bannerDuration - 0.5) != nil, "still within the duration")
        expectEqual(w.run(core, for: 1.0), nil)        // past the duration
        expectEqual(w.run(core, for: AlertsCfg.bannerPeriod - AlertsCfg.bannerDuration - 1.0), nil)
        expect(w.run(core, for: 0.5) != nil, "fires again one period after the first banner")
        expect(w.run(core, for: AlertsCfg.bannerDuration - 1.0) != nil)
        expectEqual(w.run(core, for: 1.5), nil)
    }

    test("alerts: banner cycles oldest-first through the waiting sessions") {
        let w = FakeWorld("alerts-cycle")
        w.writeSession(FakeSession(pid: 1, cwd: "/work/newer", status: "waiting",
                                   waitingFor: "input needed", statusAgo: 40))
        w.writeSession(FakeSession(pid: 2, cwd: "/work/oldest", status: "waiting",
                                   waitingFor: "approve Bash: make deploy", statusAgo: 300))
        w.writeSession(FakeSession(pid: 3, cwd: "/work/middle", status: "waiting",
                                   waitingFor: "approve plan", statusAgo: 120))
        w.writeSession(FakeSession(pid: 4, cwd: "/work/fresh", status: "waiting",
                                   waitingFor: "permission prompt", statusAgo: 5))   // too fresh at first
        w.writeSession(FakeSession(pid: 5, cwd: "/work/busy", status: "busy", statusAgo: 600))
        let core = w.alertsCore()
        var names: [String?] = [core.banner()?.name]
        for _ in 0..<4 { names.append(w.run(core, for: AlertsCfg.bannerPeriod)?.name) }
        expectEqual(names, ["/work/oldest", "/work/middle", "/work/newer", "/work/fresh", "/work/oldest"]
            .map { codename($0) })
    }

    test("alerts: banner stops once nothing is waiting") {
        let w = FakeWorld("alerts-stop")
        w.writeSession(FakeSession(pid: 1, cwd: "/work/one", status: "waiting",
                                   waitingFor: "input needed", statusAgo: 60))
        let core = w.alertsCore()
        expect(core.banner() != nil)
        w.writeSession(FakeSession(pid: 1, cwd: "/work/one", status: "busy", statusAgo: 0))
        expect(w.run(core, for: 2.5) == nil, "hidden mid-banner once the session is answered")
        expectEqual(w.run(core, for: 3 * AlertsCfg.bannerPeriod), nil)
    }

    test("alerts: a session that dies while waiting (ghost) never fires the banner") {
        let w = FakeWorld("alerts-ghost")
        w.writeSession(FakeSession(pid: 1, cwd: "/work/one", status: "waiting",
                                   waitingFor: "input needed", statusAgo: 90))
        let core = w.alertsCore(dead: [1])
        expectEqual(core.banner(), nil)
    }

    test("alerts: banner text contains only the name and the category, never command text") {
        let w = FakeWorld("alerts-privacy")
        w.writeSession(FakeSession(pid: 1, cwd: "/home/someone/secret-repo", status: "waiting",
                                   waitingFor: "approve Bash: curl https://internal.example/token?x=1",
                                   statusAgo: 90, name: "secret task title"))
        let core = w.alertsCore()
        let b = core.banner()
        expectEqual(b?.text, "⚠ OPERATOR REQUIRED — \(codename("/home/someone/secret-repo")) — APPROVE BASH")
        for leak in ["curl", "internal", "token", "secret", "/home", "someone"] {
            expect(!(b?.text ?? "").contains(leak), "banner leaked \(leak)")
        }
    }

    test("alerts: the overlay off means no banner") {
        let w = FakeWorld("alerts-off")
        w.writeSession(FakeSession(pid: 1, status: "waiting", waitingFor: "input needed", statusAgo: 90))
        w.writeConfig(#"{ "overlay": false }"#)
        let core = DiagnosticsCore(env: w.agentsEnv(), polling: .manual)
        core.pollNow()
        expectEqual(core.banner(), nil)
    }

    test("alerts: AGENTS border and ATTENTION row pulse while any session is in ATTENTION") {
        let w = FakeWorld("alerts-pulse")
        w.writeSession(FakeSession(pid: 1, status: "busy"))
        w.writeSession(FakeSession(pid: 2, status: "waiting", waitingFor: "input needed", statusAgo: 3))
        let p = w.agentsPanel()
        expect(p.pulse, "panel border pulses (even before the 30 s banner threshold)")
        expectEqual(p.lines.filter(\.pulse).map(\.label), ["ATTENTION"])
    }

    test("alerts: nothing pulses without an ATTENTION session") {
        let w = FakeWorld("alerts-nopulse")
        w.writeSession(FakeSession(pid: 1, status: "busy"))
        w.writeSession(FakeSession(pid: 2, status: "idle", statusAgo: 30))
        w.writeSession(FakeSession(pid: 3, status: "waiting", waitingFor: "input needed"))   // ghost
        let p = w.agentsPanel(dead: [3])
        expect(!p.pulse)
        expect(p.lines.allSatisfy { !$0.pulse })
    }
}
