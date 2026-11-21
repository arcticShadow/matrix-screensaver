//
//  UsageBlock.swift
//  The saver's side of the collector: reading its state file (on the poller,
//  every 5 s) and turning the usage section into the SYS panel's
//  CLAUDE.USAGE lines. Pure apart from `CollectorReader.read`.
//
//    CLAUDE.USAGE ─────────────── ·12m     (marker when the section is old)
//    WRK.STATE  STALE                       (expired token / old account data)
//    WRK.5H     ▓▓▓░░░░░░░  37% 2h14m       (amber >= 75%, red >= 90%)
//    WRK.7D     ▓░░░░░░░░░  12% 4d03h
//    WRK.XTRA   12.40 / 50 USD              (only when extra usage is enabled)
//
//  Accounts are labelled by profile tag only; folder names never reach the
//  panel. No token and no sessions -> hidden.
//

import Foundation

/// One read of the collector state file, plus which of its accounts have
/// session files (an account with no token is only shown if it has sessions).
struct CollectorReading: Equatable {
    /// nil = no state file (collector not installed or not run yet).
    var state: CollectorState?
    /// Config dir basenames with at least one `sessions/*.json`.
    var dirsWithSessions: Set<String> = []
}

enum CollectorReader {
    /// Throws when the file exists but can't be decoded (keeps the last good read).
    static func read(home: String) throws -> CollectorReading {
        let state = try CollectorStateStore.load(path: CollectorStateStore.defaultPath(home: home))
        var withSessions: Set<String> = []
        let fm = FileManager.default
        for a in state?.usage?.accounts ?? [] where a.token == .none {
            let dir = (home as NSString).appendingPathComponent(a.dir + "/sessions")
            if let names = try? fm.contentsOfDirectory(atPath: dir),
               names.contains(where: { $0.hasSuffix(".json") && !$0.hasPrefix(".") }) {
                withSessions.insert(a.dir)
            }
        }
        return CollectorReading(state: state, dirsWithSessions: withSessions)
    }
}

enum UsageBlock {
    static let title = "CLAUDE.USAGE"
    static let warnAt = 75
    static let alertAt = 90
    static let meterCells = 10
    /// Used when the state file carries no usage schedule.
    static let defaultRefresh: TimeInterval = 300

    /// `reading` nil = not read yet (or never readable).
    static func lines(_ reading: CollectorReading?, config: DiagConfig, now: Date) -> [PanelLine] {
        guard let state = reading?.state, let usage = state.usage else {
            return [.section(title), .text("COLLECTOR OFFLINE", .dim)]
        }
        let refresh = state.schedules[CollectorSourceIDs.usage]?.refreshInterval ?? defaultRefresh
        let staleAfter = SourceSchedule.staleFactor * refresh
        func isOld(_ d: Date?) -> Bool { d.map { now.timeIntervalSince($0) > staleAfter } ?? true }

        var marker: String? = nil
        if let g = usage.generatedAt, isOld(g) {
            marker = SysPanel.staleMarker(age: now.timeIntervalSince(g))
        }
        var out: [PanelLine] = [.section(title, marker: marker)]
        let shown = usage.accounts.filter {
            $0.token != .none || (reading?.dirsWithSessions.contains($0.dir) ?? false)
        }
        if shown.isEmpty { out.append(.text("NO ACCOUNTS", .dim)) }
        for a in shown {
            let tag = ProfileTag.tag(forDir: a.dir, config: config)
            if a.token == .none {
                out.append(.field("\(tag).TOKEN", "NO TOKEN", .dim))
                continue
            }
            let stale = a.token != .ok || isOld(a.generatedAt)
            if stale { out.append(.field("\(tag).STATE", "STALE", .warn)) }
            guard a.fiveHour != nil || a.sevenDay != nil else {
                out.append(.field("\(tag).USAGE", "NO SIGNAL", .dim))
                continue
            }
            if let w = a.fiveHour { out.append(meterLine("\(tag).5H", w, stale: stale, now: now)) }
            if let w = a.sevenDay { out.append(meterLine("\(tag).7D", w, stale: stale, now: now)) }
            if let x = a.extra, x.enabled { out.append(.field("\(tag).XTRA", xtra(x), stale ? .dim : .normal)) }
        }
        return out
    }

    static func meterLine(_ label: String, _ w: UsageWindow, stale: Bool, now: Date) -> PanelLine {
        let pct = Int(max(0, min(100, w.utilization)).rounded())
        var v = meter(pct) + " " + String(format: "%3d%%", pct)
        if let r = w.resetsAt { v += " " + countdown(r.timeIntervalSince(now)) }
        return .field(label, v, stale ? .dim : severity(pct))
    }

    static func severity(_ pct: Int) -> Severity {
        pct >= alertAt ? .alert : pct >= warnAt ? .warn : .normal
    }

    /// 10 cells, one per 10% (rounded down), but any usage shows one cell.
    static func meter(_ pct: Int) -> String {
        let filled = pct <= 0 ? 0 : min(meterCells, max(1, pct / 10))
        return String(repeating: "▓", count: filled) + String(repeating: "░", count: meterCells - filled)
    }

    /// Time to reset, rounded up to the minute: `4d03h`, `2h14m`, `9m`.
    static func countdown(_ interval: TimeInterval) -> String {
        let mins = max(0, Int((interval / 60).rounded(.up)))
        let d = mins / 1440, h = (mins % 1440) / 60, m = mins % 60
        if d > 0 { return String(format: "%dd%02dh", d, h) }
        if h > 0 { return String(format: "%dh%02dm", h, m) }
        return "\(m)m"
    }

    /// `12.40 / 50 USD`, or `12.40 NZD` with no monthly limit. Amounts are in
    /// minor units; the currency code comes from the response.
    static func xtra(_ x: ExtraUsage) -> String {
        let scale = pow(10, Double(max(0, x.decimalPlaces)))
        func money(_ minor: Double, trimWhole: Bool) -> String {
            let v = minor / scale
            if trimWhole, v == v.rounded() { return String(format: "%.0f", v) }
            return String(format: "%.\(max(0, x.decimalPlaces))f", v)
        }
        let used = money(x.usedMinor ?? 0, trimWhole: false)
        if let limit = x.limitMinor { return "\(used) / \(money(limit, trimWhole: true)) \(x.currency)" }
        return "\(used) \(x.currency)"
    }
}
