//
//  TokenRefresh.swift
//  Keeps usage fresh without ever touching refresh tokens (#10). When an
//  account's token is the reason its usage data is more than 2 h stale
//  (expired, or rejected with 401/403), the collector runs `claude -p` with a
//  trivial prompt and a small model under that account's config dir, so
//  Claude Code refreshes (and rotates) its own token in the keychain exactly
//  as an interactive session would. At most once per hour per account.
//
//  The run's session id is chosen up front (`--session-id`), recorded in the
//  state file and checkpointed BEFORE launch, then the collector waits longer
//  than the saver's 5 s state-file poll, so the AGENTS panel already knows to
//  hide the session when its `sessions/<pid>.json` appears.
//

import Foundation

enum TokenRefreshCfg {
    /// Refresh only once usage data is older than this.
    static let staleAfter: TimeInterval = 2 * 3600
    /// Minimum gap between refresh attempts for one account.
    static let minInterval: TimeInterval = 3600
    /// Pause between recording the session id and launching (> the saver's
    /// 5 s collector-state poll).
    static let leadTime: TimeInterval = 6
    static let timeout: TimeInterval = 120
    /// Records older than this are dropped from the state file.
    static let retention: TimeInterval = 7 * 86400
    static let maxRecords = 50
    static let model = "haiku"
    static let prompt = "Reply with the single word OK."
}

enum TokenRefresh {
    /// The token is the problem, the data is > 2 h stale, and this account
    /// had no refresh attempt in the last hour.
    static func isDue(_ a: AccountUsage, sessions: [RefreshSession], now: Date) -> Bool {
        guard a.token == .expired else { return false }
        if let fetched = a.generatedAt, now.timeIntervalSince(fetched) <= TokenRefreshCfg.staleAfter { return false }
        let last = sessions.filter { $0.dir == a.dir }.map(\.startedAt).max()
        return last.map { now.timeIntervalSince($0) >= TokenRefreshCfg.minInterval } ?? true
    }

    /// The shared child environment (`ChildProcess.environment`: credentials
    /// dropped, HOME/USER/LOGNAME from passwd) plus CLAUDE_CONFIG_DIR, set
    /// only for non-default dirs. (Setting it for `~/.claude` would change
    /// the keychain service name.)
    static func environment(configDir: String, home: String, user: String,
                            inherited: [String: String]) -> [String: String] {
        var env = ChildProcess.environment(home: home, user: user, inherited: inherited)
        if configDir != ".claude" { env["CLAUDE_CONFIG_DIR"] = (home as NSString).appendingPathComponent(configDir) }
        return env
    }

    static func command(claude: String, configDir: String, sessionID: String,
                        ctx: CollectorContext) -> ProcessSpec {
        ProcessSpec(
            executable: claude,
            // `--tools ""` last: it takes a variadic list. Never `--bare`
            // (it skips keychain reads, i.e. the whole point).
            arguments: ["-p", TokenRefreshCfg.prompt,
                        "--model", TokenRefreshCfg.model,
                        "--session-id", sessionID,
                        "--no-session-persistence",
                        "--safe-mode",
                        "--strict-mcp-config",
                        "--output-format", "json",
                        "--max-budget-usd", "0.05",
                        "--tools", ""],
            environment: environment(configDir: configDir, home: ctx.home, user: ctx.user,
                                     inherited: ctx.environment),
            workingDirectory: ChildProcess.workingDirectory(home: ctx.home),
            timeout: TokenRefreshCfg.timeout)
    }

    /// Drop week-old records (and cap the list).
    static func prune(_ state: inout CollectorState, now: Date) {
        guard var sessions = state.refresh?.sessions else { return }
        sessions.removeAll { now.timeIntervalSince($0.startedAt) > TokenRefreshCfg.retention }
        if sessions.count > TokenRefreshCfg.maxRecords {
            sessions.removeFirst(sessions.count - TokenRefreshCfg.maxRecords)
        }
        state.refresh = sessions.isEmpty ? nil : RefreshSection(sessions: sessions)
    }

    /// One refresh run for `dir`. Returns true when claude exited 0 (the
    /// caller then re-reads the keychain and fetches usage).
    static func run(dir: String, state: inout CollectorState, ctx: CollectorContext) -> Bool {
        let tag = ProfileTags.tag(configDir: dir, overrides: ctx.config.profileTags)
        var rec = RefreshSession(sessionId: ctx.newSessionID(), dir: dir, startedAt: ctx.now())
        func save() {
            var s = state.refresh?.sessions ?? []
            if let i = s.firstIndex(where: { $0.sessionId == rec.sessionId }) { s[i] = rec } else { s.append(rec) }
            state.refresh = RefreshSection(sessions: s)
        }
        guard let claude = ctx.claudePath else {
            rec.outcome = "no claude"; rec.finishedAt = rec.startedAt
            save()
            ctx.log.error("\(tag) token refresh skipped: claude not found")
            return false
        }
        rec.outcome = "running"
        save()
        ctx.checkpoint(state)
        ctx.sleep(TokenRefreshCfg.leadTime)

        let spec = command(claude: claude, configDir: dir, sessionID: rec.sessionId, ctx: ctx)
        let ok: Bool
        do {
            let r = try ctx.runProcess(spec)
            ok = !r.timedOut && r.status == 0
            rec.outcome = r.timedOut ? "timeout" : ok ? "ok" : "exit \(r.status)"
        } catch {
            ok = false
            rec.outcome = "launch failed"
        }
        rec.finishedAt = ctx.now()
        save()
        if ok { ctx.log.change("\(tag) token refresh ok") }
        else { ctx.log.error("\(tag) token refresh failed (\(rec.outcome ?? "?"))") }
        return ok
    }
}
