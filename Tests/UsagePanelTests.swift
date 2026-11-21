//
//  UsagePanelTests.swift — seam 1 for the usage block: a collector state file
//  in a fake home (written with the shared schema) + the injected clock in;
//  the SYS panel's CLAUDE.USAGE lines out (DiagnosticsCore, manual polling).
//

import Foundation

extension FakeWorld {
    func writeCollectorState(_ s: CollectorState) {
        let path = CollectorStateStore.defaultPath(home: home)
        writeFile(path, "")
        try? CollectorStateStore.encode(s).write(to: URL(fileURLWithPath: path))
    }

    func addSessionFile(_ dir: String) { writeFile("\(home)/\(dir)/sessions/123.json", "{}") }

    /// A healthy collector state as of `now`, with these accounts.
    func collectorState(_ accounts: [AccountUsage], usageAge: TimeInterval = 30) -> CollectorState {
        var sched = SourceSchedule(baseInterval: 300)
        sched.recordSuccess(at: now.addingTimeInterval(-usageAge), duration: 1.5)
        return CollectorState(generatedAt: now.addingTimeInterval(-usageAge),
                              schedules: [CollectorSourceIDs.usage: sched],
                              usage: UsageSection(generatedAt: now.addingTimeInterval(-usageAge),
                                                  accounts: accounts))
    }

    func account(_ dir: String, five: Double = 37, seven: Double = 12, token: AccountUsage.TokenState = .ok,
                 extra: ExtraUsage? = nil, fetchedAgo: TimeInterval = 30) -> AccountUsage {
        AccountUsage(dir: dir, token: token, tokenExpiresAt: now.addingTimeInterval(3600),
                     generatedAt: now.addingTimeInterval(-fetchedAgo),
                     fiveHour: UsageWindow(utilization: five, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)),
                     sevenDay: UsageWindow(utilization: seven, resetsAt: now.addingTimeInterval(4 * 86400 + 3 * 3600 + 60)),
                     extra: extra)
    }
}

private func sysPanel(_ w: FakeWorld) -> Panel {
    let c = DiagnosticsCore(env: w.env, polling: .manual)
    c.pollNow()
    return c.panels()[0]
}

private func usageLines(_ p: Panel) -> [PanelLine] {
    guard let i = p.lines.firstIndex(where: { $0.label == "CLAUDE.USAGE" }) else { return [] }
    var out = [p.lines[i]]
    for l in p.lines[(i + 1)...] {
        if l.style == .section || l.style == .rule { break }
        out.append(l)
    }
    return out
}

func usagePanelTests() {
    test("usage block: 5H and 7D meters with reset countdowns, labelled by profile tag") {
        let w = FakeWorld("usage-basic")
        w.writeConfig(#"{ "profileTags": { ".claude-alpha": "ZED" } }"#)
        w.writeCollectorState(w.collectorState([w.account(".claude"), w.account(".claude-alpha", five: 3, seven: 100)]))
        expectEqual(usageLines(sysPanel(w)), [
            .section("CLAUDE.USAGE"),
            .field("WRK.5H", "▓▓▓░░░░░░░  37% 2h14m"),
            .field("WRK.7D", "▓░░░░░░░░░  12% 4d03h"),
            .field("ZED.5H", "▓░░░░░░░░░   3% 2h14m"),
            .field("ZED.7D", "▓▓▓▓▓▓▓▓▓▓ 100% 4d03h", .alert),
        ])
    }

    test("meter colour thresholds: amber at 75%, red at 90%") {
        let cases: [(Double, String, Severity)] = [
            (74, "▓▓▓▓▓▓▓░░░  74%", .normal),
            (75, "▓▓▓▓▓▓▓░░░  75%", .warn),
            (89, "▓▓▓▓▓▓▓▓░░  89%", .warn),
            (90, "▓▓▓▓▓▓▓▓▓░  90%", .alert),
            (0, "░░░░░░░░░░   0%", .normal),
        ]
        for (pct, meter, sev) in cases {
            let w = FakeWorld("usage-thr")
            w.writeCollectorState(w.collectorState([w.account(".claude", five: pct)]))
            expectEqual(sysPanel(w).line("WRK.5H"), .field("WRK.5H", meter + " 2h14m", sev))
        }
    }

    test("XTRA line only when extra usage is enabled; amounts in currency units") {
        let w = FakeWorld("usage-xtra")
        w.writeCollectorState(w.collectorState([
            w.account(".claude", extra: ExtraUsage(enabled: true, usedMinor: 1240, limitMinor: 5000,
                                                   currency: "USD", decimalPlaces: 2)),
            w.account(".claude-alpha", extra: ExtraUsage(enabled: true, usedMinor: 1240, limitMinor: nil,
                                                         currency: "NZD", decimalPlaces: 2)),
            w.account(".claude-beta", extra: ExtraUsage(enabled: false, usedMinor: nil, limitMinor: nil,
                                                        currency: "USD", decimalPlaces: 2)),
        ]))
        let p = sysPanel(w)
        expectEqual(p.line("WRK.XTRA"), .field("WRK.XTRA", "12.40 / 50 USD"))
        expectEqual(p.line("ALP.XTRA"), .field("ALP.XTRA", "12.40 NZD"))
        expect(p.line("BET.XTRA") == nil, "no XTRA line when disabled")
        expect(p.line("BET.5H") != nil)
    }

    test("an account with no token and no sessions is hidden; with sessions it shows NO TOKEN") {
        let w = FakeWorld("usage-hide")
        w.addSessionFile(".claude-busy")
        w.writeCollectorState(w.collectorState([
            w.account(".claude"),
            AccountUsage(dir: ".claude-busy", token: .none),
            AccountUsage(dir: ".claude-dormant", token: .none),
        ]))
        let p = sysPanel(w)
        expectEqual(p.line("BUS.TOKEN"), .field("BUS.TOKEN", "NO TOKEN", .dim))
        expect(!p.lines.contains { $0.label.hasPrefix("DOR.") }, "dormant token-less account hidden")
    }

    test("expired token marks the account STALE (meters dimmed)") {
        let w = FakeWorld("usage-expired")
        w.writeCollectorState(w.collectorState([w.account(".claude", five: 95, token: .expired, fetchedAgo: 7200)]))
        let p = sysPanel(w)
        expectEqual(p.line("WRK.STATE"), .field("WRK.STATE", "STALE", .warn))
        expectEqual(p.line("WRK.5H")?.severity, .dim)
    }

    test("an account whose own data is old is STALE even with a valid token") {
        let w = FakeWorld("usage-acct-old")
        w.writeCollectorState(w.collectorState([w.account(".claude", fetchedAgo: 601), w.account(".claude-alpha")]))
        let p = sysPanel(w)
        expectEqual(p.line("WRK.STATE"), .field("WRK.STATE", "STALE", .warn))
        expect(p.line("ALP.STATE") == nil, "fresh account not stale")
    }

    test("missing state file -> COLLECTOR OFFLINE; the rest of SYS keeps working") {
        let w = FakeWorld("usage-nofile")
        let p = sysPanel(w)
        expectEqual(usageLines(p), [.section("CLAUDE.USAGE"), .text("COLLECTOR OFFLINE", .dim)])
        expectEqual(p.value(of: "SYS.CLOCK"), "14:30:05")
        expectEqual(p.value(of: "LOAD.AVG"), "0.42 0.38 0.31")
    }

    test("state file without a usage section -> COLLECTOR OFFLINE") {
        let w = FakeWorld("usage-nosection")
        w.writeCollectorState(CollectorState(generatedAt: w.now))
        expectEqual(usageLines(sysPanel(w)), [.section("CLAUDE.USAGE"), .text("COLLECTOR OFFLINE", .dim)])
    }

    test("unreadable state file -> COLLECTOR OFFLINE until a good read; then the last good read is kept") {
        let w = FakeWorld("usage-corrupt")
        writeFile(CollectorStateStore.defaultPath(home: w.home), "{ not json")
        let c = DiagnosticsCore(env: w.env, polling: .manual)
        c.pollNow()
        expect(c.panels()[0].line("COLLECTOR OFFLINE") != nil, "offline while unreadable")
        w.writeCollectorState(w.collectorState([w.account(".claude")]))
        w.advance(60); c.pollNow()
        expect(c.panels()[0].line("WRK.5H") != nil, "shown after a good read")
        writeFile(CollectorStateStore.defaultPath(home: w.home), "{ half a fi")
        w.advance(60); c.pollNow()
        expect(c.panels()[0].line("WRK.5H") != nil, "a bad read keeps the last good state")
    }

    test("old usage section gets the staleness marker") {
        let w = FakeWorld("usage-old")
        w.writeCollectorState(w.collectorState([w.account(".claude", fetchedAgo: 720)], usageAge: 720))
        expectEqual(sysPanel(w).line("CLAUDE.USAGE"), .section("CLAUDE.USAGE", marker: "·12m"))
        let fresh = FakeWorld("usage-fresh")
        fresh.writeCollectorState(fresh.collectorState([fresh.account(".claude")], usageAge: 599))
        expectEqual(sysPanel(fresh).line("CLAUDE.USAGE"), .section("CLAUDE.USAGE"))
    }

    test("the state file is re-read on the 5 s poll") {
        let w = FakeWorld("usage-reread")
        let c = DiagnosticsCore(env: w.env, polling: .manual)
        c.pollNow()
        expectEqual(c.panels()[0].line("COLLECTOR OFFLINE"), .text("COLLECTOR OFFLINE", .dim))
        w.writeCollectorState(w.collectorState([w.account(".claude")]))
        w.advance(2); c.pollNow()
        expect(c.panels()[0].line("WRK.5H") == nil, "not re-read before 5 s")
        w.advance(3.1); c.pollNow()
        expect(c.panels()[0].line("WRK.5H") != nil, "re-read after 5 s")
    }

    test("folder names never reach the panel") {
        let w = FakeWorld("usage-private")
        w.addSessionFile(".claude-secretclient")
        w.writeCollectorState(w.collectorState([w.account(".claude-secretclient"),
                                                AccountUsage(dir: ".claude-otherthing", token: .error)]))
        let p = sysPanel(w)
        for l in p.lines {
            expect(!l.label.contains("secret") && !l.value.contains("secret") && !l.label.contains(".claude"),
                   "leaked folder name in \(l)")
        }
        expectEqual(p.line("OTH.USAGE"), .field("OTH.USAGE", "NO SIGNAL", .dim))
    }
}
