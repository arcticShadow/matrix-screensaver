//
//  SysPanel.swift
//  Builds the SYS panel model (clock, date, uptimes). Pure: every input is
//  injected via SysInputs, so it is called every frame by the renderer and
//  directly by tests.
//

import Foundation

struct SysInputs: Equatable {
    var now: Date
    /// When the machine booted (kern.boottime in the live environment).
    var bootTime: Date
    /// When this saver activation started.
    var saverStart: Date
    var timeZone: TimeZone
}

enum SysPanel {
    static func build(_ inp: SysInputs) -> Panel {
        let t = wallClock(inp.now, inp.timeZone)
        return Panel(title: "SYS", lines: [
            .field("SYS.CLOCK", String(format: "%02d:%02d:%02d", t.hour, t.minute, t.second)),
            .field("SYS.DATE", String(format: "%04d-%02d-%02d %@", t.year, t.month, t.day,
                                      weekdays[t.weekday - 1])),
            .rule,
            .field("CONSTRUCT.UPTIME", formatUptime(inp.now.timeIntervalSince(inp.bootTime))),
            .field("SAVER.UPTIME", formatUptime(inp.now.timeIntervalSince(inp.saverStart))),
        ])
    }

    /// Under a day: `hh:mm:ss`. A day or more: `Nd hh:mm` (seconds dropped).
    /// Negative intervals (clock skew) clamp to zero.
    static func formatUptime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let d = total / 86400, h = (total % 86400) / 3600
        let m = (total % 3600) / 60, s = total % 60
        return d > 0 ? String(format: "%dd %02d:%02d", d, h, m)
                     : String(format: "%02d:%02d:%02d", h, m, s)
    }

    // Fixed English abbreviations: the console look shouldn't vary by locale.
    private static let weekdays = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]

    private struct WallClock { var year, month, day, weekday, hour, minute, second: Int }

    private static func wallClock(_ date: Date, _ tz: TimeZone) -> WallClock {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
        return WallClock(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0,
                         weekday: c.weekday ?? 1, hour: c.hour ?? 0,
                         minute: c.minute ?? 0, second: c.second ?? 0)
    }
}
