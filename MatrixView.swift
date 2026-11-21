//
//  MatrixView.swift
//  Solarized Matrix — Brutalist macOS screensaver
//

import ScreenSaver
import AppKit
import os

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
        // Logo "ghost" rain: bounding box as a fraction of min(width,height).
        static let logoSizeRatio: CGFloat = 0.60
        // Peak alpha of logo-stream glyphs at full fade-in.
        static let logoAlphaMax:  CGFloat = 0.95
        // Parallel "ghost" rain streams per column inside the logo mask. The logo
        // rain only paints on masked cells, so it needs many more streams than the
        // main rain (1/col) to read as a filled shape instead of sparse dots.
        static let logoStreams:   Int     = 10
        // Fade in/out envelope: the logo eases toward a target that flips between
        // "visible" and "hidden" on a random interval, so the mark breathes in and
        // out of the rain rather than sitting there statically.
        static let logoFadeSpeed: CGFloat = 0.02   // per-frame ease toward target (smaller = slower)
        static let logoHoldMin:   Int     = 150    // min frames a phase holds (~5s @30fps)
        static let logoHoldMax:   Int     = 420    // max frames a phase holds (~14s @30fps)

        // Diagnostic overlay (panels drawn over the rain on the main display).
        static let overlayFontSize: CGFloat = 15
        static let overlayMargin:   CGFloat = 48     // inset from the screen edge, points

        // Attention alerts (rendering only; WHEN the banner fires — 30 s wait
        // threshold, 60 s period, 4 s duration — is decided by AlertsCfg in the core).
        static let pulsePeriod:     Double  = 1.2    // seconds per red pulse of the AGENTS border/row
        static let bannerFontSize:  CGFloat = 30
        // While the banner shows, the trail fade runs toward a dark red at this
        // multiple of fadeAlpha and new rain glyphs fall red: the screen washes
        // red within the banner's ~4 s, then fades back at the normal trail rate.
        static let glitchWashRate:  CGFloat = 1.5
        static let glitchBurst:     Double  = 0.8    // seconds of slice glitch at the banner's start...
        static let glitchTailBurst: Double  = 0.3    // ...and at its end
        static let glitchBands:     Int     = 6      // displaced rain slices per burst frame
        static let glitchShift:     CGFloat = 70     // max horizontal slice displacement, points
        // Hidden debug lines: per-source fetch time and effective poll interval.
        // (Always on in SM_FRAME_DUMP real-host verification builds.)
        #if SM_FRAME_DUMP
        static let overlayDebug:    Bool    = true
        #else
        static let overlayDebug:    Bool    = false
        #endif
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
    private let alertRed  = hex("dc322f")
    private let alertWash = hex("3d0c10")   // background the rain fades toward during the banner
    private let alertRain: [NSColor] = ["dc322f", "cb4b16", "d33682"].map(hex)
    private let headColor = hex("eee8d5")
    private let stream: [NSColor] = ["2aa198","268bd2","859900","6c71c4","b58900"].map(hex)
    // Logo-stream palette — brighter warm greens & teals so the logo shape reads
    // as "materialised" from within the cooler main rain.
    private let logoStream: [NSColor] = ["6ef0c2","86e0f5","cdeb6e"].map(hex)

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
    private var dismissed = false
    private var ssObservers: [NSObjectProtocol] = []

    // MARK: - Diagnostic overlay
    // The UI-free core (Diagnostics/) builds panel models; PanelRenderer draws
    // them. No core at all in the System Settings preview.
    private var diagnostics: DiagnosticsCore?
    private var pollerHub: PollerHub?
    private var panelRenderer: PanelRenderer?
    /// Decided in setup(): not preview, main display, and config `overlay` on.
    private var overlayActive = false
    /// Overlay frames drawn (drives the pulse phase).
    private var alertFrame = 0
    /// Test/harness hook: force the main-display decision (nil = detect).
    var displayRoleOverride: Bool?
    private static let log = Logger(subsystem: "law.jude.SolarizedMatrix", category: "overlay")

    // Cached draw attributes. A font lookup plus an attributes dictionary per
    // glyph cost a few thousand allocations a frame; body/head dictionaries only
    // change when a column resets, so build them once and reuse.
    private lazy var font: NSFont = NSFont(name: "SF Mono", size: Cfg.fontSize)
        ?? NSFont.monospacedSystemFont(ofSize: Cfg.fontSize, weight: .semibold)
    private var colBodyAttrs: [[NSAttributedString.Key: Any]] = []
    private var colAlertAttrs: [[NSAttributedString.Key: Any]] = []   // red body glyphs during the banner
    private var colHeadAttrs: [[NSAttributedString.Key: Any]] = []

    // MARK: - Logo "ghost" rain state
    // A second rain stream, drawn only where it falls inside the logo shape.
    private var logoMask:    [[Bool]] = []   // [col][row] -> cell is inside the logo glyph
    private var logoDrops:   [[CGFloat]] = []   // [col][stream] parallel ghost drops
    private var logoColChar: [[String]]  = []   // [col][stream]
    // Fade in/out envelope state
    private var logoEnv:       CGFloat = 0       // eased visibility 0…1
    private var logoEnvTarget: CGFloat = 0       // start hidden so the mark fades in shortly after launch
    private var logoEnvHold:   Int     = 0       // frames until next target flip

    // MARK: - Lifecycle
    override convenience init?(frame: NSRect, isPreview: Bool) {
        self.init(frame: frame, isPreview: isPreview, environment: nil)
    }

    /// `environment` injects a fake diagnostics environment (render harness);
    /// nil means the live one. `pollerHub` is the background poller shared by
    /// every view in the process (the harness may pass its own).
    init?(frame: NSRect, isPreview: Bool, environment: DiagnosticsEnvironment?,
          pollerHub: PollerHub = .shared, debugLines: Bool = Cfg.overlayDebug) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30.0
        if !isPreview {
            self.pollerHub = pollerHub
            diagnostics = DiagnosticsCore(env: environment ?? .live(),
                                          polling: .shared(pollerHub), showDebug: debugLines)
        }
        observeScreenSaverState()
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

        logoDrops   = (0..<cols).map { _ in (0..<Cfg.logoStreams).map { _ in CGFloat.random(in: 0...rows) } }
        logoColChar = (0..<cols).map { _ in (0..<Cfg.logoStreams).map { _ in rc() } }

        colBodyAttrs = (0..<cols).map { attrs(colColor[$0], colAlpha[$0]) }
        colAlertAttrs = (0..<cols).map { attrs(alertRain[$0 % alertRain.count], colAlpha[$0]) }
        colHeadAttrs = (0..<cols).map { attrs(headColor, colAlpha[$0]) }

        buffer  = makeBuffer()
        buildLogoMask(bw: bounds.width, bh: bounds.height)
        decideOverlay()
        didInit = true
    }

    /// Main display = the one holding the menu bar (CGMainDisplayID, i.e.
    /// NSScreen.screens.first). With no window/screen yet, only a single-display
    /// machine counts as main. Re-run whenever the view changes window.
    private var isMainDisplay: Bool {
        if let forced = displayRoleOverride { return forced }
        guard let screen = window?.screen,
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return NSScreen.screens.count <= 1 }
        return CGDirectDisplayID(num.uint32Value) == CGMainDisplayID()
    }

    private func decideOverlay() {
        let main = isMainDisplay
        overlayActive = !isPreview && main && (diagnostics?.overlayEnabled ?? false)
        if overlayActive, panelRenderer == nil {
            panelRenderer = PanelRenderer(style: .init(fontSize: Cfg.overlayFontSize, bannerFontSize: Cfg.bannerFontSize))
        }
        // Only a view that shows the overlay holds a lease on the shared poller.
        if overlayActive { diagnostics?.startPolling() } else { diagnostics?.stopPolling() }
        logPoller("decide")
        let status = diagnostics.map { "\($0.configStatus)" } ?? "none"
        Self.log.notice("overlay=\(self.overlayActive, privacy: .public) preview=\(self.isPreview, privacy: .public) main=\(main, privacy: .public) config=\(status, privacy: .public) size=\(Int(self.bounds.width), privacy: .public)x\(Int(self.bounds.height), privacy: .public)")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if didInit { decideOverlay() }
    }

    override func startAnimation() { super.startAnimation() }

    // Kept for hosts that honour it; macOS 26's legacyScreenSaver does not — see
    // observeScreenSaverState() for the signal actually relied on.
    override func stopAnimation() {
        super.stopAnimation()
        teardown()
    }

    private func teardown() {
        buffer       = nil
        drops        = []; colColor    = []; colAlpha     = []
        colChar      = []; colHead     = []; colResetAt   = []
        colBodyAttrs = []; colHeadAttrs = []; colAlertAttrs = []
        logoMask     = []; logoDrops   = []; logoColChar  = []
        panelRenderer = nil; overlayActive = false; alertFrame = 0
        if diagnostics?.isPolling == true {
            diagnostics?.stopPolling()   // last view out stops the shared poller
            logPoller("teardown")
        }
        cols         = 0
        didInit      = false
    }

    // macOS 14+ (FB13041503) never calls stopAnimation() on a dismissed saver,
    // never releases the view, and goes on calling animateOneFrame forever. The
    // window gives nothing to test against: isVisible stays true and
    // occlusionState reads 8192 whether displayed or dismissed.
    //
    // Each activation builds a fresh instance, but the host also calls
    // startAnimation on the stale ones, so without this their render loops
    // accumulate and run in parallel. didstop is therefore TERMINAL: an instance
    // that has been dismissed never draws again, and the next activation's new
    // instance does the drawing.
    //
    // Deliberately not exit(0), which the usual advice suggests: the host is
    // respawned within seconds, and a host spawned outside a screensaver session
    // never receives a didstop — so it animates forever. That trades one stuck
    // render loop for an endless exit/respawn/burn cycle.
    private func observeScreenSaverState() {
        let dnc = DistributedNotificationCenter.default()
        ssObservers = [
            dnc.addObserver(forName: .init("com.apple.screensaver.didstop"),
                            object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.isPreview else { return }
                self.dismissed = true
                self.teardown()
            },
        ]
    }

    private func logPoller(_ event: String) {
        guard let hub = pollerHub else { return }
        Self.log.notice("poller \(event, privacy: .public) leased=\(self.isPolling, privacy: .public) running=\(hub.isRunning, privacy: .public) leases=\(hub.activeLeases, privacy: .public) starts=\(hub.starts, privacy: .public)")
    }

    /// Harness/diagnostics: whether this view currently leases the poller.
    var isPolling: Bool { diagnostics?.isPolling ?? false }

    deinit {
        let dnc = DistributedNotificationCenter.default()
        ssObservers.forEach { dnc.removeObserver($0) }
    }

    override func animateOneFrame() {
        guard isPreview || !dismissed else { return }

        let needsSetup = !didInit
            || cols != Int(bounds.width / Cfg.fontSize)
            || buffer?.width  != Int(bounds.width)
            || buffer?.height != Int(bounds.height)
        if needsSetup { setup() }
        needsDisplay = true
        #if SM_FRAME_DUMP
        dumpFrameIfDue()
        #endif
    }

    #if SM_FRAME_DUMP
    // Real-host verification aid, compiled in only with
    // `SM_SWIFT_FLAGS="-D SM_FRAME_DUMP" mise run install`. The screen can't be
    // captured while the saver runs (the session is locked, loginwindow covers
    // it), so the saver renders itself through the normal draw path into a
    // bitmap and writes a PNG into its own (sandbox container) temp dir.
    private var dumpFrameCount = 0
    // Banner dumps: one in the opening glitch burst and one in the steady
    // red wash of each takeover banner (first few banners only).
    private var lastBannerElapsed: Double?
    private var prevBannerElapsed: Double?
    private var bannerDumps = 0
    private func dumpFrameIfDue() {
        dumpFrameCount += 1
        let e = lastBannerElapsed, prev = prevBannerElapsed ?? -1
        prevBannerElapsed = e
        let bannerDue = bannerDumps < 6 && e.map { e in [0.35, 2.0].contains { prev < $0 && e >= $0 } } == true
        guard !dismissed, bannerDue || dumpFrameCount == 150 || dumpFrameCount % 1800 == 0,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        if bannerDue { bannerDumps += 1 }
        cacheDisplay(in: bounds, to: rep)
        let tag = bannerDue ? String(format: "-banner%.1f", e ?? 0) : ""
        let name = "SolarizedMatrix-frame-\(getpid())-\(isPreview ? "preview" : "main")-\(dumpFrameCount)\(tag).png"
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
        let ok = (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) != nil
        Self.log.notice("frame dump \(name, privacy: .public) ok=\(ok, privacy: .public)")
    }

    // Draw-time stats over the last window of frames, logged with each dump
    // window: lets the real host show whether polling makes the rain stutter.
    // Frames drawn while the takeover banner/glitch runs are tallied
    // separately (banner=true) so the glitch's cost shows on its own.
    private var drawTimes: [UInt64] = []
    private var bannerDrawTimes: [UInt64] = []
    private func recordDrawTime(_ ns: UInt64) {
        guard !dismissed else { return }
        let inBanner = lastBannerElapsed != nil
        if inBanner { bannerDrawTimes.append(ns) } else { drawTimes.append(ns) }
        let window = inBanner ? 100 : 300
        let times = inBanner ? bannerDrawTimes : drawTimes
        guard times.count >= window else { return }
        let sorted = times.sorted()
        let ms = { (q: Double) in Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]) / 1e6 }
        Self.log.notice("draw ms p50=\(ms(0.5), privacy: .public) p99=\(ms(0.99), privacy: .public) max=\(ms(1.0), privacy: .public) n=\(sorted.count, privacy: .public) polling=\(self.isPolling, privacy: .public) banner=\(inBanner, privacy: .public)")
        if inBanner { bannerDrawTimes.removeAll(keepingCapacity: true) } else { drawTimes.removeAll(keepingCapacity: true) }
    }
    #endif

    // MARK: - Frame
    override func draw(_ rect: NSRect) {
        // Each frame allocates a full-screen CGImage plus thousands of text
        // temporaries. Without an explicit pool they accumulate for the life of
        // the hosting process, which outlives the saver.
        #if SM_FRAME_DUMP
        let t0 = DispatchTime.now().uptimeNanoseconds
        autoreleasepool { drawFrame() }
        recordDrawTime(DispatchTime.now().uptimeNanoseconds - t0)
        #else
        autoreleasepool { drawFrame() }
        #endif
    }

    private func drawFrame() {
        if !didInit { setup() }
        guard let buf = buffer,
              let screenCtx = NSGraphicsContext.current?.cgContext else { return }

        let bw = CGFloat(buf.width), bh = CGFloat(buf.height)

        // Advance the logo fade envelope: flip to a new target on a random interval,
        // then ease toward it so the mark fades in/out of the rain.
        if logoEnvHold <= 0 {
            logoEnvTarget = logoEnvTarget < 0.5 ? CGFloat.random(in: 0.80...1.0)
                                                : CGFloat.random(in: 0.0...0.10)
            logoEnvHold   = Int.random(in: Cfg.logoHoldMin...Cfg.logoHoldMax)
        }
        logoEnvHold -= 1
        logoEnv += (logoEnvTarget - logoEnv) * Cfg.logoFadeSpeed
        let logoAlphaNow = Cfg.logoAlphaMax * logoEnv

        // Attention takeover banner: decided by the core, asked once per frame.
        // While it shows, the rain itself turns red (wash + red glyphs, both in
        // the buffer, so it costs nothing extra and fades back out with the trails).
        let banner = overlayActive ? diagnostics?.banner() : nil
        #if SM_FRAME_DUMP
        lastBannerElapsed = banner?.elapsed
        #endif

        // Step 1: fade buffer toward base03 (builds the glowing trail effect)
        if banner == nil {
            buf.setFillColor(base03.withAlphaComponent(Cfg.fadeAlpha).cgColor)
        } else {
            buf.setFillColor(alertWash.withAlphaComponent(Cfg.fadeAlpha * Cfg.glitchWashRate).cgColor)
        }
        buf.fill(CGRect(x: 0, y: 0, width: bw, height: bh))

        // Step 2: draw new glyph positions into the buffer via AppKit text APIs
        let bufNSCtx = NSGraphicsContext(cgContext: buf, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = bufNSCtx

        // Only three distinct logo colours, but the envelope alpha changes every
        // frame, so rebuild just these three rather than one per glyph.
        let logoAttrs = logoStream.map { attrs($0, logoAlphaNow) }

        for i in 0..<cols {
            let x    = CGFloat(i) * Cfg.fontSize
            let yTop = bh - drops[i] * Cfg.fontSize

            if Double.random(in: 0...1) > 0.92 { colChar[i] = rc() }

            drawGlyph(colChar[i], at: CGPoint(x: x, y: yTop),
                      attrs: banner == nil ? colBodyAttrs[i] : colAlertAttrs[i])
            drawGlyph(colHead[i], at: CGPoint(x: x, y: yTop - Cfg.fontSize),
                      attrs: colHeadAttrs[i])

            drops[i] += Cfg.fallMin + CGFloat.random(in: 0...(Cfg.fallMax - Cfg.fallMin))

            if drops[i] > colResetAt[i] {
                drops[i]      = CGFloat.random(in: -4...0)
                colColor[i]   = stream.randomElement()!
                colAlpha[i]   = CGFloat.random(in: 0.25...1.0)
                colChar[i]    = rc()
                colHead[i]    = rh()
                colResetAt[i] = resetThreshold(bufH: bh)
                colBodyAttrs[i] = attrs(colColor[i], colAlpha[i])
                colAlertAttrs[i] = attrs(alertRain.randomElement()!, colAlpha[i])
                colHeadAttrs[i] = attrs(headColor, colAlpha[i])
            }

            // Logo "ghost" rain: advance a parallel drop and draw it only when
            // it lands on a cell inside the logo mask, so the shape emerges
            // from within the falling code rather than as a solid watermark.
            if i < logoMask.count {
                for k in 0..<logoDrops[i].count {
                    let logoRow = Int(logoDrops[i][k])
                    if logoAlphaNow > 0.01, logoRow >= 0, logoRow < logoMask[i].count, logoMask[i][logoRow] {
                        let lyTop = bh - logoDrops[i][k] * Cfg.fontSize
                        drawGlyph(logoColChar[i][k], at: CGPoint(x: x, y: lyTop),
                                  attrs: logoAttrs[(i + k) % logoAttrs.count])
                        if Double.random(in: 0...1) > 0.88 { logoColChar[i][k] = rc() }
                    }
                    logoDrops[i][k] += (Cfg.fallMin + CGFloat.random(in: 0...(Cfg.fallMax - Cfg.fallMin))) * 0.9
                    if logoDrops[i][k] > colResetAt[i] {
                        logoDrops[i][k]   = CGFloat.random(in: -4...0)
                        logoColChar[i][k] = rc()
                    }
                }
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        // Step 3: blit accumulated buffer to screen
        let img = buf.makeImage()
        if let img { screenCtx.draw(img, in: bounds) }

        // Step 4: diagnostic overlay, straight into the screen context (never
        // the fading buffer) so it stays crisp. Panel models are rebuilt every
        // frame so the clock ticks.
        // Corners and widths come from the core's layout; the AGENTS roster is
        // capped to the lines that fit the screen height.
        //
        // Attention alerts: the slice glitch goes on the screen ctx (never the
        // buffer, so displaced slices don't smear into the trails), under the
        // panels, with the banner on top of everything.
        if overlayActive, let core = diagnostics, let renderer = panelRenderer {
            alertFrame += 1
            if let banner, inBurst(banner), let img { drawGlitch(screenCtx, rain: img) }
            let t = Double(alertFrame) * animationTimeInterval / Cfg.pulsePeriod
            let pulse = CGFloat(0.5 - 0.5 * cos(2 * Double.pi * t))
            core.agentsMaxLines = renderer.lineCapacity(height: bounds.height - 2 * Cfg.overlayMargin)
            for placed in core.layout() {
                renderer.draw(placed, in: bounds, margin: Cfg.overlayMargin, pulse: pulse)
            }
            if let banner {
                renderer.drawBanner(banner.text, in: bounds, alpha: glitchEnvelope(banner),
                                    jitter: inBurst(banner) && Bool.random() ? CGFloat.random(in: -8...8) : 0)
            }
        }
    }

    // MARK: - Attention glitch

    /// 0→1 over the first 0.15 s, 1→0 over the last 0.3 s.
    private func glitchEnvelope(_ b: AlertBanner) -> CGFloat {
        CGFloat(max(0, min(1, b.elapsed / 0.15, (b.duration - b.elapsed) / 0.3)))
    }

    private func inBurst(_ b: AlertBanner) -> Bool {
        b.elapsed < Cfg.glitchBurst || b.duration - b.elapsed < Cfg.glitchTailBurst
    }

    /// During the bursts: a few horizontal slices of the rain displaced
    /// sideways and flashed red. Clipped redraws of the frame image the blit
    /// already made, so the cost is proportional to the slices' area.
    private func drawGlitch(_ ctx: CGContext, rain img: CGImage) {
        for _ in 0..<Cfg.glitchBands {
            let h = CGFloat.random(in: 4...46)
            let band = CGRect(x: bounds.minX, y: CGFloat.random(in: bounds.minY...(bounds.maxY - h)),
                              width: bounds.width, height: h)
            ctx.saveGState()
            ctx.clip(to: band)
            ctx.draw(img, in: bounds.offsetBy(dx: CGFloat.random(in: -Cfg.glitchShift...Cfg.glitchShift), dy: 0))
            ctx.setFillColor(alertRed.withAlphaComponent(CGFloat.random(in: 0.12...0.35)).cgColor)
            ctx.fill(band)
            ctx.restoreGState()
        }
    }

    /// Build the `[col][row]` mask of which glyph cells fall inside the logo
    /// shape, by rendering the logo into an off-screen ARGB context at
    /// `logoSize × logoSize` and sampling its alpha channel per cell. Rebuilt
    /// from `setup()` so it tracks the current bounds / column count.
    private func buildLogoMask(bw: CGFloat, bh: CGFloat) {
        let rowCount = max(0, Int(bh / Cfg.fontSize))
        // Default every cell to "outside" so the draw loop can index safely even
        // when the logo image is unavailable or the context can't be created.
        logoMask = [[Bool]](repeating: [Bool](repeating: false, count: rowCount),
                            count: cols)

        let logoSize = (min(bw, bh) * (isPreview ? 0.35 : Cfg.logoSizeRatio))
            .rounded(.down)
        let dim = Int(logoSize)
        guard dim > 0, let logo = judeLogo else { return }

        let bytesPerRow = dim * 4
        guard let ctx = CGContext(data: nil, width: dim, height: dim,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return }

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        logo.draw(in: CGRect(x: 0, y: 0, width: logoSize, height: logoSize))
        NSGraphicsContext.restoreGraphicsState()

        let bytes = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * dim)
        let logoOriginX = bw / 2 - logoSize / 2
        let logoOriginY = bh / 2 - logoSize / 2

        for i in 0..<cols {
            for r in 0..<rowCount {
                let screenX = CGFloat(i) * Cfg.fontSize + Cfg.fontSize / 2
                // y-up: row 0 is the top of the screen (matches the draw loop).
                let screenY = bh - CGFloat(r) * Cfg.fontSize - Cfg.fontSize / 2
                let lx = Int((screenX - logoOriginX) / logoSize * logoSize)
                let ly = Int((screenY - logoOriginY) / logoSize * logoSize)
                if lx >= 0, lx < dim, ly >= 0, ly < dim {
                    let alpha = bytes[ly * bytesPerRow + lx * 4 + 3]
                    logoMask[i][r] = alpha > 40
                }
            }
        }
    }

    private func attrs(_ color: NSColor, _ alpha: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color.withAlphaComponent(alpha)]
    }

    private func drawGlyph(_ s: String, at p: CGPoint, attrs: [NSAttributedString.Key: Any]) {
        s.draw(at: p, withAttributes: attrs)
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
