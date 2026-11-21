//
//  CalendarSource.swift
//  Upcoming calendar events (#11): `gws calendar +agenda --format json` for
//  the single signed-in Google account, every 5 min under the shared policy.
//  Keeps only summary, start, end and all-day-ness; the saver picks the next
//  event and decides (trusted network) whether the title may be shown.
//
//  SAFETY: gws derives its credential-encryption key from $USER. Run without
//  USER it fails to decrypt and DELETES the user's stored credentials. So the
//  child always gets USER/LOGNAME/HOME from the passwd entry, and the source
//  refuses to launch gws at all when the user name is unknown.
//

import Foundation

enum CalendarCfg {
    /// Agenda window from now. 2 days so a late-evening run still sees
    /// tomorrow morning.
    static let days = 2
    static let timeout: TimeInterval = 30
    /// Cap on events kept in the state file.
    static let maxEvents = 50
}

struct CalendarSource: CollectorSource {
    let id: SourceID = CollectorSourceIDs.calendar
    let baseInterval: TimeInterval = 300

    /// A failed agenda run. `category` is short and never contains event data.
    struct Failed: Error, CustomStringConvertible {
        var category: String
        var description: String { "calendar: \(category)" }
    }

    func fetch(_ state: inout CollectorState, _ ctx: CollectorContext) throws {
        do {
            let events = try Self.fetchEvents(ctx)
            state.calendar = CalendarSection(generatedAt: ctx.now(), events: events, lastError: nil)
        } catch let f as Failed {
            // Keep the last good events (the saver marks them stale).
            var section = state.calendar ?? CalendarSection(generatedAt: nil, events: [])
            section.lastError = f.category
            state.calendar = section
            throw f
        }
    }

    static func fetchEvents(_ ctx: CollectorContext) throws -> [CalendarEvent] {
        guard let gws = ctx.gwsPath else { throw Failed(category: "NO GWS") }
        guard !ctx.user.isEmpty, !ctx.home.isEmpty else { throw Failed(category: "NO USER") }
        let out: ProcessOutput
        do { out = try ctx.runAgenda(command(gws: gws, ctx: ctx)) } catch {
            throw Failed(category: "LAUNCH")
        }
        if out.timedOut { throw Failed(category: "TIMEOUT") }
        let events = try parse(out.stdout, exitStatus: out.status, now: ctx.now())
        return events
    }

    /// `gws calendar +agenda --days N --format json` (json passed explicitly:
    /// gws's own fallback is a table).
    static func command(gws: String, ctx: CollectorContext) -> ProcessSpec {
        ProcessSpec(executable: gws,
                    arguments: ["calendar", "+agenda", "--days", String(CalendarCfg.days), "--format", "json"],
                    environment: environment(home: ctx.home, user: ctx.user, inherited: ctx.environment),
                    workingDirectory: (CollectorStateStore.defaultPath(home: ctx.home) as NSString)
                        .deletingLastPathComponent,
                    timeout: CalendarCfg.timeout)
    }

    /// The collector's environment with HOME/USER/LOGNAME always set from the
    /// passwd entry (never trust launchd for them) and a PATH fallback.
    static func environment(home: String, user: String, inherited: [String: String]) -> [String: String] {
        var env = inherited
        env["HOME"] = home
        env["USER"] = user
        env["LOGNAME"] = user
        if (env["PATH"] ?? "").isEmpty { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        return env
    }

    /// Agenda JSON -> events that haven't ended, by start time. gws prints
    /// `{"error":{"code":401,"reason":"authError",...}}` and exits 2 on failure.
    static func parse(_ data: Data, exitStatus: Int32, now: Date,
                      timeZone: TimeZone = .current) throws -> [CalendarEvent] {
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let err = obj?["error"] as? [String: Any] {
            let reason = err["reason"] as? String ?? ""
            let code = err["code"] as? Int ?? 0
            throw Failed(category: reason == "authError" || code == 401 ? "AUTH" : "API \(code)")
        }
        guard exitStatus == 0 else { throw Failed(category: "EXIT \(exitStatus)") }
        guard let raw = obj?["events"] as? [[String: Any]] else { throw Failed(category: "PARSE") }
        let events: [CalendarEvent] = raw.compactMap { e in
            guard let s = e["start"] as? String, let en = e["end"] as? String,
                  let start = parseTime(s, timeZone), let end = parseTime(en, timeZone) else { return nil }
            let summary = (e["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(No title)"
            return CalendarEvent(summary: summary, start: start.date, end: end.date, allDay: start.dateOnly)
        }
        return Array(events.filter { $0.end > now }
                           .sorted { $0.start < $1.start }
                           .prefix(CalendarCfg.maxEvents))
    }

    /// RFC 3339 date-time (with or without fractional seconds), or a bare
    /// `YYYY-MM-DD` (all-day; local midnight).
    static func parseTime(_ s: String, _ tz: TimeZone) -> (date: Date, dateOnly: Bool)? {
        if !s.contains("T") {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = tz
            f.dateFormat = "yyyy-MM-dd"
            return f.date(from: s).map { ($0, true) }
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return (d, false) }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s).map { ($0, false) }
    }
}
