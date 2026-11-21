//
//  Layout.swift
//  Where each panel goes on screen, decided in ONE place (the core), so the
//  renderer only draws what it is given. SYS and AGENTS sit in diagonally
//  opposite corners and rotate clockwise together, one corner per
//  `PanelRotation.interval`, for OLED/XDR burn-in protection.
//

import Foundation

/// Screen corner a panel is anchored to.
enum PanelCorner: Equatable, CaseIterable {
    case topLeft, topRight, bottomRight, bottomLeft

    /// `steps` corners clockwise from this one (negative = anticlockwise).
    func clockwise(_ steps: Int = 1) -> PanelCorner {
        let all = PanelCorner.allCases   // declared in clockwise order
        let i = all.firstIndex(of: self)!
        return all[((i + steps) % 4 + 4) % 4]
    }

    /// The diagonally opposite corner.
    var opposite: PanelCorner { clockwise(2) }

    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
}

/// Clockwise burn-in rotation. Anchored to the wall clock (not the saver
/// start), so short activations don't always park the panels in the same
/// corners: at any `now`, the step is `floor(now / interval) mod 4` and step 0
/// is SYS top-left, AGENTS bottom-right.
struct PanelRotation: Equatable {
    /// Default seconds per corner (~10 min). The saver passes its `Cfg` value.
    static let defaultInterval: TimeInterval = 600

    var interval: TimeInterval = PanelRotation.defaultInterval

    /// Rotation step 0...3 at `now`.
    func step(at now: Date) -> Int {
        guard interval > 0 else { return 0 }
        let n = Int(floor(now.timeIntervalSince1970 / interval))
        return ((n % 4) + 4) % 4
    }

    func sysCorner(at now: Date) -> PanelCorner { PanelCorner.topLeft.clockwise(step(at: now)) }
    func agentsCorner(at now: Date) -> PanelCorner { sysCorner(at: now).opposite }
}

struct PlacedPanel: Equatable {
    var panel: Panel
    var corner: PanelCorner
    /// Panel width in monospace cells (the AGENTS roster needs more room).
    var columns: Int
}

enum PanelLayout {
    static let sysColumns = 34
    static let agentsColumns = 52   // widest row: 13-char codename + tags + `APPROVE <10-char tool> 59m +99 BG`

    static func place(_ panels: [Panel], now: Date,
                      rotation: PanelRotation = PanelRotation()) -> [PlacedPanel] {
        panels.map { p in
            switch p.title {
            case "AGENTS": return PlacedPanel(panel: p, corner: rotation.agentsCorner(at: now), columns: agentsColumns)
            default:       return PlacedPanel(panel: p, corner: rotation.sysCorner(at: now), columns: sysColumns)
            }
        }
    }
}
