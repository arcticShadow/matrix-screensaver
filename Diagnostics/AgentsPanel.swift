//
//  AgentsPanel.swift
//  Classification of scanned sessions and the AGENTS panel model. Pure: the
//  core passes the latest SessionScan plus the clock, config and namer.
//
//  Extension points (see the #4 notes): `ClassifiedSession.waitingSince` for
//  the banner/pulse ticket, `AgentsInputs.excludedSessionIDs` for collector
//  refresh sessions. BACKGROUND totals come from `SessionRecord.background`
//  (see BackgroundAgents.swift).
//

import Foundation

enum AgentsCfg {
    /// Idle for less than this → AWAITING (amber), else DORMANT (dim).
    static let awaitingWindow: TimeInterval = 15 * 60
    /// Session kinds that never count (system workers).
    static let excludedKinds: Set<String> = ["daemon", "daemon-worker"]
}

enum AgentState: Equatable {
    case attention(WaitCategory)
    case active
    case awaiting
    case dormant
    /// Process dead or pid reused: dimmed, never counted live.
    case ghost

    var sortRank: Int {
        switch self {
        case .attention: return 0
        case .active: return 1
        case .awaiting: return 2
        case .dormant: return 3
        case .ghost: return 4
        }
    }
}

struct ClassifiedSession: Equatable {
    var record: SessionRecord
    var state: AgentState
    /// When the session started waiting on the operator (ATTENTION only).
    var waitingSince: Date?
}

enum AgentClassifier {
    /// Excluded kinds and excluded session ids are dropped entirely.
    static func classify(_ scan: SessionScan, now: Date,
                         excludedSessionIDs: Set<String> = []) -> [ClassifiedSession] {
        scan.sessions.compactMap { r in
            guard !AgentsCfg.excludedKinds.contains(r.kind),
                  !excludedSessionIDs.contains(r.sessionId) else { return nil }
            return ClassifiedSession(record: r, state: state(r, now: now),
                                     waitingSince: r.status == "waiting" && r.alive ? r.statusSince : nil)
        }
    }

    static func state(_ r: SessionRecord, now: Date) -> AgentState {
        guard r.alive else { return .ghost }
        switch r.status {
        case "waiting": return .attention(r.waitCategory ?? .attention)
        case "idle":
            guard let since = r.statusSince else { return .dormant }
            return now.timeIntervalSince(since) < AgentsCfg.awaitingWindow ? .awaiting : .dormant
        // busy, shell, and any status a newer Claude Code adds: a live process
        // doing something.
        default: return .active
        }
    }
}

struct AgentsInputs {
    var now: Date
    /// Latest scan; nil = not read yet.
    var scan: SessionScan?
    /// The last read failed (format change, unreadable dir): SIGNAL LOST.
    var signalLost = false
    var staleMarker: String? = nil
    var namer: DisplayNamer
    var profileTags: [String: String] = [:]
    /// Sessions never shown or counted (e.g. the collector's own refresh runs).
    var excludedSessionIDs: Set<String> = []
    /// Panel height budget in lines (excluding the title bar).
    var maxLines: Int = 40
}

enum AgentsPanel {
    static func build(_ inp: AgentsInputs) -> Panel {
        if inp.signalLost {
            return Panel(title: "AGENTS", lines: [
                .field("AGENT.LINK", "SIGNAL LOST", .alert),
                .text("SESSION FEED UNREADABLE", .dim),
            ])
        }
        guard let scan = inp.scan else {
            return Panel(title: "AGENTS", lines: [.field("AGENT.LINK", "ACQUIRING", .dim)])
        }
        let all = AgentClassifier.classify(scan, now: inp.now, excludedSessionIDs: inp.excludedSessionIDs)
        let live = all.filter { $0.state != .ghost }
        func count(_ f: (AgentState) -> Bool) -> Int { live.filter { f($0.state) }.count }
        let attention = count { if case .attention = $0 { return true }; return false }
        let active = count { $0 == .active }
        let awaiting = count { $0 == .awaiting }
        let dormant = count { $0 == .dormant }
        let background = live.reduce(scan.unattributedBackground) { $0 + $1.record.background }

        var lines: [PanelLine] = [
            .field("AGENT.LINK", "ONLINE", .ok),
            .field("RUNNING", "\(live.count)"),
            .field("ACTIVE", "\(active)", active > 0 ? .ok : .dim),
            PanelLine(style: .field, label: "ATTENTION", value: "\(attention)",
                      severity: attention > 0 ? .alert : .dim, pulse: attention > 0),
            .field("AWAITING", "\(awaiting)", awaiting > 0 ? .warn : .dim),
            .field("DORMANT", "\(dormant)", .dim),
            .field("BACKGROUND", "\(background)", background > 0 ? .ok : .dim),
            .section("ROSTER", marker: inp.staleMarker),
        ]

        // Individually listed: attention (longest waiting first), active
        // (longest running first), awaiting (most recently idle first).
        let listed = live.filter { $0.state != .dormant }.sorted(by: rosterOrder)
        var tail: [PanelLine] = []
        if dormant > 0 {
            let repos = Set(live.filter { $0.state == .dormant }.map(\.record.cwd)).count
            tail.append(.text("○ \(dormant) DORMANT across \(repos) \(repos == 1 ? "repo" : "repos")", .dim))
        }
        let ghosts = all.count - live.count
        if ghosts > 0 { tail.append(.text("✕ \(ghosts) GHOST", .dim)) }
        if listed.isEmpty, tail.isEmpty { tail.append(.text("NO LIVE SESSIONS", .dim)) }

        let room = max(0, inp.maxLines - lines.count - tail.count)
        var rows = listed.map { row($0, inp) }
        if rows.count > room {
            let keep = max(0, room - 1)
            let more = rows.count - keep
            rows = Array(rows.prefix(keep)) + [.text("+\(more) more", .dim)]
        }
        lines += rows + tail
        return Panel(title: "AGENTS", lines: lines, pulse: attention > 0)
    }

    private static func rosterOrder(_ a: ClassifiedSession, _ b: ClassifiedSession) -> Bool {
        if a.state.sortRank != b.state.sortRank { return a.state.sortRank < b.state.sortRank }
        let ta = a.record.statusSince ?? .distantPast, tb = b.record.statusSince ?? .distantPast
        if ta != tb { return a.state == .awaiting ? ta > tb : ta < tb }
        return a.record.pid < b.record.pid
    }

    /// `IRON-MATRIX WRK CLI ······ APPROVE BASH 2m`
    private static func row(_ s: ClassifiedSession, _ inp: AgentsInputs) -> PanelLine {
        let r = s.record
        let label = [inp.namer.name(for: r),
                     ProfileTags.tag(configDir: r.configDir, overrides: inp.profileTags),
                     r.entrypoint == "claude-desktop" ? "DSK" : "CLI"].joined(separator: " ")
        let age = (r.statusSince.map { formatAge(inp.now.timeIntervalSince($0)) } ?? "?")
            + (r.background > 0 ? " +\(min(r.background, maxBackgroundShown)) BG" : "")
        switch s.state {
        case let .attention(cat): return .field(label, "\(cat.label) \(age)", .alert)
        case .active:             return .field(label, "ACTIVE \(age)", .ok)
        case .awaiting:           return .field(label, "idle \(age)", .warn)
        case .dormant, .ghost:    return .field(label, "idle \(age)", .dim)
        }
    }

    /// Per-row `+N BG` suffix cap (keeps the row width bounded).
    static let maxBackgroundShown = 99

    /// 45s, 12m, 3h, 2d.
    static func formatAge(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
