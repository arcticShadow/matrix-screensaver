//
//  PanelRenderer.swift
//  Solarized Matrix — draws diagnostics panel models (Diagnostics/PanelModel)
//  as Matrix-console boxes. AppKit side only: all content decisions live in
//  the core; this file owns palette, font, geometry and the attribute caches.
//
//  Drawn into the SCREEN context after the rain buffer is blitted, never into
//  the fading buffer, so panel text stays crisp and never smears into trails.
//

import AppKit

final class PanelRenderer {

    struct Style {
        var fontSize: CGFloat
        /// Inner padding in character cells (horizontal) / rows (vertical, fractional).
        var padCols: CGFloat = 1.5
        var padRows: CGFloat = 0.6
        var lineSpacing: CGFloat = 1.35   // row height as a multiple of fontSize
        var backgroundAlpha: CGFloat = 0.86
    }

    // Solarized palette (see README).
    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    private let base03 = hex(0x002b36)
    private let base02 = hex(0x073642)
    private let base01 = hex(0x586e75)
    private let base1  = hex(0x93a1a1)
    private let cyan   = hex(0x2aa198)
    private let green  = hex(0x859900)
    private let yellow = hex(0xb58900)
    private let red    = hex(0xdc322f)

    let style: Style
    private let font: NSFont
    private let boldFont: NSFont
    private let cellW: CGFloat
    private var rowH: CGFloat { style.fontSize * style.lineSpacing }

    // Attribute dictionaries are built once (allocation-light per frame, same
    // reasoning as MatrixView's cached glyph attrs).
    private let labelAttrs: [NSAttributedString.Key: Any]
    private let dotAttrs: [NSAttributedString.Key: Any]
    private let titleAttrs: [NSAttributedString.Key: Any]
    private let sectionAttrs: [NSAttributedString.Key: Any]
    private let valueAttrs: [Severity: [NSAttributedString.Key: Any]]

    init(style: Style) {
        self.style = style
        font = NSFont(name: "SF Mono", size: style.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: style.fontSize, weight: .regular)
        boldFont = NSFont(name: "SF Mono Bold", size: style.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: style.fontSize, weight: .bold)
        cellW = ("M" as NSString).size(withAttributes: [.font: font]).width
        labelAttrs   = [.font: font, .foregroundColor: base1]
        dotAttrs     = [.font: font, .foregroundColor: base01]
        titleAttrs   = [.font: boldFont, .foregroundColor: cyan]
        sectionAttrs = [.font: font, .foregroundColor: green]
        valueAttrs = [
            .normal: [.font: font, .foregroundColor: cyan],
            .ok:     [.font: font, .foregroundColor: green],
            .warn:   [.font: font, .foregroundColor: yellow],
            .alert:  [.font: boldFont, .foregroundColor: red],
            .dim:    [.font: font, .foregroundColor: base01],
        ]
    }

    func size(of panel: Panel, columns: Int) -> CGSize {
        CGSize(width: CGFloat(columns) * cellW + 2 * style.padCols * cellW,
               height: CGFloat(panel.lines.count + 1) * rowH + 2 * style.padRows * rowH)
    }

    /// How many panel lines (title bar excluded) fit in `height` points.
    func lineCapacity(height: CGFloat) -> Int {
        max(0, Int((height - 2 * style.padRows * rowH) / rowH) - 1)
    }

    /// Draw a placed panel (corner + width decided by the core's PanelLayout)
    /// in `bounds`, inset by `margin` points. Must be called with the target as
    /// the current NSGraphicsContext.
    func draw(_ placed: PlacedPanel, in bounds: CGRect, margin: CGFloat) {
        let panel = placed.panel, corner = placed.corner, columns = placed.columns
        let sz = size(of: panel, columns: columns)
        let x: CGFloat, y: CGFloat
        switch corner {
        case .topLeft:     x = bounds.minX + margin;            y = bounds.maxY - margin - sz.height
        case .topRight:    x = bounds.maxX - margin - sz.width; y = bounds.maxY - margin - sz.height
        case .bottomRight: x = bounds.maxX - margin - sz.width; y = bounds.minY + margin
        case .bottomLeft:  x = bounds.minX + margin;            y = bounds.minY + margin
        }
        draw(panel, columns: columns, in: CGRect(origin: CGPoint(x: x, y: y), size: sz))
    }

    private func draw(_ panel: Panel, columns: Int, in box: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let box = box.integral

        // Box: translucent base03 plate, base01 hairline frame, cyan corner ticks.
        ctx.setFillColor(base03.withAlphaComponent(style.backgroundAlpha).cgColor)
        ctx.fill(box)
        ctx.setStrokeColor(base01.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(box.insetBy(dx: 0.5, dy: 0.5))
        let tick = cellW * 1.5
        ctx.setStrokeColor(cyan.cgColor)
        ctx.setLineWidth(2)
        for (cx, cy, dx, dy) in [(box.minX, box.minY, 1.0, 1.0), (box.maxX, box.minY, -1.0, 1.0),
                                 (box.minX, box.maxY, 1.0, -1.0), (box.maxX, box.maxY, -1.0, -1.0)] {
            ctx.move(to: CGPoint(x: cx + dx * tick, y: cy)); ctx.addLine(to: CGPoint(x: cx, y: cy))
            ctx.addLine(to: CGPoint(x: cx, y: cy + dy * tick))
        }
        ctx.strokePath()

        let left = box.minX + style.padCols * cellW
        let width = CGFloat(columns) * cellW
        var top = box.maxY - style.padRows * rowH

        // Title bar: ▓▒░ SYS ░▒▓ ──────  then a rule under it.
        top -= rowH
        ("▓▒░ " + panel.title + " ░▒▓" as NSString).draw(at: CGPoint(x: left, y: baseline(top)),
                                                         withAttributes: titleAttrs)
        drawRule(ctx, x: left, y: top + 2, width: width, color: base02)

        for line in panel.lines {
            top -= rowH
            let p = CGPoint(x: left, y: baseline(top))
            switch line.style {
            case .rule:
                drawRule(ctx, x: left, y: top + rowH / 2, width: width, color: base01)
            case .section:
                ("── " + line.label + " ──" as NSString).draw(at: p, withAttributes: sectionAttrs)
                if !line.value.isEmpty {   // e.g. the staleness marker `·12s`, dim, right-aligned
                    let x = p.x + CGFloat(columns - line.value.count) * cellW
                    (line.value as NSString).draw(at: CGPoint(x: x, y: p.y), withAttributes: dotAttrs)
                }
            case .text:
                (line.label as NSString).draw(at: p, withAttributes: valueAttrs[line.severity] ?? labelAttrs)
            case .field:
                drawField(line, columns: columns, at: p)
            }
        }
    }

    /// `LABEL ······ value`, value right-aligned to the panel's column count.
    private func drawField(_ line: PanelLine, columns cols: Int, at p: CGPoint) {
        let value = String(line.value.prefix(max(0, cols - line.label.count - 2)))
        let dots = max(1, cols - line.label.count - value.count - 2)
        (line.label as NSString).draw(at: p, withAttributes: labelAttrs)
        let dotX = p.x + CGFloat(line.label.count + 1) * cellW
        (String(repeating: "·", count: dots) as NSString)
            .draw(at: CGPoint(x: dotX, y: p.y), withAttributes: dotAttrs)
        let valX = p.x + CGFloat(cols - value.count) * cellW
        (value as NSString).draw(at: CGPoint(x: valX, y: p.y),
                                 withAttributes: valueAttrs[line.severity] ?? labelAttrs)
    }

    private func drawRule(_ ctx: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, color: NSColor) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: x, y: y.rounded() + 0.5))
        ctx.addLine(to: CGPoint(x: x + width, y: y.rounded() + 0.5))
        ctx.strokePath()
    }

    /// Text origin for a row whose bottom edge is `rowBottom`.
    private func baseline(_ rowBottom: CGFloat) -> CGFloat {
        (rowBottom + (rowH - style.fontSize) / 2 - font.descender * 0.5).rounded()
    }
}
