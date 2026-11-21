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
    /// Environment the child must not inherit: other credentials would make
    /// Claude Code skip the OAuth token, and Claude Code's own session markers
    /// (when the collector is run by hand from inside a session).
    static func isDropped(_ key: String) -> Bool {
        ["CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDECODE"].contains(key)
            || key.hasPrefix("CLAUDE_CODE_")
    }
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

    /// The child's environment: the collector's own, minus other credentials,
    /// with HOME/USER/LOGNAME always set from the passwd entry (never rely on
    /// launchd for them) and CLAUDE_CONFIG_DIR only for non-default dirs.
    /// (Setting it for `~/.claude` would change the keychain service name.)
    static func environment(configDir: String, home: String, user: String,
                            inherited: [String: String]) -> [String: String] {
        var env = inherited.filter { !TokenRefreshCfg.isDropped($0.key) }
        env["HOME"] = home
        env["USER"] = user
        env["LOGNAME"] = user
        if (env["PATH"] ?? "").isEmpty { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        let path = (home as NSString).appendingPathComponent(configDir)
        if configDir != ".claude" { env["CLAUDE_CONFIG_DIR"] = path }
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
            workingDirectory: (CollectorStateStore.defaultPath(home: ctx.home) as NSString)
                .deletingLastPathComponent,
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
