//
//  Alerts.swift
//  Attention alerts: which waiting sessions may fire the centre takeover
//  banner, and when it shows. The decision lives here (UI-free, clock-driven,
//  tested); MatrixView only animates what `DiagnosticsCore.banner()` returns
//  (banner box, red rain glitch). The AGENTS panel's pulse marks are set in
//  AgentsPanel.build.
//

import Foundation

enum AlertsCfg {
    /// A session must have waited this long before it can fire the banner, so
    /// prompts answered quickly never take over the screen.
    static let waitThreshold: TimeInterval = 30
    /// One banner every period while anything is eligible...
    static let bannerPeriod: TimeInterval = 60
    /// ...shown for this long.
    static let bannerDuration: TimeInterval = 4
}

/// What the renderer draws in the centre. Only the display name and the
/// waiting category: never command text, titles or paths.
struct AlertBanner: Equatable {
    var name: String
    var category: WaitCategory
    /// Seconds since this banner appeared (drives the glitch envelope).
    var elapsed: TimeInterval
    var duration: TimeInterval

    var text: String { "⚠ OPERATOR REQUIRED — \(name) — \(category.label)" }
}

/// A waiting session old enough for the banner, oldest first.
struct BannerCandidate: Equatable {
    var sessionId: String
    var pid: Int32
    var name: String
    var category: WaitCategory
    var waitingSince: Date

    /// Oldest-first order (pid breaks ties so the order is total).
    func precedes(_ o: BannerCandidate) -> Bool {
        waitingSince != o.waitingSince ? waitingSince < o.waitingSince : pid < o.pid
    }
}

enum AttentionAlerts {
    /// Live sessions in ATTENTION that have waited at least `threshold`, oldest first.
    static func candidates(_ inp: AgentsInputs, threshold: TimeInterval = AlertsCfg.waitThreshold)
        -> [BannerCandidate] {
        guard !inp.signalLost, let scan = inp.scan else { return [] }
        return AgentClassifier.classify(scan, now: inp.now, excludedSessionIDs: inp.excludedSessionIDs)
            .compactMap { s -> BannerCandidate? in
                guard case let .attention(cat) = s.state, let since = s.waitingSince,
                      inp.now.timeIntervalSince(since) >= threshold else { return nil }
                return BannerCandidate(sessionId: s.record.sessionId, pid: s.record.pid,
                                       name: inp.namer.name(for: s.record), category: cat,
                                       waitingSince: since)
            }
            .sorted { $0.precedes($1) }
    }
}

/// The banner clock. A cycle starts the moment something becomes eligible
/// (no waiting for a wall-clock boundary), then every `period`; each cycle
/// shows the next candidate after the previous one in oldest-first order,
/// wrapping. Nothing eligible resets it, so the next waiting session fires at
/// once. Asked once per frame.
struct BannerScheduler {
    var period: TimeInterval = AlertsCfg.bannerPeriod
    var duration: TimeInterval = AlertsCfg.bannerDuration

    private var cycleStart: Date?
    private var current: BannerCandidate?

    mutating func update(now: Date, candidates: [BannerCandidate]) -> AlertBanner? {
        guard !candidates.isEmpty else { cycleStart = nil; current = nil; return nil }
        if let start = cycleStart, now < start { cycleStart = nil }   // clock went backwards
        if cycleStart == nil || now >= cycleStart! + period {
            if let start = cycleStart {
                // Keep the cadence (no drift); skip whole periods missed while asleep.
                cycleStart = start + period * floor(now.timeIntervalSince(start) / period)
            } else {
                cycleStart = now
            }
            let prev = current
            current = prev.flatMap { p in candidates.first { p.precedes($0) } } ?? candidates[0]
        }
        guard let start = cycleStart, let shown = current else { return nil }
        let elapsed = now.timeIntervalSince(start)
        // Hide as soon as the shown session is answered (or ends) mid-banner.
        guard elapsed < duration, let live = candidates.first(where: { $0.sessionId == shown.sessionId })
        else { return nil }
        return AlertBanner(name: live.name, category: live.category, elapsed: elapsed, duration: duration)
    }
}
