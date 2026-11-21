//
//  DiagnosticsCore.swift
//  The facade the renderer talks to. One instance per saver activation: it
//  loads config once at creation (each activation builds a fresh MatrixView,
//  so editing the config takes effect at the next activation) and builds the
//  panel models on demand, every frame, from the clock plus the latest
//  immutable poller snapshot.
//
//  Polling: `.shared(hub)` (the saver) leases the process-wide background
//  poller between startPolling() and stopPolling(); `.manual` (tests) owns a
//  PollEngine that only runs when pollNow() is called, on the caller's thread.
//

import Foundation

enum PollingMode {
    case manual
    case shared(PollerHub)
}

final class DiagnosticsCore {
    let env: DiagnosticsEnvironment
    let config: DiagConfig
    let configStatus: ConfigStatus
    /// Start of this saver activation (for SAVER.UPTIME).
    let saverStart: Date
    /// Show the per-source fetch-time debug lines.
    let showDebug: Bool
    /// Codename salt holder (salt from config or per-run random); see `namer`.
    private let baseNamer: DisplayNamer
    /// AGENTS panel height budget in lines; the renderer sets it from the
    /// screen height.
    var agentsMaxLines = 40
    /// Burn-in rotation of the panel corners (the saver sets its `Cfg` interval).
    var rotation = PanelRotation()

    private let mode: PollingMode
    private var manualEngine: PollEngine?
    private var lease: PollerLease?

    init(env: DiagnosticsEnvironment, polling: PollingMode = .shared(.shared), showDebug: Bool = false) {
        self.env = env
        let loaded = ConfigLoader.load(path: env.configPath)
        config = loaded.config
        configStatus = loaded.status
        saverStart = env.now()
        baseNamer = DisplayNamer(salt: loaded.config.codenameSalt)
        self.showDebug = showDebug
        mode = polling
        if case .manual = polling {
            manualEngine = PollEngine(sources: PollSources.standard(env), clock: env.now)
        }
    }

    deinit { lease?.release() }

    var overlayEnabled: Bool { config.overlay }

    // MARK: Polling lifecycle

    /// Lease the shared poller (idempotent). No-op when the overlay is off.
    func startPolling() {
        guard overlayEnabled, lease == nil, case let .shared(hub) = mode else { return }
        let env = self.env
        lease = hub.acquire { PollEngine(sources: PollSources.standard(env), clock: env.now) }
    }

    /// Release the shared poller (idempotent). The hub stops polling when the
    /// last lease goes.
    func stopPolling() {
        lease?.release()
        lease = nil
    }

    var isPolling: Bool { lease != nil }

    /// Manual mode: run every due source now, synchronously.
    func pollNow() { manualEngine?.tick() }

    private func snapshot() -> DiagSnapshot {
        switch mode {
        case .manual: return manualEngine?.snapshot ?? DiagSnapshot()
        case let .shared(hub): return lease == nil ? DiagSnapshot() : hub.snapshot()
        }
    }

    // MARK: Trusted network

    /// THE trusted-network decision, from the latest Wi-Fi reading. Anything
    /// that shows real names (repo names, calendar titles) must follow it.
    func networkTrust() -> NetworkTrust { networkTrust(snapshot(), env.now()) }

    /// Display names under the current trust decision.
    var namer: DisplayNamer { namer(networkTrust()) }

    private func namer(_ trust: NetworkTrust) -> DisplayNamer {
        var n = baseNamer
        n.trust = trust
        return n
    }

    /// Fail closed: a failing read or a reading older than 2x its refresh
    /// interval (poller stalled) no longer counts.
    private func networkTrust(_ snap: DiagSnapshot, _ now: Date) -> NetworkTrust {
        let sched = snap.schedules[SourceIDs.wifi]
        let current = sched.map { $0.consecutiveFailures == 0 && !$0.isStale(now: now) } ?? false
        return NetworkTrust.decide(trustedSSIDs: config.trustedSSIDs, wifi: snap.wifi?.value, current: current)
    }

    // MARK: Panels

    /// Panels to draw this frame, in display order. Empty when the overlay is off.
    func panels() -> [Panel] {
        guard overlayEnabled else { return [] }
        let now = env.now()
        let snap = snapshot()
        var inp = SysInputs(now: now, bootTime: env.bootTime,
                            saverStart: saverStart, timeZone: env.timeZone())
        inp.vitals = section(snap.vitals, SourceIDs.vitals, snap, now)
        inp.power = section(snap.power, SourceIDs.power, snap, now)
        inp.usage = UsageBlock.lines(snap.collector?.value, config: config, now: now)
        inp.flavour = Flavour.lines(now: now)
        if showDebug {
            inp.debug = PollSources.order.compactMap { id in
                snap.schedules[id].map { SourceStat(id: id, schedule: $0) }
            }
        }
        return [SysPanel.build(inp), agentsPanel(snap, now)]
    }

    /// Panels with their screen placement (the one place corners are decided).
    /// `agentsLineCapacity` gives the AGENTS line budget for a corner (the
    /// renderer knows the screen and the logo); it is asked for the corner
    /// AGENTS occupies right now, so the roster cap follows the rotation.
    func layout(agentsLineCapacity: ((PanelCorner) -> Int)? = nil) -> [PlacedPanel] {
        let now = env.now()
        if let cap = agentsLineCapacity { agentsMaxLines = cap(rotation.agentsCorner(at: now)) }
        return PanelLayout.place(panels(), now: now, rotation: rotation)
    }

    private func agentsPanel(_ snap: DiagSnapshot, _ now: Date) -> Panel {
        let sec = section(snap.sessions, SourceIDs.sessions, snap, now)
        let failing = (snap.schedules[SourceIDs.sessions]?.consecutiveFailures ?? 0) > 0
        return AgentsPanel.build(AgentsInputs(now: now, scan: sec.value, signalLost: failing,
                                              staleMarker: sec.staleMarker,
                                              namer: namer(networkTrust(snap, now)),
                                              profileTags: config.profileTags,
                                              excludedSessionIDs: snap.collector?.value.state?.hiddenSessionIDs ?? [],
                                              maxLines: agentsMaxLines))
    }

    private func section<T>(_ sample: Sample<T>?, _ id: SourceID,
                            _ snap: DiagSnapshot, _ now: Date) -> SectionData<T> {
        let sched = snap.schedules[id]
        var d = SectionData<T>(value: sample?.value)
        if let s = sched, s.isStale(now: now), let age = s.dataAge(now: now) {
            d.staleMarker = SysPanel.staleMarker(age: age)
        }
        if sample == nil, (sched?.consecutiveFailures ?? 0) > 0 { d.placeholder = "NO SIGNAL" }
        return d
    }
}
