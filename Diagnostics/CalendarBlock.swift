//
//  CalendarBlock.swift
//  The SYS panel's CALENDAR lines, from the collector state file's calendar
//  section (#11). Pure: the reading, trust decision, clock and time zone
//  come in; lines come out.
//
//    CALENDAR ─────────────────── ·12m     (marker when the section is old)
//    NEXT  14:30 Standup (in 22m)          (amber within 5 min)
//    NOW   ▸ Design review                 (while an event is in progress)
//
//  All-day events are never shown. Titles appear only on a trusted network,
//  otherwise `EVENT` (same rule as repo names).
//

import Foundation

enum CalendarBlock {
    static let title = "CALENDAR"
    static let redacted = "EVENT"
    /// Titles longer than this are cut, with an ellipsis.
    static let maxTitle = 24
    /// NEXT turns amber this close to the start.
    static let soonWithin: TimeInterval = 5 * 60
    /// Used when the state file carries no calendar schedule.
    static let defaultRefresh: TimeInterval = 300

    static func lines(_ reading: CollectorReading?, trusted: Bool, now: Date, timeZone: TimeZone) -> [PanelLine] {
        guard let state = reading?.state, let cal = state.calendar else {
            return [.section(title), .text("COLLECTOR OFFLINE", .dim)]
        }
        guard let fetched = cal.generatedAt else {
            return [.section(title), .field("NEXT", "NO SIGNAL", .dim)]
        }
        let refresh = state.schedules[CollectorSourceIDs.calendar]?.refreshInterval ?? defaultRefresh
        let age = now.timeIntervalSince(fetched)
        let marker = age > SourceSchedule.staleFactor * refresh ? SysPanel.staleMarker(age: age) : nil
        let head = PanelLine.section(title, marker: marker)

        let timed = cal.events.filter { !$0.allDay && $0.end > now }
        func name(_ e: CalendarEvent) -> String { trusted ? truncate(e.summary) : redacted }
        // In progress: the most recently started one.
        if let cur = timed.filter({ $0.start <= now }).max(by: { $0.start < $1.start }) {
            return [head, .field("NOW", "▸ " + name(cur), .ok)]
        }
        guard let next = timed.min(by: { $0.start < $1.start }) else {
            return [head, .field("NEXT", "NONE", .dim)]
        }
        let until = next.start.timeIntervalSince(now)
        let value = "\(clock(next.start, timeZone)) \(name(next)) (in \(UsageBlock.countdown(until)))"
        return [head, .field("NEXT", value, until <= soonWithin ? .warn : .normal)]
    }

    static func truncate(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxTitle else { return t }
        return String(t.prefix(maxTitle - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// `14:30` in the given zone.
    static func clock(_ d: Date, _ tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
