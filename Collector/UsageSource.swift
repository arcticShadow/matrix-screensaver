//
//  UsageSource.swift
//  Claude usage per account: for every `~/.claude*` config dir, read its OAuth
//  token from the keychain and GET the usage endpoint. Never refreshes tokens
//  (refresh tokens rotate; a race would log the CLI out): an expired token
//  just marks the account's data stale; once it is 2 h stale, TokenRefresh
//  has Claude Code refresh it (`claude -p`) and the account is fetched again.
//

import Foundation
import CryptoKit

enum CollectorSources {
    /// The collector's source registry. Add new sources here.
    static func standard() -> [CollectorSource] {
        [UsageSource(), CalendarSource()]
    }
}

/// Keychain service name for a config dir (verified against real items):
/// `~/.claude` -> `Claude Code-credentials`; any other dir -> that name +
/// `-` + the first 8 hex chars of sha256(exact absolute path, no trailing slash).
enum KeychainNaming {
    static let base = "Claude Code-credentials"

    static func serviceName(configDir: String, home: String) -> String {
        var path = configDir
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == (home as NSString).appendingPathComponent(".claude") { return base }
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return base + "-" + hex.prefix(8)
    }
}

struct UsageSource: CollectorSource {
    static let endpoint = "https://api.anthropic.com/api/oauth/usage"
    let id: SourceID = CollectorSourceIDs.usage
    let baseInterval: TimeInterval = 300

    struct UsageFailed: Error, CustomStringConvertible {
        var errors: Int
        var description: String { "no account fetched (\(errors) failing)" }
    }

    func fetch(_ state: inout CollectorState, _ ctx: CollectorContext) throws {
        let previous = Dictionary((state.usage?.accounts ?? []).map { ($0.dir, $0) },
                                  uniquingKeysWith: { a, _ in a })
        var accounts: [AccountUsage] = []
        var successes = 0, errors = 0
        TokenRefresh.prune(&state, now: ctx.now())
        for dir in (try? ConfigDirs.discover(home: ctx.home)) ?? [] {
            let before = previous[dir]
            var a = before ?? AccountUsage(dir: dir, token: .none)
            var outcome = fetchAccount(&a, ctx)
            if TokenRefresh.isDue(a, sessions: state.refresh?.sessions ?? [], now: ctx.now()),
               TokenRefresh.run(dir: dir, state: &state, ctx: ctx) {
                outcome = fetchAccount(&a, ctx)
            }
            switch outcome {
            case .success: successes += 1
            case .error: errors += 1
            case .skipped: break
            }
            logChange(before: before, after: a, ctx: ctx)
            accounts.append(a)
        }
        let failed = errors > 0 && successes == 0
        state.usage = UsageSection(generatedAt: failed ? state.usage?.generatedAt : ctx.now(),
                                   accounts: accounts)
        if failed { throw UsageFailed(errors: errors) }
    }

    private enum Outcome { case success, error, skipped }

    private func fetchAccount(_ a: inout AccountUsage, _ ctx: CollectorContext) -> Outcome {
        let path = (ctx.home as NSString).appendingPathComponent(a.dir)
        let token: String
        switch ctx.readKeychain(KeychainNaming.serviceName(configDir: path, home: ctx.home)) {
        case .notFound:
            a.token = .none; a.tokenExpiresAt = nil; a.lastError = nil
            return .skipped
        case .failed:
            a.token = .error; a.lastError = "KEYCHAIN"
            return .error
        case let .found(json):
            guard let t = Self.parseToken(json) else {
                a.token = .error; a.lastError = "KEYCHAIN.PARSE"
                return .error
            }
            token = t.access
            a.tokenExpiresAt = t.expiresAt
            if let exp = t.expiresAt, exp <= ctx.now() {
                a.token = .expired; a.lastError = nil
                return .skipped
            }
        }
        let req = HTTPRequest(url: Self.endpoint, headers: [
            "Authorization": "Bearer " + token,
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": ctx.userAgent,
            "Accept": "application/json",
        ])
        let resp: HTTPResponse
        do { resp = try ctx.http(req) } catch {
            a.token = .ok; a.lastError = "NETWORK"
            return .error
        }
        switch resp.status {
        case 200:
            guard let u = Self.parseUsage(resp.body) else {
                a.token = .ok; a.lastError = "PARSE"
                return .error
            }
            a.token = .ok; a.lastError = nil
            a.fiveHour = u.fiveHour; a.sevenDay = u.sevenDay; a.extra = u.extra
            a.generatedAt = ctx.now()
            return .success
        case 401, 403:
            a.token = .expired; a.lastError = nil
            return .skipped
        default:
            a.token = .ok; a.lastError = "HTTP \(resp.status)"
            return .error
        }
    }

    /// State changes only, by profile tag (never folder or service names).
    private func logChange(before: AccountUsage?, after: AccountUsage, ctx: CollectorContext) {
        let tag = ProfileTags.tag(configDir: after.dir, overrides: ctx.config.profileTags)
        if before?.token != after.token {
            ctx.log.change("\(tag) token \(after.token.rawValue)")
        }
        if before?.lastError != after.lastError {
            if let e = after.lastError { ctx.log.error("\(tag) usage \(e)") }
            else if before?.lastError != nil { ctx.log.change("\(tag) usage ok") }
        }
    }

    // MARK: Parsing

    struct Token { var access: String; var expiresAt: Date? }

    static func parseToken(_ json: String) -> Token? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty else { return nil }
        let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue
        return Token(access: access, expiresAt: ms.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    struct Usage { var fiveHour, sevenDay: UsageWindow?; var extra: ExtraUsage? }

    static func parseUsage(_ data: Data) -> Usage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj.keys.contains("five_hour") || obj.keys.contains("seven_day") else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let w = obj[key] as? [String: Any],
                  let u = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(utilization: u, resetsAt: (w["resets_at"] as? String).flatMap(parseDate))
        }
        var extra: ExtraUsage? = nil
        if let x = obj["extra_usage"] as? [String: Any] {
            extra = ExtraUsage(enabled: (x["is_enabled"] as? Bool) ?? false,
                               usedMinor: (x["used_credits"] as? NSNumber)?.doubleValue,
                               limitMinor: (x["monthly_limit"] as? NSNumber)?.doubleValue,
                               currency: (x["currency"] as? String) ?? "USD",
                               decimalPlaces: (x["decimal_places"] as? NSNumber)?.intValue ?? 2)
        }
        return Usage(fiveHour: window("five_hour"), sevenDay: window("seven_day"), extra: extra)
    }

    /// ISO-8601 with any number of fractional digits (the endpoint sends
    /// microseconds, which ISO8601DateFormatter rejects): drop the fraction.
    static func parseDate(_ s: String) -> Date? {
        var str = s
        if let dot = str.firstIndex(of: ".") {
            var end = str.index(after: dot)
            while end < str.endIndex, str[end].isNumber { end = str.index(after: end) }
            str.removeSubrange(dot..<end)
        }
        return ISO8601DateFormatter().date(from: str)
    }
}
