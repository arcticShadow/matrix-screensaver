//
//  Layout.swift
//  Where each panel goes on screen, decided in ONE place (the core), so the
//  renderer only draws what it is given. Today: SYS top-left, AGENTS
//  bottom-right (diagonally opposite, clear of the centre logo). The
//  burn-in rotation ticket makes `place` depend on `now`.
//

import Foundation

/// Screen corner a panel is anchored to.
enum PanelCorner: Equatable { case topLeft, topRight, bottomRight, bottomLeft }

struct PlacedPanel: Equatable {
    var panel: Panel
    var corner: PanelCorner
    /// Panel width in monospace cells (the AGENTS roster needs more room).
    var columns: Int
}

enum PanelLayout {
    static let sysColumns = 34
    static let agentsColumns = 52   // widest row: 13-char codename + tags + `APPROVE <10-char tool> 59m +99 BG`

    static func place(_ panels: [Panel], now: Date) -> [PlacedPanel] {
        panels.map { p in
            switch p.title {
            case "AGENTS": return PlacedPanel(panel: p, corner: .bottomRight, columns: agentsColumns)
            default:       return PlacedPanel(panel: p, corner: .topLeft, columns: sysColumns)
            }
        }
    }
}
