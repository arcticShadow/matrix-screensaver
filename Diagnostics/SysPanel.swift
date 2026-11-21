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
    /// Polled sections. nil = section not shown.
    var vitals: SectionData<HostVitals>? = nil
    var power: SectionData<PowerStatus>? = nil
    /// CLAUDE.USAGE block (see UsageBlock); empty = not shown.
    var usage: [PanelLine] = []
    /// CALENDAR block (see CalendarBlock); empty = not shown.
    var calendar: [PanelLine] = []
    /// Atmosphere lines (see Flavour).
    var flavour: [String] = []
    /// Per-source fetch stats; empty = debug lines hidden.
    var debug: [SourceStat] = []
}

/// A polled section's data as the panel sees it.
struct SectionData<T: Equatable>: Equatable {
    /// Latest good value; nil = none yet.
    var value: T?
    /// `·12s` when the data is stale, else nil.
    var staleMarker: String? = nil
    /// Shown instead of the value when there is none yet.
    var placeholder: String = "ACQUIRING"
}

struct SourceStat: Equatable {
    var id: SourceID
    var schedule: SourceSchedule
}

enum SysPanel {
    static func build(_ inp: SysInputs) -> Panel {
        let t = wallClock(inp.now, inp.timeZone)
        var lines: [PanelLine] = [
            .field("SYS.CLOCK", String(format: "%02d:%02d:%02d", t.hour, t.minute, t.second)),
            .field("SYS.DATE", String(format: "%04d-%02d-%02d %@", t.year, t.month, t.day,
                                      weekdays[t.weekday - 1])),
            .rule,
            .field("CONSTRUCT.UPTIME", formatUptime(inp.now.timeIntervalSince(inp.bootTime))),
            .field("SAVER.UPTIME", formatUptime(inp.now.timeIntervalSince(inp.saverStart))),
        ]
        if let v = inp.vitals {
            lines.append(.section("HOST.VITALS", marker: v.staleMarker))
            if let h = v.value {
                lines.append(.field("LOAD.AVG", h.load.prefix(3).map { String(format: "%.2f", $0) }
                                                  .joined(separator: " ")))
                lines.append(memoryLine(h.memoryPressure))
                lines.append(thermalLine(h.thermal))
            } else {
                lines.append(.text(v.placeholder, .dim))
            }
        }
        // No battery, or not read yet: no power section at all (desktops never
        // flash a placeholder).
        if let p = inp.power, case let .battery(pct, onAC, charging)? = p.value {
            lines.append(.section("POWER", marker: p.staleMarker))
            lines.append(powerLine(pct, onAC: onAC, charging: charging))
        }
        lines.append(contentsOf: inp.usage)
        lines.append(contentsOf: inp.calendar)
        if !inp.flavour.isEmpty {
            lines.append(.rule)
            lines.append(contentsOf: inp.flavour.enumerated().map {
                .text($0.element, $0.offset == 0 ? .dim : .ok)
            })
        }
        if !inp.debug.isEmpty {
            lines.append(.section("DEBUG"))
            lines.append(contentsOf: inp.debug.map(debugLine))
        }
        return Panel(title: "SYS", lines: lines)
    }

    private static func memoryLine(_ m: HostVitals.MemoryPressure) -> PanelLine {
        switch m {
        case .normal:   return .field("MEM.PRESSURE", "NOMINAL", .ok)
        case .warn:     return .field("MEM.PRESSURE", "ELEVATED", .warn)
        case .critical: return .field("MEM.PRESSURE", "CRITICAL", .alert)
        }
    }

    private static func thermalLine(_ t: HostVitals.Thermal) -> PanelLine {
        switch t {
        case .nominal:  return .field("THERMAL", "NOMINAL", .ok)
        case .fair:     return .field("THERMAL", "FAIR", .normal)
        case .serious:  return .field("THERMAL", "SERIOUS", .warn)
        case .critical: return .field("THERMAL", "CRITICAL", .alert)
        }
    }

    private static func powerLine(_ pct: Int, onAC: Bool, charging: Bool) -> PanelLine {
        if onAC { return .field("POWER.CELL", "\(pct)% \(charging ? "AC CHARGING" : "AC")", .ok) }
        let sev: Severity = pct <= 10 ? .alert : pct <= 20 ? .warn : .normal
        return .field("POWER.CELL", "\(pct)% BATTERY", sev)
    }

    /// `DBG.VIT  1.2ms @5s` (`F2` = two consecutive failures, backing off).
    private static func debugLine(_ s: SourceStat) -> PanelLine {
        let sch = s.schedule
        var v = "\(formatDuration(sch.lastDuration)) @\(formatInterval(sch.effectiveInterval))"
        if sch.consecutiveFailures > 0 { v += " F\(sch.consecutiveFailures)" }
        return .field("DBG." + s.id, v, sch.consecutiveFailures > 0 ? .warn : .dim)
    }

    static func formatDuration(_ d: TimeInterval) -> String {
        let ms = d * 1000
        if ms < 10 { return String(format: "%.1fms", ms) }
        if ms < 1000 { return String(format: "%.0fms", ms) }
        return String(format: "%.2fs", d)
    }

    /// 5s, 100s, 12m, 3h: whole units, for intervals and data ages.
    static func formatInterval(_ i: TimeInterval) -> String {
        let s = Int(i.rounded())
        if s < 120 { return "\(s)s" }
        if s < 7200 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }

    /// The dim staleness marker for data of this age: `·12s`.
    static func staleMarker(age: TimeInterval) -> String { "·" + formatInterval(age) }

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
