//
//  CalendarTests.swift — the calendar (#11) at both seams:
//   - collector: FakeCollector with an injected agenda runner (never the real
//     `gws`) and clock in; the state file's calendar section, schedule and log out.
//   - saver: a collector state file in a fake home + Wi-Fi trust in; the SYS
//     panel's CALENDAR lines out (DiagnosticsCore, manual polling).
//  Event titles here are made up.
//

import Foundation

/// `gws calendar +agenda --format json` output (v0.22.5 shape: no all-day
/// flag, a bare date for all-day events, sorted by string, private
/// `calendar`/`location` fields the collector must drop).
func agendaJSON(_ events: [(start: String, end: String, summary: String)]) -> String {
    let items = events.map {
        #"{"start":"\#($0.start)","end":"\#($0.end)","summary":"\#($0.summary)","calendar":"Private Cal","location":"Room 9"}"#
    }
    return #"{"events":[\#(items.joined(separator: ","))],"count":\#(events.count),"timeMin":"x","timeMax":"y"}"#
}

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

extension FakeWorld {
    /// A collector state as of `now` holding these events (calendar fetched `age` ago).
    func writeCalendar(_ events: [CalendarEvent], age: TimeInterval = 30, lastError: String? = nil,
                       neverSucceeded: Bool = false) {
        var sched = SourceSchedule(baseInterval: 300)
        sched.recordSuccess(at: now.addingTimeInterval(-age), duration: 2.1)
        writeCollectorState(CollectorState(
            generatedAt: now.addingTimeInterval(-5),
            schedules: [CollectorSourceIDs.calendar: sched],
            calendar: CalendarSection(generatedAt: neverSucceeded ? nil : now.addingTimeInterval(-age),
                                      events: events, lastError: lastError)))
    }
    /// A timed event starting `inMin` minutes from now (negative = started already).
    func event(_ title: String, inMin: Double, lengthMin: Double = 30) -> CalendarEvent {
        let start = now.addingTimeInterval(inMin * 60)
        return CalendarEvent(summary: title, start: start, end: start.addingTimeInterval(lengthMin * 60), allDay: false)
    }
    func allDay(_ title: String) -> CalendarEvent {
        CalendarEvent(summary: title, start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(20 * 3600),
                      allDay: true)
    }
    /// SYS panel after one poll, on a trusted (or untrusted) Wi-Fi.
    func calendarPanel(trusted: Bool = true) -> Panel {
        writeConfig(trustedConfig)
        wifi = trusted ? "TrustedNet" : "CafeNet"
        let c = DiagnosticsCore(env: env, polling: .manual)
        c.pollNow()
        return c.panels()[0]
    }
}

private func calendarLines(_ p: Panel) -> [PanelLine] {
    guard let i = p.lines.firstIndex(where: { $0.label == "CALENDAR" }) else { return [] }
    var out = [p.lines[i]]
    for l in p.lines[(i + 1)...] {
        if l.style == .section || l.style == .rule { break }
        out.append(l)
    }
    return out
}

func calendarTests() {
    // MARK: Collector

    test("calendar collector: agenda JSON -> summary/start/end/all-day only, sorted by real time") {
        let w = FakeCollector("cal-parse", now: date("2026-11-21T01:00:00Z"))
        w.sources = CollectorSources.standard()
        w.agenda = (0, agendaJSON([
            ("2026-11-21", "2026-11-22", "Holiday"),
            ("2026-11-21T14:30:00+13:00", "2026-11-21T15:00:00+13:00", "Standup"),   // 01:30Z
            ("2026-11-21T01:15:00Z", "2026-11-21T01:45:00Z", "Design review"),        // sorts first by time
        ]))
        let report = w.run()
        expect(report.ran.contains("CALENDAR"), "calendar ran: \(report)")
        expectEqual(report.failed, [])
        let cal = w.state()?.calendar
        expectEqual(cal?.generatedAt, date("2026-11-21T01:00:02Z"))
        expectEqual(cal?.events.count, 3)
        let timed = cal?.events.filter { !$0.allDay } ?? []
        expectEqual(timed.map(\.summary), ["Design review", "Standup"])
        expectEqual(timed.map(\.start), [date("2026-11-21T01:15:00Z"), date("2026-11-21T01:30:00Z")])
        expectEqual(timed.map(\.end), [date("2026-11-21T01:45:00Z"), date("2026-11-21T02:00:00Z")])
        expectEqual(cal?.events.filter(\.allDay).map(\.summary), ["Holiday"])
        let raw = String(decoding: FileManager.default.contents(atPath: w.statePath) ?? Data(), as: UTF8.self)
        expect(!raw.contains("Private Cal") && !raw.contains("Room 9"), "calendar/location names dropped")
    }

    test("calendar collector: gws runs with USER, LOGNAME and HOME set, JSON format, from the resolved path") {
        let w = FakeCollector("cal-env")
        w.sources = [CalendarSource()]
        w.inheritedEnv = ["PATH": "/usr/bin:/bin"]          // launchd-like: no USER/HOME inherited
        w.run()
        expectEqual(w.agendaRuns.count, 1)
        let spec = w.agendaRuns[0]
        expectEqual(spec.executable, "/opt/fake/bin/gws")
        expectEqual(spec.arguments, ["calendar", "+agenda", "--days", "2", "--format", "json"])
        expectEqual(spec.environment["USER"], "someone")
        expectEqual(spec.environment["LOGNAME"], "someone")
        expectEqual(spec.environment["HOME"], w.home)
        expectEqual(spec.environment["PATH"], "/usr/bin:/bin")
    }

    test("calendar collector: never launches gws without a user name (gws would wipe its credentials)") {
        let w = FakeCollector("cal-nouser")
        w.sources = [CalendarSource()]
        var ctx = w.ctx
        ctx.user = ""
        let r = Collector.run(statePath: w.statePath, sources: w.sources, ctx: ctx)
        expectEqual(r.failed, ["CALENDAR"])
        expectEqual(w.agendaRuns.count, 0)
    }

    test("calendar collector: gws not installed -> failure, no launch") {
        let w = FakeCollector("cal-nogws")
        w.sources = [CalendarSource()]
        w.gwsPath = nil
        expectEqual(w.run().failed, ["CALENDAR"])
        expectEqual(w.agendaRuns.count, 0)
        expectEqual(w.state()?.calendar?.lastError, "NO GWS")
    }

    test("calendar collector: auth failure backs off exponentially, keeps the last good events, logs no titles") {
        let w = FakeCollector("cal-backoff")
        w.sources = [CalendarSource()]
        w.agendaDuration = 0
        w.agenda = (0, agendaJSON([("2026-11-22T14:30:00Z", "2026-11-22T15:00:00Z", "Secret Offsite")]))
        w.run()
        let good = w.state()?.calendar
        expectEqual(good?.events.count, 1)
        w.advance(300)
        w.agenda = (2, #"{"error":{"code":401,"message":"Token has been expired or revoked","reason":"authError"}}"#)
        var intervals: [TimeInterval] = []
        for _ in 0..<5 {
            expectEqual(w.run().failed, ["CALENDAR"])
            let sch = w.state()!.schedules["CALENDAR"]!
            intervals.append(sch.effectiveInterval)
            w.advance(sch.effectiveInterval - 1)
            expect(w.run().ran.isEmpty, "not due one second early")
            w.advance(1)
        }
        expectEqual(intervals, [600, 1200, 2400, 3000, 3000])
        let cal = w.state()?.calendar
        expectEqual(cal?.events, good?.events)
        expectEqual(cal?.generatedAt, good?.generatedAt)
        expectEqual(cal?.lastError, "AUTH")
        expect(w.log.lines.contains { $0.contains("CALENDAR source failed") }, "failure logged")
        expect(!w.log.lines.joined().contains("Secret"), "titles never logged")
        // Recovery.
        w.agenda = (0, agendaJSON([]))
        expectEqual(w.run().failed, [])
        expectEqual(w.state()?.calendar?.lastError, nil)
        expectEqual(w.state()?.schedules["CALENDAR"]?.effectiveInterval, 300)
    }

    test("calendar collector: non-zero exit, garbage output and timeouts are failures") {
        for (status, out, timeout, category) in [(Int32(1), "boom", false, "EXIT 1"),
                                                 (0, "not json", false, "PARSE"),
                                                 (0, "", true, "TIMEOUT")] {
            let w = FakeCollector("cal-fail")
            w.sources = [CalendarSource()]
            w.agenda = (status, out)
            w.agendaTimesOut = timeout
            expectEqual(w.run().failed, ["CALENDAR"])
            expectEqual(w.state()?.calendar?.lastError, category)
        }
    }

    test("calendar collector: events that already ended are dropped; untitled events get a placeholder") {
        let w = FakeCollector("cal-ended", now: date("2026-11-21T01:00:00Z"))
        w.sources = [CalendarSource()]
        w.agenda = (0, agendaJSON([("2026-11-21T00:00:00Z", "2026-11-21T00:59:00Z", "Over"),
                                   ("2026-11-21T00:30:00Z", "2026-11-21T01:30:00Z", "")]))
        w.run()
        expectEqual(w.state()?.calendar?.events.map(\.summary), ["(No title)"])
    }

    test("due-source selection: calendar and usage keep their own cadence in one collector") {
        let w = FakeCollector("cal-due")
        w.sources = CollectorSources.standard()
        w.addAccount(".claude", token: "tok-w")
        w.responses["tok-w"] = (200, usageBody(five: 1, seven: 1))
        w.httpDuration = 0
        w.agendaDuration = 0
        expectEqual(w.run().ran, ["USAGE", "CALENDAR"])
        w.advance(60)
        let idle = w.run()
        expectEqual(idle.ran, [])
        expectEqual(idle.skipped, ["USAGE", "CALENDAR"])
        // Calendar fails once and backs off to 600 s; usage stays on 300 s.
        w.advance(240)
        w.agenda = (2, #"{"error":{"code":401,"reason":"authError"}}"#)
        let r = w.run()
        expectEqual(r.ran, ["USAGE", "CALENDAR"])
        expectEqual(r.failed, ["CALENDAR"])
        w.advance(300)
        let next = w.run()
        expectEqual(next.ran, ["USAGE"])
        expectEqual(next.skipped, ["CALENDAR"])
        w.advance(300)
        expectEqual(w.run().ran, ["USAGE", "CALENDAR"])
        expectEqual(w.agendaRuns.count, 3)
        expectEqual(w.requests.count, 4)
    }

    test("live process capture: stdout captured, exact environment passed, timeout enforced (no gws involved)") {
        let dir = makeTempDir("cal-capture")
        let ok = try LiveProcess.capture(ProcessSpec(executable: "/bin/sh", arguments: ["-c", "printf '%s|%s' \"$USER\" \"$HOME\"; exit 3"],
                                                     environment: ["USER": "someone", "HOME": "/home/someone"],
                                                     workingDirectory: dir, timeout: 10))
        expectEqual(ok, ProcessOutput(status: 3, timedOut: false, stdout: Data("someone|/home/someone".utf8)))
        let slow = try LiveProcess.capture(ProcessSpec(executable: "/bin/sleep", arguments: ["5"], environment: [:],
                                                       workingDirectory: dir, timeout: 0.3))
        expect(slow.timedOut, "timed out")
    }

    // MARK: Saver

    test("calendar panel: next upcoming non-all-day event with local start time and countdown") {
        let w = FakeWorld("cal-next")                        // 14:30:05 UTC
        w.writeCalendar([w.allDay("Holiday"), w.event("Retro", inMin: 90), w.event("Standup", inMin: 22)])
        expectEqual(calendarLines(w.calendarPanel()), [
            .section("CALENDAR"),
            .field("NEXT", "14:52 Standup (in 22m)"),
        ])
    }

    test("calendar panel: all-day events are skipped even when they are the only ones") {
        let w = FakeWorld("cal-allday")
        w.writeCalendar([w.allDay("Holiday")])
        expectEqual(calendarLines(w.calendarPanel()), [.section("CALENDAR"), .field("NEXT", "NONE", .dim)])
    }

    test("calendar panel: an event in progress shows NOW ▸ <title>") {
        let w = FakeWorld("cal-now")
        w.writeCalendar([w.event("Design review", inMin: -10, lengthMin: 60), w.event("Standup", inMin: 22)])
        expectEqual(calendarLines(w.calendarPanel()), [.section("CALENDAR"), .field("NOW", "▸ Design review", .ok)])
        // Over: the next one takes its place (the data itself is not re-fetched).
        let later = FakeWorld("cal-now-over")
        later.writeCalendar([later.event("Design review", inMin: -60, lengthMin: 59.9), later.event("Standup", inMin: 5)])
        expectEqual(later.calendarPanel().line("NEXT"), .field("NEXT", "14:35 Standup (in 5m)", .warn))
    }

    test("calendar panel: countdown formatting (rounded up; hours, days); amber within 5 min") {
        let cases: [(Double, String, Severity)] = [
            (0.5, "14:30 Standup (in 1m)", .warn),
            (5, "14:35 Standup (in 5m)", .warn),
            (6, "14:36 Standup (in 6m)", .normal),
            (65, "15:35 Standup (in 1h05m)", .normal),
            (60 * 27 + 3, "17:33 Standup (in 1d03h)", .normal),
        ]
        for (mins, value, sev) in cases {
            let w = FakeWorld("cal-countdown")
            w.writeCalendar([w.event("Standup", inMin: mins)])
            expectEqual(w.calendarPanel().line("NEXT"), .field("NEXT", value, sev))
        }
    }

    test("calendar panel: long titles are truncated") {
        let w = FakeWorld("cal-long")
        w.writeCalendar([w.event("Quarterly planning and roadmap alignment", inMin: 22)])
        expectEqual(w.calendarPanel().value(of: "NEXT"), "14:52 Quarterly planning and… (in 22m)")
    }

    test("calendar panel: titles only on a trusted network; untrusted or unreadable Wi-Fi -> EVENT") {
        let w = FakeWorld("cal-untrusted")
        w.writeCalendar([w.event("Secret Offsite", inMin: 22)])
        expectEqual(w.calendarPanel(trusted: false).value(of: "NEXT"), "14:52 EVENT (in 22m)")
        let n = FakeWorld("cal-now-untrusted")
        n.writeCalendar([n.event("Secret Offsite", inMin: -5)])
        expectEqual(n.calendarPanel(trusted: false).value(of: "NOW"), "▸ EVENT")
        let u = FakeWorld("cal-unreadable")
        u.writeCalendar([u.event("Secret Offsite", inMin: 22)])
        u.writeConfig(trustedConfig)
        u.wifiFail = true
        let c = DiagnosticsCore(env: u.env, polling: .manual)
        c.pollNow()
        expectEqual(c.panels()[0].value(of: "NEXT"), "14:52 EVENT (in 22m)")
        expect(!c.panels()[0].lines.contains { $0.value.contains("Secret") }, "title leaked")
    }

    test("calendar panel: no state file, or no calendar section -> COLLECTOR OFFLINE") {
        let w = FakeWorld("cal-offline")
        expectEqual(calendarLines(w.calendarPanel()), [.section("CALENDAR"), .text("COLLECTOR OFFLINE", .dim)])
        let n = FakeWorld("cal-nosection")
        n.writeCollectorState(n.collectorState([n.account(".claude")]))
        expectEqual(calendarLines(n.calendarPanel()), [.section("CALENDAR"), .text("COLLECTOR OFFLINE", .dim)])
    }

    test("calendar panel: old section gets the staleness marker; events still counted from now") {
        let w = FakeWorld("cal-stale")
        w.writeCalendar([w.event("Standup", inMin: 22)], age: 720, lastError: "AUTH")
        expectEqual(calendarLines(w.calendarPanel()), [
            .section("CALENDAR", marker: "·12m"),
            .field("NEXT", "14:52 Standup (in 22m)"),
        ])
        let fresh = FakeWorld("cal-fresh")
        fresh.writeCalendar([fresh.event("Standup", inMin: 22)], age: 599)
        expectEqual(fresh.calendarPanel().line("CALENDAR"), .section("CALENDAR"))
    }

    test("calendar panel: collector running but the agenda never fetched -> NO SIGNAL") {
        let w = FakeWorld("cal-nosignal")
        w.writeCalendar([], lastError: "AUTH", neverSucceeded: true)
        expectEqual(calendarLines(w.calendarPanel()), [.section("CALENDAR"), .field("NEXT", "NO SIGNAL", .dim)])
    }
}
