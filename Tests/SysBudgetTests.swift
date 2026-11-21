//
//  SysBudgetTests.swift — the SYS panel's line budget through the core's
//  layout seam: the renderer's per-corner capacity in (a fake closure), the
//  placed SYS panel out. Degrades in a fixed order: flavour lines, then
//  account blocks fold into `+N ACCOUNTS` (red/amber accounts kept longest),
//  then whole sections; clock and date always stay.
//

import Foundation

extension FakeWorld {
    /// Four accounts: WRK calm, ALP red (95 %), BET amber (80 %), GAM calm.
    func writeFourAccounts() {
        writeCollectorState(collectorState([account(".claude", five: 37, seven: 12),
                                            account(".claude-alpha", five: 95, seven: 20),
                                            account(".claude-beta", five: 80, seven: 10),
                                            account(".claude-gamma", five: 10, seven: 10)]))
    }

    /// The placed SYS panel when the renderer offers `sysLines` lines for it.
    func sysPanel(maxLines sysLines: Int) -> Panel {
        let c = DiagnosticsCore(env: env, polling: .manual)
        c.pollNow()
        let placed = c.layout(lineCapacity: { _, cols in cols == PanelLayout.sysColumns ? sysLines : 40 })
        return placed.first { $0.panel.title == "SYS" }!.panel
    }
}

private func usagePart(_ p: Panel) -> [PanelLine] {
    guard let i = p.lines.firstIndex(where: { $0.label == "CLAUDE.USAGE" }) else { return [] }
    return Array(p.lines[i...].prefix { $0.label == "CLAUDE.USAGE" || $0.style != .section })
}

func sysBudgetTests() {
    test("SYS budget: the capacity is asked for each panel's current corner and width") {
        let w = FakeWorld("sysb-corner")
        let c = DiagnosticsCore(env: w.env, polling: .manual)
        var asked: [String] = []
        let placed = c.layout(lineCapacity: { corner, cols in asked.append("\(corner) \(cols)"); return 40 })
        let sys = placed.first { $0.panel.title == "SYS" }!, agents = placed.first { $0.panel.title == "AGENTS" }!
        expectEqual(Set(asked), ["\(sys.corner) 34", "\(agents.corner) 52"])
    }

    test("SYS budget: roomy budget shows everything; flavour lines are the first to go") {
        let w = FakeWorld("sysb-flavour")
        w.writeFourAccounts()
        let full = w.sysPanel(maxLines: 40)
        expectEqual(full.lines.count, 25)
        expectEqual(full.lines[22], .rule)
        let tight = w.sysPanel(maxLines: 24)
        expectEqual(tight.lines, Array(full.lines.prefix(22)))
        expectEqual(w.sysPanel(maxLines: 22).lines, Array(full.lines.prefix(22)))
    }

    test("SYS budget: account blocks fold into +N ACCOUNTS, red then amber accounts kept longest") {
        let w = FakeWorld("sysb-fold")
        w.writeFourAccounts()
        expectEqual(usagePart(w.sysPanel(maxLines: 21)), [
            .section("CLAUDE.USAGE"),
            .field("WRK.5H", "▓▓▓░░░░░░░  37% 2h14m"),
            .field("WRK.7D", "▓░░░░░░░░░  12% 4d03h"),
            .field("ALP.5H", "▓▓▓▓▓▓▓▓▓░  95% 2h14m", .alert),
            .field("ALP.7D", "▓▓░░░░░░░░  20% 4d03h"),
            .field("BET.5H", "▓▓▓▓▓▓▓▓░░  80% 2h14m", .warn),
            .field("BET.7D", "▓░░░░░░░░░  10% 4d03h"),
            .text("+1 ACCOUNT", .dim),
        ])
        expectEqual(w.sysPanel(maxLines: 21).lines.count, 21)
        expectEqual(usagePart(w.sysPanel(maxLines: 20)).map(\.label),
                    ["CLAUDE.USAGE", "ALP.5H", "ALP.7D", "BET.5H", "BET.7D", "+2 ACCOUNTS"])
        // Once an amber account is folded, the fold line says so; red wins over amber.
        expectEqual(usagePart(w.sysPanel(maxLines: 17)),
                    [.section("CLAUDE.USAGE"),
                     .field("ALP.5H", "▓▓▓▓▓▓▓▓▓░  95% 2h14m", .alert),
                     .field("ALP.7D", "▓▓░░░░░░░░  20% 4d03h"),
                     .text("+3 ACCOUNTS", .warn)])
        expectEqual(usagePart(w.sysPanel(maxLines: 16)), [.section("CLAUDE.USAGE"), .text("+4 ACCOUNTS", .alert)])
        for budget in 15...24 {
            expect(w.sysPanel(maxLines: budget).lines.count <= budget, "fits \(budget)")
        }
    }

    test("SYS budget: below that whole sections go (uptimes, power, vitals, calendar, usage); clock and date always stay") {
        let w = FakeWorld("sysb-sections")
        w.writeFourAccounts()
        expectEqual(w.sysPanel(maxLines: 13).lines.map(\.label), [
            "SYS.CLOCK", "SYS.DATE", "HOST.VITALS", "LOAD.AVG", "MEM.PRESSURE", "THERMAL",
            "POWER", "POWER.CELL", "CLAUDE.USAGE", "+4 ACCOUNTS", "CALENDAR", "COLLECTOR OFFLINE",
        ])
        expectEqual(w.sysPanel(maxLines: 10).lines.map(\.label), [
            "SYS.CLOCK", "SYS.DATE", "HOST.VITALS", "LOAD.AVG", "MEM.PRESSURE", "THERMAL",
            "CLAUDE.USAGE", "+4 ACCOUNTS", "CALENDAR", "COLLECTOR OFFLINE",
        ])
        expectEqual(w.sysPanel(maxLines: 4).lines.map(\.label), ["SYS.CLOCK", "SYS.DATE", "CLAUDE.USAGE", "+4 ACCOUNTS"])
        expectEqual(w.sysPanel(maxLines: 2).lines.map(\.label), ["SYS.CLOCK", "SYS.DATE"])
        expectEqual(w.sysPanel(maxLines: 0).lines.map(\.label), ["SYS.CLOCK", "SYS.DATE"])
    }

    test("SYS budget: debug lines go after flavour, before any account folds") {
        let w = FakeWorld("sysb-debug")
        w.writeFourAccounts()
        let c = DiagnosticsCore(env: w.env, polling: .manual, showDebug: true)
        c.pollNow()
        let full = c.layout(lineCapacity: { _, _ in 60 }).first!.panel
        let debug = full.lines.filter { $0.label.hasPrefix("DBG.") || $0.label == "DEBUG" }.count
        expect(debug > 0, "debug lines present")
        let tight = c.layout(lineCapacity: { _, cols in cols == 34 ? 22 : 40 }).first!.panel
        expect(!tight.lines.contains { $0.label.hasPrefix("DBG.") }, "debug dropped")
        expectEqual(tight.lines.filter { $0.label.hasSuffix(".5H") }.count, 4)
    }
}
