//
//  main.swift — offscreen render harness (`mise run snapshot`).
//
//  Builds the REAL MatrixView + PanelRenderer + diagnostics core into a plain
//  executable, drives it with a fake DiagnosticsEnvironment (scratch home under
//  the output dir, fixed clock, fixed boot time), runs N frames into an offscreen
//  2x bitmap and writes PNGs. No screensaver host, no real home, no private
//  data: safe for screenshots. Later tickets add fake session trees etc. to the
//  fake home in `makeWorld` and new scenarios below.
//
//  Usage: SnapshotHarness [outDir] [frames]
//

import AppKit

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "build/snapshot"
let frames = args.count > 2 ? Int(args[2]) ?? 150 : 150
let size = NSSize(width: 1440, height: 900)
let scale: CGFloat = 2

/// 2026-11-21 14:30:05 UTC; boot 4d 03:12 earlier.
let t0 = Date(timeIntervalSince1970: 1_795_271_405)

final class Clock { var now = t0 }

struct Scenario {
    var name: String
    var isPreview = false
    var mainDisplay = true
    var configJSON: String? = nil
}

let scenarios = [
    Scenario(name: "overlay"),
    Scenario(name: "overlay-off", configJSON: #"{ "overlay": false }"#),
    Scenario(name: "preview", isPreview: true),
    Scenario(name: "secondary-display", mainDisplay: false),
]

func makeWorld(_ s: Scenario, clock: Clock) -> DiagnosticsEnvironment {
    let home = "\(outDir)/home-\(s.name)"
    try? FileManager.default.removeItem(atPath: home)
    try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    let cfg = ConfigLoader.defaultPath(home: home)
    if let json = s.configJSON {
        try? FileManager.default.createDirectory(atPath: (cfg as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? json.write(toFile: cfg, atomically: true, encoding: .utf8)
    }
    return DiagnosticsEnvironment(now: { clock.now },
                                  homeDirectory: home,
                                  configPath: cfg,
                                  bootTime: t0.addingTimeInterval(-(4 * 86400 + 3 * 3600 + 12 * 60)),
                                  timeZone: { TimeZone(identifier: "UTC")! })
}

func render(_ s: Scenario) throws -> String {
    let clock = Clock()
    let env = makeWorld(s, clock: clock)
    guard let view = MatrixView(frame: NSRect(origin: .zero, size: size),
                                isPreview: s.isPreview, environment: env) else {
        throw NSError(domain: "harness", code: 1)
    }
    view.displayRoleOverride = s.mainDisplay

    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(size.width * scale),
                                     pixelsHigh: Int(size.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        throw NSError(domain: "harness", code: 2)
    }
    rep.size = size   // points -> 2x pixels, like a Retina screen (set BEFORE making the context)
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "harness", code: 2)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    for _ in 0..<frames {
        view.animateOneFrame()
        view.draw(view.bounds)
        clock.now = clock.now.addingTimeInterval(1.0 / 30.0)
    }
    NSGraphicsContext.restoreGraphicsState()

    let path = "\(outDir)/\(s.name).png"
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "harness", code: 3)
    }
    try png.write(to: URL(fileURLWithPath: path))
    return path
}

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for s in scenarios {
    let path = try autoreleasepool { try render(s) }
    print("wrote \(path)")
}
