//
//  MatrixView.swift
//  Solarized Matrix — Brutalist macOS screensaver
//

import ScreenSaver
import AppKit

// Jude logo SVG — fetched from jude.law/images/layout/logo.svg
private let judeSVG = """
<svg width="51" height="51" viewBox="0 0 51 51" fill="none" xmlns="http://www.w3.org/2000/svg">
<path d="M50.1463 31.968L50.1462 33.7534L46.1633 35.745C42.1765 37.7384 39.7512 41.5076 39.7512 45.7102L39.7512 49.2893L38.0232 50.1533L25.9001 44.0916L25.9 40.9181C25.9 35.3931 29.4187 30.2087 35.095 27.3704L38.0232 25.9063L50.1463 31.968Z" fill="white"/>
<path d="M5.29934e-07 31.968L3.30989e-05 33.7534L3.98294 35.745C7.96978 37.7384 10.3951 41.5076 10.3951 45.7102L10.3951 49.2893L12.1231 50.1533L24.2462 44.0916L24.2462 40.9181C24.2462 35.3931 20.7275 30.2087 15.0513 27.3704L12.1231 25.9063L5.29934e-07 31.968Z" fill="white"/>
<path d="M0 18.1853L3.24129e-05 16.3999L3.98294 14.4083C7.96978 12.4149 10.3951 8.64566 10.3951 4.44307L10.3951 0.864046L12.1231 2.38419e-06L24.2462 6.06174L24.2462 9.2352C24.2462 14.7603 20.7275 19.9446 15.0513 22.7829L12.1231 24.247L0 18.1853Z" fill="white"/>
<path d="M50.1463 18.1853L50.1462 16.3999L46.1633 14.4083C42.1765 12.4149 39.7512 8.64565 39.7512 4.44307L39.7511 0.864044L38.0232 0L25.9001 6.06174L25.9 9.2352C25.9 14.7603 29.4187 19.9446 35.095 22.7829L38.0232 24.247L50.1463 18.1853Z" fill="white"/>
</svg>
"""

final class MatrixView: ScreenSaverView {

    // MARK: - Tunables
    private struct Cfg {
        static let fontSize:  CGFloat = 16
        static let fallMin:   CGFloat = 0.4
        static let fallMax:   CGFloat = 1.2
        // How much each frame fades toward background. Lower = longer trails.
        // At 0.018 and 30 fps a glyph takes ~4 seconds to fade out (~96 rows).
        static let fadeAlpha: CGFloat = 0.018
    }

    // MARK: - Solarized palette
    private static func hex(_ s: String) -> NSColor {
        var h = s; if h.hasPrefix("#") { h.removeFirst() }
        let v = UInt32(h, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                       green:   CGFloat((v >> 8)  & 0xff) / 255,
                       blue:    CGFloat(v & 0xff) / 255, alpha: 1)
    }
    private let base03    = hex("002b36")
    private let headColor = hex("eee8d5")
    private let stream: [NSColor] = ["2aa198","268bd2","859900","6c71c4","b58900"].map(hex)

    // MARK: - Glyph sets
    private static let bodyGlyphs: [String] = {
        let syms = Array("{}[]()<>=!+-*/%&|^~?:;.,0123456789#$@\\_'`\"").map { String($0) }
        var kata: [String] = []
        for c in 0xFF66...0xFF9D { if let u = Unicode.Scalar(c) { kata.append(String(u)) } }
        return syms + syms + kata
    }()

    private static let headTokens: [String] = [
        "=>","===","!==","?.","??","||","&&","...","++","--","**",
        "<<",">>","+=","-=","*=","/=","||=","&&=","??=",
        "null","void","true","false","NaN","undefined",
        "new","let","var","if","do","in","of",
        "const","async","await","type","enum","from","this","else",
        "while","catch","throw","yield","super","class",
        "import","export","return","delete","typeof","instanceof","extends",
        "any","never","unknown","string","number","boolean","object","symbol","bigint",
        "fn","cb","id","db","req","res","err","api","url","ctx","ref",
        "key","val","map","set","arr","obj","msg","buf","pkg","mod",
        "[]","{}","()","<>","/*","*/","//","::","->",
    ]

    private func rc() -> String { Self.bodyGlyphs.randomElement()! }
    private func rh() -> String { Self.headTokens.randomElement()! }

    // MARK: - Jude logo
    private lazy var judeLogo: NSImage? = {
        guard let data = judeSVG.data(using: .utf8) else { return nil }
        return NSImage(data: data)
    }()

    // MARK: - Off-screen accumulation buffer
    // Trails only work if pixels persist across draw() calls. ScreenSaverView
    // doesn't guarantee backing-store preservation, so we own a CGContext that
    // we composite into every frame, then blit to screen.
    private var buffer: CGContext?

    // MARK: - Per-column state
    private var cols:       Int       = 0
    private var drops:      [CGFloat] = []   // current row position (increases as drop falls)
    private var colColor:   [NSColor] = []
    private var colAlpha:   [CGFloat] = []   // per-stream brightness 0.25…1.0
    private var colChar:    [String]  = []
    private var colHead:    [String]  = []
    private var colResetAt: [CGFloat] = []   // row at which this drop resets
    private var didInit = false

    // MARK: - Lifecycle
    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30.0
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    private func makeBuffer() -> CGContext? {
        let w = Int(bounds.width), h = Int(bounds.height)
        guard w > 0, h > 0 else { return nil }
        let ctx = CGContext(data: nil, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.setFillColor(base03.cgColor)
        ctx?.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return ctx
    }

    private func resetThreshold(bufH: CGFloat) -> CGFloat {
        // Drop resets after travelling 0–15% past the bottom edge
        bufH / Cfg.fontSize + CGFloat.random(in: 0...bufH / Cfg.fontSize * 0.15)
    }

    private func setup() {
        cols = max(1, Int(bounds.width / Cfg.fontSize))
        let rows = bounds.height / Cfg.fontSize

        // Seed drops across the full screen height so it looks full immediately
        drops      = (0..<cols).map { _ in CGFloat.random(in: 0...rows) }
        colColor   = (0..<cols).map { stream[$0 % stream.count] }
        colAlpha   = (0..<cols).map { _ in CGFloat.random(in: 0.25...1.0) }
        colChar    = (0..<cols).map { _ in rc() }
        colHead    = (0..<cols).map { _ in rh() }
        colResetAt = (0..<cols).map { _ in resetThreshold(bufH: bounds.height) }

        buffer  = makeBuffer()
        didInit = true
    }

    override func startAnimation() { super.startAnimation() }
    override func stopAnimation()  { super.stopAnimation() }

    override func animateOneFrame() {
        let needsSetup = !didInit
            || cols != Int(bounds.width / Cfg.fontSize)
            || buffer?.width  != Int(bounds.width)
            || buffer?.height != Int(bounds.height)
        if needsSetup { setup() }
        needsDisplay = true
    }

    // MARK: - Frame
    override func draw(_ rect: NSRect) {
        if !didInit { setup() }
        guard let buf = buffer,
              let screenCtx = NSGraphicsContext.current?.cgContext else { return }

        let bw = CGFloat(buf.width), bh = CGFloat(buf.height)

        // Step 1: fade buffer toward base03 (builds the glowing trail effect)
        buf.setFillColor(base03.withAlphaComponent(Cfg.fadeAlpha).cgColor)
        buf.fill(CGRect(x: 0, y: 0, width: bw, height: bh))

        // Step 2: draw new glyph positions into the buffer via AppKit text APIs
        let bufNSCtx = NSGraphicsContext(cgContext: buf, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = bufNSCtx

        let font = NSFont(name: "SF Mono", size: Cfg.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: Cfg.fontSize, weight: .semibold)

        for i in 0..<cols {
            let x    = CGFloat(i) * Cfg.fontSize
            let yTop = bh - drops[i] * Cfg.fontSize

            if Double.random(in: 0...1) > 0.92 { colChar[i] = rc() }

            drawGlyph(colChar[i], at: CGPoint(x: x, y: yTop),
                      color: colColor[i].withAlphaComponent(colAlpha[i]), font: font)
            drawGlyph(colHead[i], at: CGPoint(x: x, y: yTop - Cfg.fontSize),
                      color: headColor.withAlphaComponent(colAlpha[i]), font: font)

            drops[i] += Cfg.fallMin + CGFloat.random(in: 0...(Cfg.fallMax - Cfg.fallMin))

            if drops[i] > colResetAt[i] {
                drops[i]      = CGFloat.random(in: -4...0)
                colColor[i]   = stream.randomElement()!
                colAlpha[i]   = CGFloat.random(in: 0.25...1.0)
                colChar[i]    = rc()
                colHead[i]    = rh()
                colResetAt[i] = resetThreshold(bufH: bh)
            }
        }

        drawJudeLogo(bw: bw, bh: bh)

        NSGraphicsContext.restoreGraphicsState()

        // Step 3: blit accumulated buffer to screen
        if let img = buf.makeImage() {
            screenCtx.draw(img, in: bounds)
        }
    }

    private func drawJudeLogo(bw: CGFloat, bh: CGFloat) {
        guard let logo = judeLogo else { return }
        let size: CGFloat = isPreview ? 40 : 120
        let rect = CGRect(x: bw / 2 - size / 2, y: bh / 2 - size / 2,
                          width: size, height: size)
        NSGraphicsContext.current?.cgContext.setAlpha(0.18)
        logo.draw(in: rect)
        NSGraphicsContext.current?.cgContext.setAlpha(1.0)
    }

    private func drawGlyph(_ s: String, at p: CGPoint, color: NSColor, font: NSFont) {
        s.draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
