//
//  AgentsTests.swift — the AGENTS panel through the core's top seam: a fake
//  home tree of `~/.claude*` dirs with `sessions/*.json`, an injected clock and
//  an injected liveness checker in; the AGENTS panel model out.
//

import Foundation

/// One fake session file. Defaults describe a live interactive CLI session
/// in `~/.claude` that went idle 60 s ago.
struct FakeSession {
    var dir = ".claude"
    var pid: Int32
    var cwd = "/work/alpha-repo"
    var status = "idle"
    var waitingFor: String? = nil
    var kind = "interactive"
    var entrypoint = "cli"
    /// Seconds before the world's `now` that the status last changed.
    var statusAgo: TimeInterval = 60
    var procStart = "Fri Nov 20 19:37:21 2026"
    var sessionId = UUID().uuidString.lowercased()
    var name = "secret task title"
}

extension FakeWorld {
    func sessionsDir(_ dir: String) -> String { "\(home)/\(dir)/sessions" }

    func writeSession(_ s: FakeSession) {
        let ms = { (d: Date) in Int64(d.timeIntervalSince1970 * 1000) }
        var obj: [String: Any] = [
            "pid": Int(s.pid), "sessionId": s.sessionId, "cwd": s.cwd, "status": s.status,
            "kind": s.kind, "entrypoint": s.entrypoint, "procStart": s.procStart,
            "startedAt": ms(now.addingTimeInterval(-7200)), "version": "2.1.330",
            "updatedAt": ms(now.addingTimeInterval(-s.statusAgo)),
            "statusUpdatedAt": ms(now.addingTimeInterval(-s.statusAgo)),
            "name": s.name, "nameSource": "derived", "pidDomain": "darwin",
        ]
        if let wf = s.waitingFor { obj["waitingFor"] = wf }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        writeFile("\(sessionsDir(s.dir))/\(s.pid).json", String(data: data, encoding: .utf8)!)
    }

    /// The environment with an injected liveness checker: pids in `dead` are
    /// gone, everything else is alive with a matching start time.
    func agentsEnv(dead: Set<Int32> = []) -> DiagnosticsEnvironment {
        var e = env
        e.isProcessAlive = { pid, _ in !dead.contains(pid) }
        return e
    }

    /// A manual-polling core that has polled once.
    func agentsPanel(dead: Set<Int32> = [], maxLines: Int = 40) -> Panel {
        let core = DiagnosticsCore(env: agentsEnv(dead: dead), polling: .manual)
        core.agentsMaxLines = maxLines
        core.pollNow()
        return core.panels().first { $0.title == "AGENTS" }!
    }
}

/// Lines after the ROSTER section heading.
func rosterLines(_ p: Panel) -> [PanelLine] {
    guard let i = p.lines.firstIndex(where: { $0.style == .section && $0.label == "ROSTER" }) else { return [] }
    return Array(p.lines[(i + 1)...])
}
func rosterRows(_ p: Panel) -> [PanelLine] { rosterLines(p).filter { $0.style == .field } }

func agentsTests() {
    test("agents: one busy session in ~/.claude is RUNNING and ACTIVE") {
        let w = FakeWorld("agents-one")
        w.writeSession(FakeSession(pid: 101, status: "busy"))
        let p = w.agentsPanel()
        expectEqual(p.value(of: "AGENT.LINK"), "ONLINE")
        expectEqual(p.value(of: "RUNNING"), "1")
        expectEqual(p.value(of: "ACTIVE"), "1")
        expectEqual(p.value(of: "ATTENTION"), "0")
        expectEqual(p.value(of: "AWAITING"), "0")
        expectEqual(p.value(of: "DORMANT"), "0")
        expectEqual(rosterRows(p).count, 1)
    }

    test("agents: discovers every ~/.claude* dir with sessions/, skipping decoys") {
        let w = FakeWorld("agents-discovery")
        w.writeSession(FakeSession(dir: ".claude", pid: 201, status: "busy"))
        w.writeSession(FakeSession(dir: ".claude-alpha", pid: 202, status: "busy"))
        w.writeSession(FakeSession(dir: ".claude-lab", pid: 203, status: "busy"))
        // Decoys: top-level files, a config dir with no sessions/, non-session files.
        writeFile("\(w.home)/.claude.json", "{}")
        writeFile("\(w.home)/.claude.json.backup.1795200000000", "{}")
        writeFile("\(w.home)/.claude-empty/settings.json", "{}")
        writeFile("\(w.home)/.clyde/sessions/301.json", "{}")
        let s = w.sessionsDir(".claude")
        writeFile("\(s)/201.\(String(repeating: "ab", count: 32)).key", "k")
        writeFile("\(s)/.401.json", #"{"pid":401,"cwd":"/x","status":"busy"}"#)
        writeFile("\(s)/0402.json", #"{"pid":402,"cwd":"/x","status":"busy"}"#)
        writeFile("\(s)/notes.txt", "hello")
        let p = w.agentsPanel()
        expectEqual(p.value(of: "AGENT.LINK"), "ONLINE")
        expectEqual(p.value(of: "RUNNING"), "3")
        expectEqual(p.value(of: "ACTIVE"), "3")
    }

    test("agents: classifies every state") {
        let w = FakeWorld("agents-states")
        w.writeSession(FakeSession(pid: 1, status: "busy", statusAgo: 720))
        w.writeSession(FakeSession(pid: 2, status: "shell"))
        w.writeSession(FakeSession(pid: 3, status: "waiting", waitingFor: "permission prompt", statusAgo: 40))
        w.writeSession(FakeSession(pid: 4, status: "idle", statusAgo: 14 * 60 + 59))
        w.writeSession(FakeSession(pid: 5, status: "idle", statusAgo: 15 * 60))
        w.writeSession(FakeSession(pid: 6, status: "idle", statusAgo: 3 * 3600))
        let p = w.agentsPanel()
        expectEqual(p.value(of: "RUNNING"), "6")
        expectEqual(p.value(of: "ACTIVE"), "2")
        expectEqual(p.value(of: "ATTENTION"), "1")
        expectEqual(p.value(of: "AWAITING"), "1")
        expectEqual(p.value(of: "DORMANT"), "2")
        expectEqual(p.line("ATTENTION")?.severity, .alert)
        expectEqual(p.line("AWAITING")?.severity, .warn)
        expectEqual(p.line("DORMANT")?.severity, .dim)
        // Listed individually: attention, active x2, awaiting. Dormant folded.
        expectEqual(rosterRows(p).map { $0.value }, ["APPROVE 40s", "ACTIVE 12m", "ACTIVE 1m", "idle 14m"])
        expectEqual(rosterRows(p).map { $0.severity }, [.alert, .ok, .ok, .warn])
    }

    test("agents: daemon and daemon-worker kinds are excluded entirely") {
        let w = FakeWorld("agents-daemon")
        w.writeSession(FakeSession(pid: 11, status: "busy"))
        w.writeSession(FakeSession(pid: 12, status: "busy", kind: "daemon"))
        w.writeSession(FakeSession(pid: 13, status: "waiting", kind: "daemon-worker"))
        let p = w.agentsPanel()
        expectEqual(p.value(of: "RUNNING"), "1")
        expectEqual(p.value(of: "ATTENTION"), "0")
        expectEqual(rosterRows(p).count, 1)
    }

    test("agents: dead or reused pids are GHOSTs, dimmed and not counted live") {
        let w = FakeWorld("agents-ghost")
        w.writeSession(FakeSession(pid: 21, status: "busy"))
        w.writeSession(FakeSession(pid: 22, status: "waiting", waitingFor: "input needed"))
        w.writeSession(FakeSession(pid: 23, status: "idle", statusAgo: 30))
        let p = w.agentsPanel(dead: [22, 23])
        expectEqual(p.value(of: "RUNNING"), "1")
        expectEqual(p.value(of: "ATTENTION"), "0")
        expectEqual(p.value(of: "AWAITING"), "0")
        expectEqual(rosterRows(p).count, 1)
        expectEqual(rosterLines(p).last, .text("✕ 2 GHOST", .dim))
    }

    test("agents: the liveness checker gets each session's pid and procStart") {
        let w = FakeWorld("agents-liveness-args")
        w.writeSession(FakeSession(pid: 31, status: "busy", procStart: "Mon Nov  2 01:02:03 2026"))
        var seen: [String] = []
        var e = w.env
        e.isProcessAlive = { pid, ps in seen.append("\(pid)|\(ps ?? "nil")"); return true }
        let core = DiagnosticsCore(env: e, polling: .manual)
        core.pollNow()
        expectEqual(seen, ["31|Mon Nov  2 01:02:03 2026"])
    }

    test("agents: no ~/.claude* dirs or empty sessions/ means zero, not SIGNAL LOST") {
        let w = FakeWorld("agents-empty")
        expectEqual(w.agentsPanel().value(of: "RUNNING"), "0")
        try FileManager.default.createDirectory(atPath: w.sessionsDir(".claude"), withIntermediateDirectories: true)
        let p = w.agentsPanel()
        expectEqual(p.value(of: "AGENT.LINK"), "ONLINE")
        expectEqual(p.value(of: "RUNNING"), "0")
        expect(rosterLines(p).contains(.text("NO LIVE SESSIONS", .dim)))
    }

    test("agents: malformed session files -> AGENT.LINK SIGNAL LOST, never zero") {
        let w = FakeWorld("agents-malformed")
        let s = w.sessionsDir(".claude")
        writeFile("\(s)/51.json", "not json")
        writeFile("\(s)/52.json", #"{"pid":52,"state":"renamed-field"}"#)
        writeFile("\(s)/53.json", #"{"pid":99,"cwd":"/x","status":"busy"}"#)   // pid != file name
        let p = w.agentsPanel()
        expectEqual(p.line("AGENT.LINK"), .field("AGENT.LINK", "SIGNAL LOST", .alert))
        expectEqual(p.value(of: "RUNNING"), nil)
        expect(!p.lines.contains { $0.value == "0" }, "no zero counts while the link is lost")
    }

    test("agents: one unreadable file among good ones is skipped, link stays up") {
        let w = FakeWorld("agents-partial")
        w.writeSession(FakeSession(pid: 61, status: "busy"))
        writeFile("\(w.sessionsDir(".claude"))/62.json", "{trunc")
        let p = w.agentsPanel()
        expectEqual(p.value(of: "AGENT.LINK"), "ONLINE")
        expectEqual(p.value(of: "RUNNING"), "1")
    }

    test("agents: a sessions read that starts failing turns the link SIGNAL LOST") {
        let w = FakeWorld("agents-failing")
        w.writeSession(FakeSession(pid: 71, status: "busy"))
        let core = DiagnosticsCore(env: w.agentsEnv(), polling: .manual)
        core.pollNow()
        expectEqual(core.panels()[1].value(of: "RUNNING"), "1")
        writeFile("\(w.sessionsDir(".claude"))/71.json", "garbage")
        w.advance(3)
        core.pollNow()
        expectEqual(core.panels()[1].value(of: "AGENT.LINK"), "SIGNAL LOST")
        expectEqual(core.panels()[1].value(of: "RUNNING"), nil)
    }

    test("agents: waitingFor maps to a category only") {
        let cases: [(String?, String)] = [
            ("approve Bash: rm -rf /tmp/build-cache", "APPROVE BASH"),
            ("approve Bash", "APPROVE BASH"),
            ("approve WebFetch: https://example.com/private", "APPROVE WEBFETCH"),
            ("approve mcp__plugin_srv__do_thing: arg", "APPROVE MCP"),
            ("approve plan", "APPROVE PLAN"),
            ("permission prompt", "APPROVE"),
            ("sandbox request", "APPROVE"),
            ("worker request", "APPROVE"),
            ("input needed", "INPUT NEEDED"),
            ("dialog open", "INPUT NEEDED"),
            ("goal proposal", "INPUT NEEDED"),
            ("mcp elicitation", "INPUT NEEDED"),
            ("something new", "ATTENTION"),
            ("", "ATTENTION"),
            (nil, "ATTENTION"),
        ]
        for (raw, want) in cases {
            let w = FakeWorld("agents-wait")
            w.writeSession(FakeSession(pid: 81, status: "waiting", waitingFor: raw, statusAgo: 125))
            expectEqual(rosterRows(w.agentsPanel()).first?.value, "\(want) 2m")
        }
    }

    test("agents: command text, session titles and paths never reach the panel") {
        let w = FakeWorld("agents-privacy")
        w.writeConfig(#"{ "codenameSalt": "test-salt" }"#)
        w.writeSession(FakeSession(dir: ".claude-alpha", pid: 91, cwd: "/home/someone/code/acme-secret",
                                   status: "waiting", waitingFor: "approve Bash: curl https://acme.example/tok",
                                   name: "fix acme billing"))
        w.writeSession(FakeSession(pid: 92, cwd: "/home/someone/code/acme-secret/.claude/worktrees/wt1",
                                   status: "idle", statusAgo: 7200, name: "dormant acme thing"))
        let p = w.agentsPanel()
        let text = p.lines.map { "\($0.label) \($0.value)" }.joined(separator: "\n").lowercased()
        for leak in ["curl", "acme", "tok", "billing", "someone", "worktree", "/"] {
            expect(!text.contains(leak), "panel leaks '\(leak)':\n\(text)")
        }
    }

    test("agents: roster sorts attention -> active -> awaiting, oldest wait first") {
        let w = FakeWorld("agents-sort")
        w.writeSession(FakeSession(pid: 1, cwd: "/a", status: "idle", statusAgo: 60))
        w.writeSession(FakeSession(pid: 2, cwd: "/b", status: "busy", statusAgo: 30))
        w.writeSession(FakeSession(pid: 3, cwd: "/c", status: "waiting", waitingFor: "input needed", statusAgo: 10))
        w.writeSession(FakeSession(pid: 4, cwd: "/d", status: "idle", statusAgo: 300))
        w.writeSession(FakeSession(pid: 5, cwd: "/e", status: "waiting", waitingFor: "approve plan", statusAgo: 90))
        w.writeSession(FakeSession(pid: 6, cwd: "/f", status: "busy", statusAgo: 600))
        expectEqual(rosterRows(w.agentsPanel()).map(\.value),
                    ["APPROVE PLAN 1m", "INPUT NEEDED 10s", "ACTIVE 10m", "ACTIVE 30s", "idle 1m", "idle 5m"])
    }

    test("agents: dormant sessions fold into one line counting distinct repos") {
        let w = FakeWorld("agents-fold")
        w.writeSession(FakeSession(pid: 1, cwd: "/r/one", status: "idle", statusAgo: 3600))
        w.writeSession(FakeSession(pid: 2, cwd: "/r/one", status: "idle", statusAgo: 7200))
        w.writeSession(FakeSession(pid: 3, cwd: "/r/two", status: "idle", statusAgo: 86400))
        w.writeSession(FakeSession(pid: 4, cwd: "/r/three", status: "busy"))
        let p = w.agentsPanel()
        expectEqual(rosterRows(p).count, 1)
        expectEqual(rosterLines(p).last, .text("○ 3 DORMANT across 2 repos", .dim))
    }

    test("agents: roster rows are capped by the line budget with +N more") {
        let w = FakeWorld("agents-cap")
        for i in 1...12 { w.writeSession(FakeSession(pid: Int32(100 + i), cwd: "/r/\(i)", status: "busy")) }
        w.writeSession(FakeSession(pid: 200, cwd: "/r/old", status: "idle", statusAgo: 9999))
        let p = w.agentsPanel(maxLines: 15)   // 8 totals (incl. BACKGROUND) + ROSTER heading + 7 roster lines
        expectEqual(p.lines.count, 15)
        let roster = rosterLines(p)
        // Session rows outrank the dormant summary; `+N more` takes the last line.
        expectEqual(roster.filter { $0.style == .field }.count, 6)
        expectEqual(roster.last, .text("+6 more", .dim))
        // Everything fits: no "+N more", the dormant summary is back.
        let roomy = w.agentsPanel(maxLines: 40)
        expectEqual(rosterRows(roomy).count, 12)
        expect(!roomy.lines.contains { $0.label.hasSuffix("more") })
        expectEqual(rosterLines(roomy).last, .text("○ 1 DORMANT across 1 repo", .dim))
    }

    test("agents: profile tags default per dir and honour config overrides; CLI/DSK tag") {
        let w = FakeWorld("agents-tags")
        w.writeSession(FakeSession(dir: ".claude", pid: 1, status: "busy", statusAgo: 1))
        w.writeSession(FakeSession(dir: ".claude-alpha", pid: 2, status: "busy",
                                   entrypoint: "claude-desktop", statusAgo: 2))
        w.writeSession(FakeSession(dir: ".claude-lab", pid: 3, status: "busy", statusAgo: 3))
        let tags = { (p: Panel) in rosterRows(p).map { $0.label.split(separator: " ").dropFirst().joined(separator: " ") } }
        expectEqual(tags(w.agentsPanel()), ["LAB CLI", "ALP DSK", "WRK CLI"])
        w.writeConfig(#"{ "profileTags": { ".claude-alpha": "hom", ".claude": "ops" } }"#)
        expectEqual(tags(w.agentsPanel()), ["LAB CLI", "HOM DSK", "OPS CLI"])
    }

    test("agents: codenames are stable WORD-WORD for a salt, and change with the salt") {
        let cwds = ["/r/alpha", "/r/beta", "/r/gamma", "/r/delta", "/r/alpha/.claude/worktrees/x"]
        func names(_ cfg: String?) -> [String] {
            let w = FakeWorld("agents-codename")
            if let c = cfg { w.writeConfig(c) }
            for (i, c) in cwds.enumerated() {
                w.writeSession(FakeSession(pid: Int32(i + 1), cwd: c, status: "busy", statusAgo: Double(10 - i)))
            }
            return rosterRows(w.agentsPanel()).map { String($0.label.split(separator: " ")[0]) }
        }
        let a1 = names(#"{ "codenameSalt": "salt-one" }"#), a2 = names(#"{ "codenameSalt": "salt-one" }"#)
        let b = names(#"{ "codenameSalt": "salt-two" }"#)
        expectEqual(a1, a2)
        expect(a1 != b, "different salt should change names: \(a1) vs \(b)")
        expect(names(nil) != names(nil), "no salt: a random per-run salt")
        for n in a1 {
            let parts = n.split(separator: "-")
            expect(parts.count == 2 && Codename.first.contains(String(parts[0]))
                   && Codename.second.contains(String(parts[1])), "not WORD-WORD: \(n)")
        }
        // A worktree is named by its own path, not its parent repo's.
        expect(a1[0] != a1[4] || a1[0] != names(#"{ "codenameSalt": "salt-three" }"#)[4])
    }

    test("codename vocabularies: 64 unique words each, short enough for the roster") {
        expectEqual(Set(Codename.first).count, 64)
        expectEqual(Set(Codename.second).count, 64)
        expect((Codename.first + Codename.second).allSatisfy { $0.count <= 6 && $0 == $0.uppercased() })
    }

    test("liveness (real proc_pidinfo): own pid with its procStart is alive; mismatch or dead pid is not") {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        expectEqual(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size), size)
        let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
        let ps = Liveness.formatProcStart(started)
        expectEqual(Liveness.parseProcStart(ps), started)
        expect(Liveness.check(pid: getpid(), procStart: ps), "own process should be alive: \(ps)")
        expect(!Liveness.check(pid: getpid(), procStart: Liveness.formatProcStart(started.addingTimeInterval(-3600))),
               "pid reuse (start time mismatch) must be a ghost")
        expect(!Liveness.check(pid: 99_999_9, procStart: nil), "nonexistent pid must be dead")
    }

    test("liveness: procStart parses as UTC, including space-padded days") {
        expectEqual(Liveness.parseProcStart("Mon Nov  2 01:02:03 2026"),
                    Date(timeIntervalSince1970: 1_793_581_323))
        expectEqual(Liveness.formatProcStart(Date(timeIntervalSince1970: 1_793_581_323)), "Mon Nov  2 01:02:03 2026")
    }

    test("layout: SYS and AGENTS sit in diagonally opposite corners") {
        let w = FakeWorld("agents-layout")
        let core = DiagnosticsCore(env: w.agentsEnv(), polling: .manual)
        core.pollNow()
        let placed = core.layout()
        expectEqual(placed.map(\.panel.title), ["SYS", "AGENTS"])
        expectEqual(placed[1].corner, placed[0].corner.opposite)
        expect(placed[1].columns >= placed[0].columns, "AGENTS rows need at least SYS width")
    }

    test("agents: the panel never exceeds its line budget, at any budget") {
        let w = FakeWorld("agents-budget")
        writeMixedRoster(w)
        for budget in 1...30 {
            let p = w.agentsPanel(dead: [90], maxLines: budget)
            expect(p.lines.count <= budget, "budget \(budget): \(p.lines.count) lines")
        }
    }

    test("agents: a tight budget keeps full totals while a row and +N more still fit") {
        let w = FakeWorld("agents-budget-full")
        writeMixedRoster(w)   // 2 attention, 3 active, 2 awaiting, 3 dormant, 1 ghost
        let p = w.agentsPanel(dead: [90], maxLines: 12)
        expectEqual(p.value(of: "ATTENTION"), "2")
        expectEqual(rosterLines(p).map(\.value), ["APPROVE 5m", "INPUT NEEDED 1m", "ACTIVE 20m", ""])
        expectEqual(rosterLines(p).last, .text("+4 more", .dim))
        // All rows fit but not both summaries: dormant summary before ghost.
        let q = w.agentsPanel(dead: [90], maxLines: 16)
        expectEqual(rosterRows(q).count, 7)
        expectEqual(rosterLines(q).last, .text("○ 3 DORMANT across 2 repos", .dim))
        expectEqual(w.agentsPanel(dead: [90], maxLines: 17).lines.last, .text("✕ 1 GHOST", .dim))
    }

    test("agents: below the full totals the panel folds totals into one line and keeps rows") {
        let w = FakeWorld("agents-budget-compact")
        writeMixedRoster(w)
        let p = w.agentsPanel(dead: [90], maxLines: 7)
        expectEqual(p.lines.first, .text("RUN 10 · ATT 2 · ACT 3 · AWT 2 · DOR 3 · BG 0", .alert))
        expectEqual(p.lines.filter { $0.style == .field }.map(\.value),
                    ["APPROVE 5m", "INPUT NEEDED 1m", "ACTIVE 20m", "ACTIVE 10m", "ACTIVE 1m"])
        expectEqual(p.lines.last, .text("+2 more", .dim))
        // Three lines: totals, the first attention row, +N more.
        let three = w.agentsPanel(dead: [90], maxLines: 3)
        expectEqual(three.lines.map(\.value), ["", "APPROVE 5m", ""])
        expectEqual(three.lines.last, .text("+6 more", .dim))
        // Two lines: totals and the first attention row.
        expectEqual(w.agentsPanel(dead: [90], maxLines: 2).lines.map(\.value), ["", "APPROVE 5m"])
        // One line: the first attention row beats the totals.
        let one = w.agentsPanel(dead: [90], maxLines: 1)
        expectEqual(one.lines.count, 1)
        expectEqual(one.lines.first?.value, "APPROVE 5m")
        expectEqual(one.lines.first?.severity, .alert)
    }

    test("agents: compact totals are not red without attention and carry the stale marker's place") {
        let w = FakeWorld("agents-budget-calm")
        for i in 1...4 { w.writeSession(FakeSession(pid: Int32(i), cwd: "/r/\(i)", status: "busy", statusAgo: Double(i))) }
        let p = w.agentsPanel(maxLines: 4)
        expectEqual(p.lines.first, .text("RUN 4 · ATT 0 · ACT 4 · AWT 0 · DOR 0 · BG 0", .normal))
        expectEqual(p.lines.count, 4)
        expectEqual(p.lines.last, .text("+2 more", .dim))
        // No live rows: totals plus the summary.
        let idle = FakeWorld("agents-budget-idle")
        idle.writeSession(FakeSession(pid: 1, cwd: "/r/a", status: "idle", statusAgo: 9999))
        expectEqual(idle.agentsPanel(maxLines: 2).lines,
                    [.text("RUN 1 · ATT 0 · ACT 0 · AWT 0 · DOR 1 · BG 0", .normal),
                     .text("○ 1 DORMANT across 1 repo", .dim)])
    }

    test("layout: the widest roster row fits the AGENTS panel width") {
        let longest = (Codename.first.map(\.count).max() ?? 0) + 1 + (Codename.second.map(\.count).max() ?? 0)
        let label = longest + " WRK DSK".count
        let value = "APPROVE ".count + WaitCategory.maxToolLength + " 59m".count
        expect(label + value + 2 <= PanelLayout.agentsColumns,
               "row needs \(label + value + 2) cells, panel has \(PanelLayout.agentsColumns)")
    }

    test("agents: sessions are polled every 2 s on the shared poller registry") {
        let w = FakeWorld("agents-interval")
        let src = PollSources.standard(w.env).first { $0.id == SourceIDs.sessions }
        expectEqual(src?.baseInterval, 2)
    }
}


/// 2 attention (oldest first: 5m, 1m), 3 active (20m, 10m, 1m), 2 awaiting,
/// 3 dormant across 2 repos and one ghost (pid 90, pass `dead: [90]`).
func writeMixedRoster(_ w: FakeWorld) {
    w.writeSession(FakeSession(pid: 1, cwd: "/r/a", status: "waiting", waitingFor: "permission prompt", statusAgo: 300))
    w.writeSession(FakeSession(pid: 2, cwd: "/r/b", status: "waiting", waitingFor: "input needed", statusAgo: 60))
    w.writeSession(FakeSession(pid: 3, cwd: "/r/c", status: "busy", statusAgo: 1200))
    w.writeSession(FakeSession(pid: 4, cwd: "/r/d", status: "busy", statusAgo: 600))
    w.writeSession(FakeSession(pid: 5, cwd: "/r/e", status: "busy", statusAgo: 60))
    w.writeSession(FakeSession(pid: 6, cwd: "/r/f", status: "idle", statusAgo: 120))
    w.writeSession(FakeSession(pid: 7, cwd: "/r/g", status: "idle", statusAgo: 240))
    for (pid, cwd) in [(8, "/r/old"), (9, "/r/old"), (10, "/r/older")] {
        w.writeSession(FakeSession(pid: Int32(pid), cwd: cwd, status: "idle", statusAgo: 99999))
    }
    w.writeSession(FakeSession(pid: 90, cwd: "/r/gone", status: "busy"))
}
