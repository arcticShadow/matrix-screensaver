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

/// The Solarized palette (see README), shared by the rain (MatrixView) and
/// the panels. The one place colours are defined.
enum Solarized {
    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    static let base03  = hex(0x002b36)
    static let base02  = hex(0x073642)
    static let base01  = hex(0x586e75)
    static let base1   = hex(0x93a1a1)
    static let base2   = hex(0xeee8d5)
    static let yellow  = hex(0xb58900)
    static let orange  = hex(0xcb4b16)
    static let red     = hex(0xdc322f)
    static let magenta = hex(0xd33682)
    static let violet  = hex(0x6c71c4)
    static let blue    = hex(0x268bd2)
    static let cyan    = hex(0x2aa198)
    static let green   = hex(0x859900)
}

final class PanelRenderer {

    /// Geometry and translucency. The saver fills it from its `Cfg`
    /// (MatrixView.swift), where every rendering tunable lives.
    struct Style {
        var fontSize: CGFloat
        /// Inner padding in character cells (horizontal) / rows (vertical, fractional).
        var padCols: CGFloat
        var padRows: CGFloat
        /// Row height as a multiple of fontSize.
        var lineSpacing: CGFloat
        /// Opacity of the panel's base03 plate.
        var backgroundAlpha: CGFloat
        /// Centre takeover banner text size (before shrinking to fit).
        var bannerFontSize: CGFloat
        /// The banner box is never wider than this fraction of the screen.
        var bannerMaxWidth: CGFloat
        /// Opacity of the banner's base03 plate.
        var bannerPlateAlpha: CGFloat
        /// Opacity of the cyan ghost copy drawn during glitch jitter.
        var bannerGhostAlpha: CGFloat
    }

    private let base03 = Solarized.base03
    private let base02 = Solarized.base02
    private let base01 = Solarized.base01
    private let base1  = Solarized.base1
    private let cyan   = Solarized.cyan
    private let green  = Solarized.green
    private let yellow = Solarized.yellow
    private let red    = Solarized.red

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
    private let pulseAttrs: [NSAttributedString.Key: Any]
    private let bannerFont: NSFont
    private let bannerAttrs: [NSAttributedString.Key: Any]
    private let bannerGhostAttrs: [NSAttributedString.Key: Any]
    private var bannerSizeCache: (text: String, size: CGSize)?

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
        pulseAttrs = [.font: boldFont, .foregroundColor: red]
        bannerFont = NSFont(name: "SF Mono Bold", size: style.bannerFontSize)
            ?? NSFont.monospacedSystemFont(ofSize: style.bannerFontSize, weight: .bold)
        bannerAttrs = [.font: bannerFont, .foregroundColor: red]
        bannerGhostAttrs = [.font: bannerFont, .foregroundColor: cyan.withAlphaComponent(style.bannerGhostAlpha)]
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
    /// the current NSGraphicsContext. `pulse` (0…1) is the current phase of the
    /// attention pulse, applied to whatever the model marks as pulsing.
    func draw(_ placed: PlacedPanel, in bounds: CGRect, margin: CGFloat, pulse: CGFloat = 0) {
        let panel = placed.panel, corner = placed.corner, columns = placed.columns
        let sz = size(of: panel, columns: columns)
        let x: CGFloat, y: CGFloat
        switch corner {
        case .topLeft:     x = bounds.minX + margin;            y = bounds.maxY - margin - sz.height
        case .topRight:    x = bounds.maxX - margin - sz.width; y = bounds.maxY - margin - sz.height
        case .bottomRight: x = bounds.maxX - margin - sz.width; y = bounds.minY + margin
        case .bottomLeft:  x = bounds.minX + margin;            y = bounds.minY + margin
        }
        draw(panel, columns: columns, in: CGRect(origin: CGPoint(x: x, y: y), size: sz), pulse: pulse)
    }

    private func draw(_ panel: Panel, columns: Int, in box: CGRect, pulse: CGFloat) {
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
        if panel.pulse {
            // Red frame breathing over the hairline, plus a faint outer glow.
            ctx.saveGState()
            ctx.setAlpha(0.25 + 0.75 * pulse)
            ctx.setStrokeColor(red.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(box.insetBy(dx: 1, dy: 1))
            ctx.setAlpha(0.35 * pulse)
            ctx.setLineWidth(4)
            ctx.stroke(box.insetBy(dx: -3, dy: -3))
            ctx.restoreGState()
        }

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
            case .text where line.pulse:
                // Folded AGENTS totals: flashes red over the label colour,
                // like the ATTENTION row it stands in for.
                (line.label as NSString).draw(at: p, withAttributes: labelAttrs)
                ctx.saveGState()
                ctx.setAlpha(pulse)
                (line.label as NSString).draw(at: p, withAttributes: pulseAttrs)
                ctx.restoreGState()
            case .text:
                (line.label as NSString).draw(at: p, withAttributes: valueAttrs[line.severity] ?? labelAttrs)
            case .field:
                drawField(line, columns: columns, at: p)
                if line.pulse {
                    // The row's label flashes red over its normal colour.
                    ctx.saveGState()
                    ctx.setAlpha(pulse)
                    (line.label as NSString).draw(at: p, withAttributes: pulseAttrs)
                    ctx.restoreGState()
                }
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

    /// Centre takeover banner: `text` in red on an opaque plate with a red
    /// double frame. `alpha` fades it in/out; `jitter` (points) shifts the
    /// text sideways with a cyan ghost copy for the glitch bursts.
    func drawBanner(_ text: String, in bounds: CGRect, alpha: CGFloat, jitter: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext, alpha > 0 else { return }
        let str = text as NSString
        if bannerSizeCache?.text != text { bannerSizeCache = (text, str.size(withAttributes: bannerAttrs)) }
        let textSize = bannerSizeCache!.size
        let padX = style.bannerFontSize * 1.4, padY = style.bannerFontSize * 0.9
        // Never wider than the screen (minus a margin); shrink if the name is long.
        let maxW = bounds.width * style.bannerMaxWidth
        let scale = min(1, maxW / (textSize.width + 2 * padX))
        let box = CGRect(x: bounds.midX - (textSize.width * scale + 2 * padX) / 2,
                         y: bounds.midY - (textSize.height * scale + 2 * padY) / 2,
                         width: textSize.width * scale + 2 * padX,
                         height: textSize.height * scale + 2 * padY).integral
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setFillColor(base03.withAlphaComponent(style.bannerPlateAlpha).cgColor)
        ctx.fill(box)
        ctx.setStrokeColor(red.cgColor)
        ctx.setLineWidth(3)
        ctx.stroke(box.insetBy(dx: 1.5, dy: 1.5))
        ctx.setLineWidth(1)
        ctx.stroke(box.insetBy(dx: 7.5, dy: 7.5))
        let origin = CGPoint(x: box.minX + padX, y: box.minY + padY)
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: scale, y: scale)
        if jitter != 0 {
            str.draw(at: CGPoint(x: -jitter * 0.6, y: 0), withAttributes: bannerGhostAttrs)
        }
        str.draw(at: CGPoint(x: jitter, y: 0), withAttributes: bannerAttrs)
        ctx.restoreGState()
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
