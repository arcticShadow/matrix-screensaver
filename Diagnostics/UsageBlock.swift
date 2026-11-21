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

/// The CLAUDE.USAGE block, kept in per-account pieces so the SYS panel can
/// fold accounts into `+N ACCOUNTS` when it runs out of lines.
struct UsageContent: Equatable {
    /// Section heading (plus COLLECTOR OFFLINE / NO ACCOUNTS); empty = not shown.
    var head: [PanelLine] = []
    var accounts: [UsageAccountLines] = []

    var lines: [PanelLine] { head + accounts.flatMap(\.lines) }
}

struct UsageAccountLines: Equatable {
    var lines: [PanelLine]
    /// `.alert` / `.warn` when one of its meters is red / amber, else nil.
    /// Such accounts are the last to be folded away.
    var attention: Severity? = nil
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
        content(reading, config: config, now: now).lines
    }

    static func content(_ reading: CollectorReading?, config: DiagConfig, now: Date) -> UsageContent {
        guard let state = reading?.state, let usage = state.usage else {
            return UsageContent(head: [.section(title), .text("COLLECTOR OFFLINE", .dim)])
        }
        let refresh = state.schedules[CollectorSourceIDs.usage]?.refreshInterval ?? defaultRefresh
        let staleAfter = SourceSchedule.staleFactor * refresh
        func isOld(_ d: Date?) -> Bool { d.map { now.timeIntervalSince($0) > staleAfter } ?? true }

        var marker: String? = nil
        if let g = usage.generatedAt, isOld(g) {
            marker = SysPanel.staleMarker(age: now.timeIntervalSince(g))
        }
        var out = UsageContent(head: [.section(title, marker: marker)])
        let shown = usage.accounts.filter {
            $0.token != .none || (reading?.dirsWithSessions.contains($0.dir) ?? false)
        }
        if shown.isEmpty { out.head.append(.text("NO ACCOUNTS", .dim)) }
        for a in shown {
            out.accounts.append(accountLines(a, config: config, now: now, isOld: isOld))
        }
        return out
    }

    private static func accountLines(_ a: AccountUsage, config: DiagConfig, now: Date,
                                     isOld: (Date?) -> Bool) -> UsageAccountLines {
        let tag = ProfileTags.tag(configDir: a.dir, overrides: config.profileTags)
        if a.token == .none { return UsageAccountLines(lines: [.field("\(tag).TOKEN", "NO TOKEN", .dim)]) }
        var out: [PanelLine] = []
        let stale = a.token != .ok || isOld(a.generatedAt)
        if stale { out.append(.field("\(tag).STATE", "STALE", .warn)) }
        guard a.fiveHour != nil || a.sevenDay != nil else {
            return UsageAccountLines(lines: out + [.field("\(tag).USAGE", "NO SIGNAL", .dim)])
        }
        let meters = [("5H", a.fiveHour), ("7D", a.sevenDay)].compactMap { label, w in
            w.map { meterLine("\(tag).\(label)", $0, stale: stale, now: now) }
        }
        out += meters
        if let x = a.extra, x.enabled { out.append(.field("\(tag).XTRA", xtra(x), stale ? .dim : .normal)) }
        let levels = Set(meters.map(\.severity))
        let attention: Severity? = levels.contains(.alert) ? .alert : levels.contains(.warn) ? .warn : nil
        return UsageAccountLines(lines: out, attention: attention)
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
