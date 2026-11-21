//
//  BackgroundTests.swift — background-agent counts (#5) through the core's
//  top seam: a fake home tree with sessions, subagent meta files, jobs and a
//  daemon roster in; the AGENTS panel's BACKGROUND total and per-row `+N BG`
//  suffix out.
//

import Foundation

extension FakeWorld {
    /// One subagent of `sessionId` under `<dir>/projects/<project>/`. Its
    /// transcript was last written `ago` seconds before the world's `now`.
    func writeSubagent(dir: String = ".claude", project: String, sessionId: String,
                       id: String = UUID().uuidString.prefix(8).lowercased(),
                       finished: Bool = false, ago: TimeInterval = 10) {
        let base = "\(home)/\(dir)/projects/\(project)/\(sessionId)/subagents/agent-\(id)"
        var meta: [String: Any] = ["agentType": "general-purpose", "description": "secret subagent task",
                                   "spawnDepth": 1]
        if finished { meta["finished"] = true }
        let data = try! JSONSerialization.data(withJSONObject: meta)
        writeFile("\(base).meta.json", String(data: data, encoding: .utf8)!)
        writeFile("\(base).jsonl", "{}\n")
        try! FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-ago)],
                                               ofItemAtPath: "\(base).jsonl")
    }

    /// The session's transcript in its project dir (what makes the cwd-derived
    /// project path "resolve").
    func writeTranscript(dir: String = ".claude", project: String, sessionId: String) {
        writeFile("\(home)/\(dir)/projects/\(project)/\(sessionId).jsonl", "{}\n")
    }

    func writeJob(dir: String = ".claude", id: String, state: String, sessionId: String) {
        writeFile("\(home)/\(dir)/jobs/\(id)/state.json",
                  #"{"state":"\#(state)","tempo":"idle","sessionId":"\#(sessionId)","needs":"secret","name":"secret job"}"#)
    }

    func writeRoster(dir: String = ".claude", workers: [(id: String, pid: Int32, sessionId: String)]) {
        let w = workers.map {
            #""\#($0.id)":{"pid":\#($0.pid),"sessionId":"\#($0.sessionId)","cwd":"/work/x","startedAt":1,"attempt":1,"rendezvousSock":"/tmp/r.sock","dispatch":{}}"#
        }.joined(separator: ",")
        writeFile("\(home)/\(dir)/daemon/roster.json",
                  #"{"proto":1,"supervisorPid":1,"updatedAt":1,"workers":{\#(w)}}"#)
    }
}

/// The `+N BG` suffix of each roster row, in roster order ("" when none).
func bgSuffixes(_ p: Panel) -> [String] {
    rosterRows(p).map { row in
        let parts = row.value.split(separator: " ")
        guard parts.count >= 2, parts.last == "BG" else { return "" }
        return String(parts[parts.count - 2])
    }
}

func backgroundTests() {
    test("bg: an unfinished subagent with a fresh transcript is counted on its session and in the total") {
        let w = FakeWorld("bg-fresh")
        w.writeSession(FakeSession(pid: 1, cwd: "/work/alpha-repo", status: "busy", sessionId: "sess-a"))
        w.writeTranscript(project: "-work-alpha-repo", sessionId: "sess-a")
        w.writeSubagent(project: "-work-alpha-repo", sessionId: "sess-a", ago: 20)
        w.writeSubagent(project: "-work-alpha-repo", sessionId: "sess-a", ago: 100)
        let p = w.agentsPanel()
        expectEqual(p.value(of: "BACKGROUND"), "2")
        expectEqual(p.line("BACKGROUND")?.severity, .ok)
        expectEqual(rosterRows(p).first?.value, "ACTIVE 1m +2 BG")
    }

    test("bg: no background work shows BACKGROUND 0 (dim) and no row suffix") {
        let w = FakeWorld("bg-none")
        w.writeSession(FakeSession(pid: 1, status: "busy"))
        let p = w.agentsPanel()
        expectEqual(p.line("BACKGROUND"), .field("BACKGROUND", "0", .dim))
        expectEqual(rosterRows(p).first?.value, "ACTIVE 1m")
    }

    test("bg: finished subagents, stale transcripts and compaction runs are not counted") {
        let w = FakeWorld("bg-not-running")
        w.writeSession(FakeSession(pid: 1, cwd: "/work/alpha-repo", status: "busy", sessionId: "sess-a"))
        w.writeTranscript(project: "-work-alpha-repo", sessionId: "sess-a")
        w.writeSubagent(project: "-work-alpha-repo", sessionId: "sess-a", finished: true, ago: 5)
        w.writeSubagent(project: "-work-alpha-repo", sessionId: "sess-a", ago: 6 * 60)   // crashed
        w.writeSubagent(project: "-work-alpha-repo", sessionId: "sess-a", ago: 30)       // the one running
        // A compaction transcript has no meta file.
        writeFile("\(w.home)/.claude/projects/-work-alpha-repo/sess-a/subagents/agent-acompact-1f2e.jsonl", "{}")
        // A meta that doesn't parse is skipped, not fatal.
        writeFile("\(w.home)/.claude/projects/-work-alpha-repo/sess-a/subagents/agent-bad.meta.json", "{trunc")
        let p = w.agentsPanel()
        expectEqual(p.value(of: "AGENT.LINK"), "ONLINE")
        expectEqual(p.value(of: "BACKGROUND"), "1")
        expectEqual(bgSuffixes(p), ["+1"])
    }

    test("bg: cwd-mismatch fallback finds the session's subagents in another project dir") {
        let w = FakeWorld("bg-fallback")
        // The session moved into a worktree; its transcript stayed in the repo's project dir.
        w.writeSession(FakeSession(pid: 1, cwd: "/work/alpha-repo/.claude/worktrees/w1", status: "busy",
                                   sessionId: "sess-a"))
        w.writeSubagent(project: "-work-alpha-repo", sessionId: "sess-a")
        // Another session's subagents in the same project dir are not this session's.
        w.writeSubagent(project: "-work-alpha-repo", sessionId: "sess-other")
        expectEqual(bgSuffixes(w.agentsPanel()), ["+1"])
    }

    test("bg: a cwd longer than 200 units resolves to the truncated, hashed project dir") {
        let w = FakeWorld("bg-long-cwd")
        let cwd = "/home/someone/" + String(repeating: "deeply-nested-directory/", count: 9) + "project"
        // Expected name computed independently with Claude Code's JS algorithm.
        let project = String(repeating: "-", count: 1) + "home-someone-"
            + String(repeating: "deeply-nested-directory-", count: 9) + "project"
        let name = String(project.prefix(200)) + "-7dqkon"
        w.writeSession(FakeSession(pid: 1, cwd: cwd, status: "busy", sessionId: "sess-long"))
        w.writeSubagent(project: name, sessionId: "sess-long")
        let bg = BackgroundAgentScanner()
        let scan = try SessionReader.scan(home: w.home, isAlive: { _, _ in true }, now: w.now, background: bg)
        expectEqual(scan.sessions.first?.background, 1)
        expectEqual(bg.fallbackLookups, 0)
    }

    test("bg: running jobs and live daemon workers count; blocked/done jobs and dead workers don't") {
        let w = FakeWorld("bg-jobs")
        w.writeSession(FakeSession(pid: 1, cwd: "/work/alpha-repo", status: "busy", statusAgo: 120, sessionId: "sess-a"))
        w.writeSession(FakeSession(pid: 2, cwd: "/work/beta-repo", status: "busy", statusAgo: 60, sessionId: "sess-b"))
        w.writeJob(id: "0000000a", state: "working", sessionId: "sess-a")
        w.writeJob(id: "0000000b", state: "blocked", sessionId: "sess-a")
        w.writeJob(id: "0000000c", state: "done", sessionId: "sess-b")
        w.writeJob(id: "0000000d", state: "working", sessionId: "sess-elsewhere")   // no matching session
        writeFile("\(w.home)/.claude/jobs/0000000e/tmp/x", "")                       // no state.json
        writeFile("\(w.home)/.claude/jobs/pins.json", "[]")
        w.writeRoster(workers: [(id: "aaaaaaa1", pid: 501, sessionId: "sess-b"),
                                (id: "aaaaaaa2", pid: 502, sessionId: "sess-b"),
                                (id: "aaaaaaa3", pid: 503, sessionId: "sess-b"),     // dead
                                (id: "aaaaaaa4", pid: 504, sessionId: "sess-a")])    // same unit as job 0a
        let p = w.agentsPanel(dead: [503])
        // sess-a: job 0a (+ its worker, one unit); sess-b: 2 live workers... deduped by session id → 1.
        expectEqual(bgSuffixes(p), ["+1", "+1"])
        expectEqual(p.value(of: "BACKGROUND"), "3")
    }

    test("bg: missing or malformed jobs/roster are zero, never SIGNAL LOST") {
        let w = FakeWorld("bg-missing")
        w.writeSession(FakeSession(pid: 1, status: "busy"))
        w.writeSession(FakeSession(dir: ".claude-alpha", pid: 2, status: "busy"))
        writeFile("\(w.home)/.claude-alpha/jobs/00000001/state.json", "not json")
        writeFile("\(w.home)/.claude-alpha/daemon/roster.json", #"{"proto":1,"workers":"weird"}"#)
        let p = w.agentsPanel()
        expectEqual(p.value(of: "AGENT.LINK"), "ONLINE")
        expectEqual(p.value(of: "RUNNING"), "2")
        expectEqual(p.value(of: "BACKGROUND"), "0")
    }

    test("bg: counts follow each session's own config dir when several dirs share a cwd") {
        let w = FakeWorld("bg-multi-dir")
        w.writeSession(FakeSession(dir: ".claude", pid: 1, cwd: "/work/alpha-repo", status: "busy",
                                   statusAgo: 300, sessionId: "sess-w"))
        w.writeSession(FakeSession(dir: ".claude-alpha", pid: 2, cwd: "/work/alpha-repo", status: "busy",
                                   statusAgo: 200, sessionId: "sess-a"))
        w.writeSession(FakeSession(dir: ".claude-beta", pid: 3, cwd: "/work/alpha-repo", status: "busy",
                                   statusAgo: 100, sessionId: "sess-b"))
        for (dir, sid) in [(".claude", "sess-w"), (".claude-alpha", "sess-a"), (".claude-beta", "sess-b")] {
            w.writeTranscript(dir: dir, project: "-work-alpha-repo", sessionId: sid)
        }
        w.writeSubagent(dir: ".claude-alpha", project: "-work-alpha-repo", sessionId: "sess-a")
        w.writeSubagent(dir: ".claude-alpha", project: "-work-alpha-repo", sessionId: "sess-a")
        w.writeSubagent(dir: ".claude-beta", project: "-work-alpha-repo", sessionId: "sess-b")
        // A job in .claude-beta naming the .claude session is not attributed across dirs.
        w.writeJob(dir: ".claude-beta", id: "0000000f", state: "working", sessionId: "sess-w")
        let p = w.agentsPanel()
        // Roster: active, longest running first → sess-w, sess-a, sess-b.
        expectEqual(bgSuffixes(p), ["", "+2", "+1"])
        expectEqual(p.value(of: "BACKGROUND"), "4")
    }

    test("bg: ghost and excluded sessions contribute nothing") {
        let w = FakeWorld("bg-ghost")
        w.writeSession(FakeSession(pid: 1, cwd: "/work/alpha-repo", status: "busy", sessionId: "sess-g"))
        w.writeSession(FakeSession(pid: 2, cwd: "/work/alpha-repo", status: "busy", kind: "daemon", sessionId: "sess-d"))
        w.writeSubagent(project: "-work-alpha-repo", sessionId: "sess-g")
        w.writeSubagent(project: "-work-alpha-repo", sessionId: "sess-d")
        expectEqual(w.agentsPanel(dead: [1]).value(of: "BACKGROUND"), "0")
    }

    test("bg: the fallback glob runs once per session, not on every 2 s poll") {
        let w = FakeWorld("bg-hot-path")
        // Resolves on the primary path.
        w.writeSession(FakeSession(pid: 1, cwd: "/work/alpha-repo", status: "busy", sessionId: "sess-a"))
        w.writeTranscript(project: "-work-alpha-repo", sessionId: "sess-a")
        w.writeSubagent(project: "-work-alpha-repo", sessionId: "sess-a")
        let bg = BackgroundAgentScanner()
        let alive: LivenessChecker = { _, _ in true }
        for _ in 0..<5 { _ = try SessionReader.scan(home: w.home, isAlive: alive, now: w.now, background: bg) }
        expectEqual(bg.fallbackLookups, 0)
        // Needs the fallback (moved cwd): looked up once, then cached.
        w.writeSession(FakeSession(pid: 2, cwd: "/work/beta-repo/.claude/worktrees/w2", status: "busy", sessionId: "sess-b"))
        w.writeSubagent(project: "-work-beta-repo", sessionId: "sess-b")
        for _ in 0..<5 {
            let scan = try SessionReader.scan(home: w.home, isAlive: alive, now: w.now, background: bg)
            expectEqual(scan.sessions.map(\.background), [1, 1])
            w.advance(2)
        }
        expectEqual(bg.fallbackLookups, 1)
        // A session found nowhere is retried only after BackgroundCfg.fallbackRetry.
        w.writeSession(FakeSession(pid: 3, cwd: "/work/gamma-repo", status: "busy", sessionId: "sess-c"))
        for _ in 0..<10 {
            _ = try SessionReader.scan(home: w.home, isAlive: alive, now: w.now, background: bg)
            w.advance(2)
        }
        expectEqual(bg.fallbackLookups, 2)
        w.advance(BackgroundCfg.fallbackRetry)
        _ = try SessionReader.scan(home: w.home, isAlive: alive, now: w.now, background: bg)
        expectEqual(bg.fallbackLookups, 3)
    }

    test("bg: through the core, a fallback-resolved session keeps updating across polls") {
        let w = FakeWorld("bg-core-cache")
        w.writeSession(FakeSession(pid: 1, cwd: "/work/alpha-repo/.claude/worktrees/w1", status: "busy",
                                   sessionId: "sess-a"))
        w.writeSubagent(project: "-work-alpha-repo", sessionId: "sess-a", id: "one", ago: 1)
        let core = DiagnosticsCore(env: w.agentsEnv(), polling: .manual)
        core.pollNow()
        expectEqual(core.panels()[1].value(of: "BACKGROUND"), "1")
        w.writeSubagent(project: "-work-alpha-repo", sessionId: "sess-a", id: "two", ago: 0)
        w.advance(3)
        core.pollNow()
        expectEqual(core.panels()[1].value(of: "BACKGROUND"), "2")
        w.writeSubagent(project: "-work-alpha-repo", sessionId: "sess-a", id: "one", finished: true, ago: 0)
        w.writeSubagent(project: "-work-alpha-repo", sessionId: "sess-a", id: "two", finished: true, ago: 0)
        w.advance(3)
        core.pollNow()
        expectEqual(core.panels()[1].value(of: "BACKGROUND"), "0")
    }

    test("bg: privacy: subagent descriptions and job text never reach the panel") {
        let w = FakeWorld("bg-privacy")
        w.writeSession(FakeSession(pid: 1, cwd: "/work/alpha-repo", status: "busy", sessionId: "sess-a"))
        w.writeSubagent(project: "-work-alpha-repo", sessionId: "sess-a")
        w.writeJob(id: "00000001", state: "working", sessionId: "sess-a")
        let text = w.agentsPanel().lines.map { "\($0.label) \($0.value)" }.joined(separator: "\n").lowercased()
        expect(!text.contains("secret"), "panel leaks:\n\(text)")
    }

    test("layout: the widest roster row with a +99 BG suffix fits the AGENTS panel width") {
        let longest = (Codename.first.map(\.count).max() ?? 0) + 1 + (Codename.second.map(\.count).max() ?? 0)
        let label = longest + " WRK DSK".count
        let value = "APPROVE ".count + WaitCategory.maxToolLength + " 59m".count + " +99 BG".count
        expect(label + value + 2 <= PanelLayout.agentsColumns,
               "row needs \(label + value + 2) cells, panel has \(PanelLayout.agentsColumns)")
        // More than 99 is capped in the row; the total stays exact.
        let w = FakeWorld("bg-cap")
        w.writeSession(FakeSession(pid: 1, cwd: "/work/alpha-repo", status: "busy", sessionId: "sess-a"))
        for i in 0..<120 { w.writeSubagent(project: "-work-alpha-repo", sessionId: "sess-a", id: "n\(i)") }
        let p = w.agentsPanel()
        expectEqual(bgSuffixes(p), ["+99"])
        expectEqual(p.value(of: "BACKGROUND"), "120")
    }
}
