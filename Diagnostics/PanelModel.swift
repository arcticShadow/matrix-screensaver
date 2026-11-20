//
//  PanelModel.swift
//  The panel model: plain value types the diagnostics core produces and
//  MatrixView merely draws. Tests assert on these, never on drawing.
//
//  A Panel is a titled box of lines. Each line has a style (how it is laid
//  out), a label and value (text), and a severity (which palette colour the
//  renderer uses). The renderer owns all colours, fonts and geometry.
//

import Foundation

enum Severity: Equatable {
    /// base1 text, cyan values: the default.
    case normal
    /// green: healthy / good.
    case ok
    /// amber (yellow): needs a look.
    case warn
    /// red: needs the operator.
    case alert
    /// base01: background detail, stale data.
    case dim
}

enum LineStyle: Equatable {
    /// `LABEL ........ value` row.
    case field
    /// Section heading inside the panel (e.g. `── SYS.TIME ──`).
    case section
    /// Horizontal rule.
    case rule
    /// Free text spanning the row (label only; value ignored).
    case text
}

struct PanelLine: Equatable {
    var style: LineStyle
    var label: String
    var value: String
    var severity: Severity

    static func field(_ label: String, _ value: String, _ severity: Severity = .normal) -> PanelLine {
        PanelLine(style: .field, label: label, value: value, severity: severity)
    }
    static func section(_ label: String) -> PanelLine {
        PanelLine(style: .section, label: label, value: "", severity: .normal)
    }
    static let rule = PanelLine(style: .rule, label: "", value: "", severity: .normal)
    static func text(_ label: String, _ severity: Severity = .normal) -> PanelLine {
        PanelLine(style: .text, label: label, value: "", severity: severity)
    }
}

struct Panel: Equatable {
    /// Short id shown in the title bar, e.g. "SYS", "AGENTS".
    var title: String
    var lines: [PanelLine]

    /// The value of the first `.field` line with this label, if any.
    func value(of label: String) -> String? {
        lines.first { $0.style == .field && $0.label == label }?.value
    }

    /// The first line (any style) with this label.
    func line(_ label: String) -> PanelLine? {
        lines.first { $0.label == label }
    }
}
