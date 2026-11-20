//
//  DiagnosticsCore.swift
//  The facade the renderer talks to. One instance per saver activation: it
//  loads config once at creation (each activation builds a fresh MatrixView,
//  so editing the config takes effect at the next activation) and builds the
//  panel models on demand, every frame.
//
//  Later tickets: a shared background poller feeds immutable snapshots in;
//  panels() stays a cheap, pure read of the latest snapshot plus the clock.
//

import Foundation

final class DiagnosticsCore {
    let env: DiagnosticsEnvironment
    let config: DiagConfig
    let configStatus: ConfigStatus
    /// Start of this saver activation (for SAVER.UPTIME).
    let saverStart: Date

    init(env: DiagnosticsEnvironment) {
        self.env = env
        let loaded = ConfigLoader.load(path: env.configPath)
        config = loaded.config
        configStatus = loaded.status
        saverStart = env.now()
    }

    var overlayEnabled: Bool { config.overlay }

    /// Panels to draw this frame, in display order. Empty when the overlay is off.
    func panels() -> [Panel] {
        guard overlayEnabled else { return [] }
        return [SysPanel.build(SysInputs(now: env.now(), bootTime: env.bootTime,
                                         saverStart: saverStart, timeZone: env.timeZone()))]
    }
}
