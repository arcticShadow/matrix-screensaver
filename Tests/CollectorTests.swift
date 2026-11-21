//
//  CollectorTests.swift — seam 2, the collector: fake home tree, fake keychain,
//  fake HTTP client and a settable clock in; the state file (as the saver will
//  read it) and the log out. Never touches the real keychain or network.
//

import Foundation

/// A fake world for collector runs.
final class FakeCollector {
    let home: String
    var now: Date
    /// Keychain items by config dir basename (the fake resolves the service
    /// name with the production naming rule, tested separately below).
    var tokens: [String: String] = [:]
    var keychainFailures: Set<String> = []
    /// Usage responses by bearer token.
    var responses: [String: (Int, String)] = [:]
    var networkDown = false
    /// Fake fetch time per HTTP call (advances the clock).
    var httpDuration: TimeInterval = 0.5
    private(set) var requests: [HTTPRequest] = []
    private(set) var keychainLookups: [String] = []
    let log: CollectorLog
    var config = DiagConfig()
    /// `claude -p` refresh runs (Tests/RefreshTests.swift). nil = not installed.
    var claudePath: String? = "/opt/fake/bin/claude"
    var inheritedEnv: [String: String] = ["PATH": "/usr/bin:/bin"]
    /// What a refresh run does; default: the CLI refreshes its token.
    var onRefresh: ((ProcessSpec) -> ProcessResult)?
    var refreshDuration: TimeInterval = 4
    private(set) var processes: [ProcessSpec] = []
    /// Collector state on disk at the moment each process was launched.
    private(set) var stateAtLaunch: [CollectorState?] = []
    private(set) var sleeps: [TimeInterval] = []
    private var sessionCounter = 0
    /// Sources a run uses. Usage-only by default (the usage tests predate the
    /// calendar); calendar tests use `CollectorSources.standard()`.
    var sources: [CollectorSource] = [UsageSource()]
    /// `gws` (Tests/CalendarTests.swift). nil = not installed.
    var gwsPath: String? = "/opt/fake/bin/gws"
    /// The fake agenda runner's answer: exit status + stdout. Never the real gws.
    var agenda: (status: Int32, stdout: String) = (0, #"{"events":[],"count":0}"#)
    var agendaTimesOut = false
    var agendaDuration: TimeInterval = 2
    private(set) var agendaRuns: [ProcessSpec] = []

    struct NetworkError: Error {}

    init(_ name: String, now: Date = Date(timeIntervalSince1970: 1_795_271_405), logPath: String? = nil) {
        home = makeTempDir(name)
        self.now = now
        var clock: (() -> Date)!
        log = CollectorLog(path: logPath, now: { clock() })
        clock = { [unowned self] in self.now }
    }

    var statePath: String { CollectorStateStore.defaultPath(home: home) }

    /// Create `~/<dir>` with an optional token (expiring `expiresIn` from now).
    func addAccount(_ dir: String, token: String? = nil, expiresIn: TimeInterval = 3600) {
        try? FileManager.default.createDirectory(atPath: "\(home)/\(dir)", withIntermediateDirectories: true)
        if let token {
            let ms = Int((now.timeIntervalSince1970 + expiresIn) * 1000)
            tokens[dir] = #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"rt-\#(token)","expiresAt":\#(ms),"scopes":["user:inference"]}}"#
        }
    }

    var ctx: CollectorContext {
        let names = Dictionary(uniqueKeysWithValues: tokens.keys.map {
            (KeychainNaming.serviceName(configDir: "\(home)/\($0)", home: home), $0)
        })
        let failing = Set(keychainFailures.map { KeychainNaming.serviceName(configDir: "\(home)/\($0)", home: home) })
        return CollectorContext(
            now: { [unowned self] in self.now },
            home: home,
            config: config,
            readKeychain: { [unowned self] svc in
                self.keychainLookups.append(svc)
                if failing.contains(svc) { return .failed(51) }
                guard let dir = names[svc], let json = self.tokens[dir] else { return .notFound }
                return .found(json)
            },
            http: { [unowned self] req in
                self.requests.append(req)
                self.now = self.now.addingTimeInterval(self.httpDuration)
                if self.networkDown { throw NetworkError() }
                let bearer = String((req.headers["Authorization"] ?? "").dropFirst("Bearer ".count))
                let (status, body) = self.responses[bearer] ?? (404, "{}")
                return HTTPResponse(status: status, body: Data(body.utf8))
            },
            userAgent: "claude-cli/9.9.9 (external, cli)",
            log: log,
            user: "someone",
            environment: inheritedEnv,
            claudePath: claudePath,
            runProcess: { [unowned self] spec in
                self.processes.append(spec)
                self.stateAtLaunch.append(self.state())
                self.now = self.now.addingTimeInterval(self.refreshDuration)
                if let f = self.onRefresh { return f(spec) }
                self.refreshToken(for: spec)
                return ProcessResult(status: 0, timedOut: false)
            },
            newSessionID: { [unowned self] in
                self.sessionCounter += 1
                return String(format: "00000000-0000-4000-8000-%012d", self.sessionCounter)
            },
            sleep: { [unowned self] s in self.sleeps.append(s); self.now = self.now.addingTimeInterval(s) },
            gwsPath: gwsPath,
            runAgenda: { [unowned self] spec in
                self.agendaRuns.append(spec)
                self.now = self.now.addingTimeInterval(self.agendaDuration)
                return ProcessOutput(status: self.agendaTimesOut ? 15 : self.agenda.status,
                                     timedOut: self.agendaTimesOut, stdout: Data(self.agenda.stdout.utf8))
            })
    }

    /// Config dir basename a refresh process targets (no CLAUDE_CONFIG_DIR = `~/.claude`).
    func dir(of spec: ProcessSpec) -> String {
        spec.environment["CLAUDE_CONFIG_DIR"].map { ($0 as NSString).lastPathComponent } ?? ".claude"
    }

    /// What Claude Code does on a successful run: a new access token (8 h).
    func refreshToken(for spec: ProcessSpec) {
        let d = dir(of: spec)
        guard tokens[d] != nil else { return }
        let fresh = "tok-fresh-\(processes.count)"
        addAccount(d, token: fresh, expiresIn: 8 * 3600)
        if responses[fresh] == nil { responses[fresh] = (200, usageBody(five: 55, seven: 44)) }
    }

    @discardableResult
    func run(force: Bool = false,
             write: ((Data, String) throws -> Void)? = nil) -> CollectorRunReport {
        if let write {
            return Collector.run(statePath: statePath, sources: sources, ctx: ctx, force: force, write: write)
        }
        return Collector.run(statePath: statePath, sources: sources, ctx: ctx, force: force)
    }

    func state() -> CollectorState? { try? CollectorStateStore.load(path: statePath) }
    func account(_ dir: String) -> AccountUsage? { state()?.usage?.accounts.first { $0.dir == dir } }
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

/// A 200 usage body in the endpoint's shape (utilisation in percent, resets
/// with microseconds and a +00:00 offset, extra amounts in minor units).
func usageBody(five: Double, seven: Double, extraEnabled: Bool = false,
               used: Double? = nil, limit: Double? = nil, currency: String = "NZD") -> String {
    func j(_ v: Double?) -> String { v.map { "\($0)" } ?? "null" }
    return """
    {"five_hour":{"utilization":\(five),"resets_at":"2026-11-21T16:44:00.460219+00:00","limit_dollars":null},
     "seven_day":{"utilization":\(seven),"resets_at":"2026-11-25T17:42:05.112233+00:00","limit_dollars":null},
     "seven_day_opus":null,
     "extra_usage":{"is_enabled":\(extraEnabled),"monthly_limit":\(j(limit)),"used_credits":\(j(used)),
                    "utilization":null,"currency":"\(currency)","decimal_places":2,"disabled_reason":null},
     "limits":[], "member_dashboard_available":false}
    """
}

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

func collectorTests() {
    test("keychain service name: .claude is bare, other dirs get a sha256(path) suffix") {
        expectEqual(KeychainNaming.serviceName(configDir: "/home/example/.claude", home: "/home/example"),
                    "Claude Code-credentials")
        expectEqual(KeychainNaming.serviceName(configDir: "/home/example/.claude-alpha", home: "/home/example"),
                    "Claude Code-credentials-90d24236")
        // A trailing slash would change the hash: it is stripped first.
        expectEqual(KeychainNaming.serviceName(configDir: "/home/example/.claude-alpha/", home: "/home/example"),
                    "Claude Code-credentials-90d24236")
    }

    test("usage is written per account for several accounts") {
        let w = FakeCollector("col-multi")
        w.addAccount(".claude", token: "tok-w")
        w.addAccount(".claude-alpha", token: "tok-a")
        w.addAccount(".claude-beta", token: "tok-b")
        writeFile("\(w.home)/.claude.json", "{}")   // a file, not a config dir
        w.responses["tok-w"] = (200, usageBody(five: 37, seven: 12))
        w.responses["tok-a"] = (200, usageBody(five: 90, seven: 75.5, extraEnabled: true, used: 1240, limit: 5000))
        w.responses["tok-b"] = (200, usageBody(five: 0, seven: 2, extraEnabled: false))
        let report = w.run()
        expectEqual(report, CollectorRunReport(ran: ["USAGE"], skipped: [], failed: [], wrote: true))
        let s = w.state()
        expectEqual(s?.usage?.accounts.map(\.dir), [".claude", ".claude-alpha", ".claude-beta"])
        let wrk = w.account(".claude")
        expectEqual(wrk?.token, .ok)
        expectEqual(wrk?.fiveHour, UsageWindow(utilization: 37, resetsAt: date("2026-11-21T16:44:00Z")))
        expectEqual(wrk?.sevenDay, UsageWindow(utilization: 12, resetsAt: date("2026-11-25T17:42:05Z")))
        expectEqual(wrk?.extra?.enabled, false)
        expect(wrk?.generatedAt != nil, "per-account generatedAt")
        expect(s?.usage?.generatedAt != nil, "per-section generatedAt")
        expectEqual(w.account(".claude-alpha")?.extra,
                    ExtraUsage(enabled: true, usedMinor: 1240, limitMinor: 5000, currency: "NZD", decimalPlaces: 2))
        expectEqual(w.account(".claude-beta")?.sevenDay?.utilization, 2)
        // Request shape: GET usage endpoint, bearer token, beta + UA headers.
        expectEqual(w.requests.count, 3)
        let r = w.requests[0]
        expectEqual(r.method, "GET")
        expectEqual(r.url, "https://api.anthropic.com/api/oauth/usage")
        expectEqual(r.headers["Authorization"], "Bearer tok-w")
        expectEqual(r.headers["anthropic-beta"], "oauth-2025-04-20")
        expectEqual(r.headers["User-Agent"], "claude-cli/9.9.9 (external, cli)")
    }

    test("a dir without a keychain item is recorded as token none, with no request") {
        let w = FakeCollector("col-none")
        w.addAccount(".claude", token: "tok-w")
        w.addAccount(".claude-idle")
        w.responses["tok-w"] = (200, usageBody(five: 1, seven: 1))
        w.run()
        expectEqual(w.account(".claude-idle")?.token, AccountUsage.TokenState.none)
        expectEqual(w.requests.count, 1)
    }

    test("expired token: no request, previous data kept and flagged expired (stale)") {
        let w = FakeCollector("col-expired")
        w.addAccount(".claude", token: "tok-w", expiresIn: 600)
        w.responses["tok-w"] = (200, usageBody(five: 40, seven: 20))
        w.run()
        let firstFetch = w.account(".claude")?.generatedAt
        w.advance(1200)   // token now expired, usage due again
        let report = w.run()
        expectEqual(report.failed, [])
        let a = w.account(".claude")
        expectEqual(a?.token, .expired)
        expectEqual(a?.fiveHour?.utilization, 40)
        expectEqual(a?.generatedAt, firstFetch)
        expectEqual(w.requests.count, 1)
    }

    test("a 401 from the endpoint marks the token expired and keeps old data") {
        let w = FakeCollector("col-401")
        w.addAccount(".claude", token: "tok-w")
        w.responses["tok-w"] = (200, usageBody(five: 40, seven: 20))
        w.run()
        w.responses["tok-w"] = (401, #"{"type":"error","error":{"type":"authentication_error"}}"#)
        w.advance(301)
        w.run()
        expectEqual(w.account(".claude")?.token, .expired)
        expectEqual(w.account(".claude")?.sevenDay?.utilization, 20)
    }

    test("not-due source is skipped: no keychain read, no request, state still written") {
        let w = FakeCollector("col-due")
        w.addAccount(".claude", token: "tok-w")
        w.responses["tok-w"] = (200, usageBody(five: 1, seven: 1))
        w.run()
        let lookups = w.keychainLookups.count
        w.advance(60)
        let r = w.run()
        expectEqual(r.ran, [])
        expectEqual(r.skipped, ["USAGE"])
        expect(r.wrote)
        expectEqual(w.keychainLookups.count, lookups)
        expectEqual(w.requests.count, 1)
        w.advance(241)   // 301 s after the first run's end
        expectEqual(w.run().ran, ["USAGE"])
        expectEqual(w.requests.count, 2)
    }

    test("slow fetches throttle the interval to 20x the fetch time") {
        let w = FakeCollector("col-throttle")
        w.addAccount(".claude", token: "tok-w")
        w.responses["tok-w"] = (200, usageBody(five: 1, seven: 1))
        w.httpDuration = 20                // 20 s fetch -> refresh every 400 s, not 300
        w.run()
        expectEqual(w.state()?.schedules["USAGE"]?.refreshInterval, 400)
        w.advance(350)
        expectEqual(w.run().ran, [])
        w.advance(60)
        expectEqual(w.run().ran, ["USAGE"])
    }

    test("failures back off exponentially, capped at 10x base") {
        let w = FakeCollector("col-backoff")
        w.addAccount(".claude", token: "tok-w", expiresIn: 86400)
        w.networkDown = true
        w.httpDuration = 0
        var intervals: [TimeInterval] = []
        for _ in 0..<6 {
            let r = w.run(force: false)
            expectEqual(r.failed, ["USAGE"])
            let sch = w.state()!.schedules["USAGE"]!
            intervals.append(sch.effectiveInterval)
            w.advance(sch.effectiveInterval - 1)
            expect(w.run().ran.isEmpty, "not due one second early")
            w.advance(1)
        }
        expectEqual(intervals, [600, 1200, 2400, 3000, 3000, 3000])
        w.networkDown = false
        w.responses["tok-w"] = (200, usageBody(five: 1, seven: 1))
        expectEqual(w.run().failed, [])
        expectEqual(w.state()?.schedules["USAGE"]?.effectiveInterval, 300)
    }

    test("one failing account does not fail the source when another succeeds") {
        let w = FakeCollector("col-partial")
        w.addAccount(".claude", token: "tok-w")
        w.addAccount(".claude-alpha", token: "tok-a")
        w.responses["tok-w"] = (200, usageBody(five: 1, seven: 1))
        w.responses["tok-a"] = (503, "oops")
        expectEqual(w.run().failed, [])
        expectEqual(w.account(".claude-alpha")?.lastError, "HTTP 503")
        expectEqual(w.account(".claude")?.lastError, nil)
    }

    test("atomic write: a failure before rename leaves the old file intact and no temp file") {
        let w = FakeCollector("col-atomic")
        w.addAccount(".claude", token: "tok-w")
        w.responses["tok-w"] = (200, usageBody(five: 11, seven: 1))
        w.run()
        let before = FileManager.default.contents(atPath: w.statePath)
        w.responses["tok-w"] = (200, usageBody(five: 99, seven: 1))
        struct Boom: Error {}
        let r = w.run(force: true, write: { data, path in
            try AtomicFile.write(data, to: path, beforeRename: { throw Boom() })
        })
        expect(!r.wrote, "write should report failure")
        expectEqual(FileManager.default.contents(atPath: w.statePath), before)
        let dir = (w.statePath as NSString).deletingLastPathComponent
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["collector-state.json"])
        expectEqual(w.account(".claude")?.fiveHour?.utilization, 11)
        expect(w.log.lines.contains { $0.contains("ERROR state write failed") }, "write failure logged")
    }

    test("never calls the OAuth refresh endpoint: only GETs to the usage endpoint, in every scenario") {
        let w = FakeCollector("col-norefresh")
        w.addAccount(".claude", token: "tok-w", expiresIn: -10)       // expired
        w.addAccount(".claude-alpha", token: "tok-a")                  // 401
        w.addAccount(".claude-beta", token: "tok-b")                   // ok
        w.addAccount(".claude-gamma")                                  // no token
        w.responses["tok-a"] = (401, "{}")
        w.responses["tok-b"] = (200, usageBody(five: 1, seven: 1))
        for _ in 0..<3 { w.run(force: true); w.advance(4000) }
        w.networkDown = true
        w.run(force: true)
        expect(!w.requests.isEmpty)
        for r in w.requests {
            expectEqual(r.method, "GET")
            expectEqual(r.url, UsageSource.endpoint)
            expect(!r.url.contains("token"), "no token endpoint")
            expect(!r.headers.values.contains { $0.contains("rt-") }, "refresh token never sent")
        }
    }

    test("the live HTTP client refuses anything but GET to the usage endpoint") {
        expect(LiveHTTP.isAllowed(HTTPRequest(url: UsageSource.endpoint)))
        expect(!LiveHTTP.isAllowed(HTTPRequest(url: "https://console.anthropic.com/v1/oauth/token")))
        expect(!LiveHTTP.isAllowed(HTTPRequest(url: "https://api.anthropic.com/v1/oauth/token")))
        expect(!LiveHTTP.isAllowed(HTTPRequest(method: "POST", url: UsageSource.endpoint)))
    }

    test("unreadable state file: start fresh and log it") {
        let w = FakeCollector("col-corrupt")
        writeFile(w.statePath, "{ not json")
        w.addAccount(".claude", token: "tok-w")
        w.responses["tok-w"] = (200, usageBody(five: 5, seven: 5))
        expectEqual(w.run().ran, ["USAGE"])
        expectEqual(w.account(".claude")?.fiveHour?.utilization, 5)
        expect(w.log.lines.contains { $0.contains("state file unreadable") })
    }

    test("log: only errors and state changes, never tokens, service names or folder names") {
        let logPath = makeTempDir("col-log") + "/collector.log"
        let w = FakeCollector("col-logcontent", logPath: logPath)
        w.config.profileTags = [".claude-alpha": "ZED"]
        w.addAccount(".claude", token: "tok-secret-w")
        w.addAccount(".claude-alpha", token: "tok-secret-a")
        w.responses["tok-secret-w"] = (200, usageBody(five: 1, seven: 1))
        w.responses["tok-secret-a"] = (200, usageBody(five: 1, seven: 1))
        w.run()
        let quietRunStart = w.log.lines.count
        w.advance(301); w.run()                      // nothing changed: nothing logged
        expectEqual(w.log.lines.count, quietRunStart)
        w.responses["tok-secret-a"] = (500, "x")
        w.advance(301); w.run()
        w.responses["tok-secret-a"] = (401, "x")
        w.advance(301); w.run()
        let text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        expect(text.contains("ZED"), "accounts appear by profile tag")
        expect(text.contains("HTTP 500"), "error logged")
        expect(text.contains("expired"), "token state change logged")
        for banned in ["tok-secret", "rt-", "Claude Code-credentials", ".claude", w.home] {
            expect(!text.contains(banned), "log must not contain \(banned)")
        }
        for l in text.split(separator: "\n") {
            expect(l.contains(" ERROR ") || l.contains(" STATE "), "unexpected log line kind: \(l)")
        }
    }

    test("log is truncated once it passes 1 MB") {
        let dir = makeTempDir("col-trunc")
        let path = dir + "/collector.log"
        writeFile(path, String(repeating: "x", count: 1_000_001))
        let log = CollectorLog(path: path, now: { Date(timeIntervalSince1970: 0) })
        log.error("after")
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? -1
        expect(size > 0 && size < 1000, "expected a small file after truncation, got \(size)")
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        expect(text.contains("log truncated") && text.contains("ERROR after"))
        // Under the limit: plain append.
        log.error("again")
        let text2 = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        expect(text2.hasPrefix(text) && text2.contains("ERROR again"))
    }

    test("binary resolution: known absolute locations first, PATH fallback, cmux shims skipped") {
        let exists: (String) -> Bool = { ["/opt/homebrew/bin/claude", "/h/.cmuxterm/x/claude", "/usr/bin/foo"].contains($0) }
        expectEqual(BinaryResolver.resolve("claude", home: "/h", path: "/h/.cmuxterm/x:/usr/bin", isExecutable: exists),
                    "/opt/homebrew/bin/claude")
        expectEqual(BinaryResolver.resolve("foo", home: "/h", path: "/h/.cmuxterm/x:/usr/bin", isExecutable: exists),
                    "/usr/bin/foo")
        expectEqual(BinaryResolver.resolve("claude", home: "/h", path: "/h/.cmuxterm/x",
                                           isExecutable: { $0 == "/h/.cmuxterm/x/claude" }), nil)
    }
}
