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
//  SM_COLLECTOR_STATE=<path>: also render `overlay-real-usage` from a real
//  collector state file (copied into the fake home; clock = real now). Local
//  verification only: the PNG shows real usage numbers by profile tag.
//

import AppKit

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "build/snapshot"
let frames = args.count > 2 ? Int(args[2]) ?? 150 : 150
let size = NSSize(width: 1440, height: 900)
let scale: CGFloat = 2

/// 2026-11-21 14:30:05 UTC; boot 4d 03:12 earlier.
let t0 = Date(timeIntervalSince1970: 1_795_271_405)

/// Fake clock + fetch counter. Thread-safe: the shared poller reads the clock
/// and calls the readers on its background queue.
final class Clock {
    private let lock = NSLock()
    private var t: Date
    init(start: Date = t0) { t = start }
    private var fetches = 0
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
    var vitalsFetches: Int { lock.lock(); defer { lock.unlock() }; return fetches }
    func countFetch() -> Int { lock.lock(); defer { lock.unlock() }; fetches += 1; return fetches }
}

struct Scenario {
    var name: String
    var isPreview = false
    var mainDisplay = true
    var configJSON: String? = nil
    var debugLines = false
    var power: PowerStatus = .battery(percent: 87, onAC: false, charging: false)
    var thermal: HostVitals.Thermal = .nominal
    /// Vitals fail after the first fetch (drives the staleness marker).
    var vitalsFailAfterFirst = false
    /// Fake seconds per frame (larger = data ages faster).
    var clockStep: TimeInterval = 1.0 / 30.0
    /// Collector state file written into the fake home (nil = none: COLLECTOR OFFLINE).
    var collector: CollectorState? = nil
    /// Session files to create (config dir basenames), so token-less accounts show.
    var sessionDirs: [String] = []
    /// Clock start (default t0).
    var start: Date = t0
}

/// A fake collector state at t0: two healthy accounts (one near its limits,
/// with extra usage), one with an expired token, one without a token.
func fakeUsageState() -> CollectorState {
    func acct(_ dir: String, _ five: Double, _ seven: Double, token: AccountUsage.TokenState = .ok,
              ago: TimeInterval = 40, extra: ExtraUsage? = nil) -> AccountUsage {
        AccountUsage(dir: dir, token: token, tokenExpiresAt: t0.addingTimeInterval(3600),
                     generatedAt: t0.addingTimeInterval(-ago),
                     fiveHour: UsageWindow(utilization: five, resetsAt: t0.addingTimeInterval(2 * 3600 + 14 * 60)),
                     sevenDay: UsageWindow(utilization: seven, resetsAt: t0.addingTimeInterval(4 * 86400 + 3 * 3600)),
                     extra: extra)
    }
    var sched = SourceSchedule(baseInterval: 300)
    sched.recordSuccess(at: t0.addingTimeInterval(-40), duration: 1.4)
    return CollectorState(generatedAt: t0.addingTimeInterval(-40),
                          schedules: [CollectorSourceIDs.usage: sched],
                          usage: UsageSection(generatedAt: t0.addingTimeInterval(-40), accounts: [
                            acct(".claude", 37, 12),
                            acct(".claude-alpha", 78, 91, extra: ExtraUsage(enabled: true, usedMinor: 1240,
                                 limitMinor: nil, currency: "NZD", decimalPlaces: 2)),
                            acct(".claude-beta", 64, 30, token: .expired, ago: 3 * 3600),
                            AccountUsage(dir: ".claude-gamma", token: .none),
                          ]))
}

let scenarios = [
    Scenario(name: "overlay"),
    Scenario(name: "overlay-off", configJSON: #"{ "overlay": false }"#),
    Scenario(name: "preview", isPreview: true),
    Scenario(name: "secondary-display", mainDisplay: false),
    Scenario(name: "overlay-debug", debugLines: true, power: .battery(percent: 64, onAC: true, charging: true),
             thermal: .serious),
    Scenario(name: "overlay-stale", debugLines: true, vitalsFailAfterFirst: true, clockStep: 0.2),
    Scenario(name: "overlay-desktop", power: .noBattery),
    Scenario(name: "overlay-usage", collector: fakeUsageState()),
] + realUsageScenario()

func realUsageScenario() -> [Scenario] {
    guard let path = ProcessInfo.processInfo.environment["SM_COLLECTOR_STATE"] else { return [] }
    guard let st = try? CollectorStateStore.load(path: path) else {
        print("SM_COLLECTOR_STATE: cannot read state file"); return []
    }
    return [Scenario(name: "overlay-real-usage", collector: st, start: Date())]
}

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
    if let st = s.collector, let data = try? CollectorStateStore.encode(st) {
        try? AtomicFileForHarness.write(data, CollectorStateStore.defaultPath(home: home))
    }
    for d in s.sessionDirs {
        let p = "\(home)/\(d)/sessions/1.json"
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? "{}".write(toFile: p, atomically: true, encoding: .utf8)
    }
    let thermal = s.thermal, power = s.power, failAfterFirst = s.vitalsFailAfterFirst
    return DiagnosticsEnvironment(now: { clock.now },
                                  homeDirectory: home,
                                  configPath: cfg,
                                  bootTime: t0.addingTimeInterval(-(4 * 86400 + 3 * 3600 + 12 * 60)),
                                  timeZone: { TimeZone(identifier: "UTC")! },
                                  readVitals: {
                                      if clock.countFetch() > 1, failAfterFirst {
                                          throw ReaderError(description: "fake failure")
                                      }
                                      return HostVitals(load: [1.84, 1.52, 1.37], memoryPressure: .normal,
                                                        thermal: thermal)
                                  },
                                  readPower: { power })
}

/// Wait (real time) for the background poller to catch up.
func waitFor(_ timeout: TimeInterval = 2, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.005) }
    return cond()
}

func makeContext() throws -> (NSBitmapImageRep, NSGraphicsContext) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(size.width * scale),
                                     pixelsHigh: Int(size.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        throw NSError(domain: "harness", code: 2)
    }
    rep.size = size   // points -> 2x pixels, like a Retina screen (set BEFORE making the context)
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { throw NSError(domain: "harness", code: 2) }
    return (rep, ctx)
}

func render(_ s: Scenario) throws -> String {
    let clock = Clock(start: s.start)
    let env = makeWorld(s, clock: clock)
    let hub = PollerHub(tickInterval: 0.01)
    guard let view = MatrixView(frame: NSRect(origin: .zero, size: size),
                                isPreview: s.isPreview, environment: env,
                                pollerHub: hub, debugLines: s.debugLines) else {
        throw NSError(domain: "harness", code: 1)
    }
    view.displayRoleOverride = s.mainDisplay
    let (rep, ctx) = try makeContext()

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    for i in 0..<frames {
        view.animateOneFrame()
        // Let the first fetch land before frame 1 so snapshots are deterministic.
        if i == 0, view.isPolling { _ = waitFor { clock.vitalsFetches > 0 } ; Thread.sleep(forTimeInterval: 0.02) }
        view.draw(view.bounds)
        clock.advance(s.clockStep)
        if s.clockStep > 0.1 { Thread.sleep(forTimeInterval: 0.002) }   // give the poller turns
    }
    NSGraphicsContext.restoreGraphicsState()
    view.stopAnimation()
    if hub.isRunning { throw NSError(domain: "harness: poller still running after stopAnimation", code: 4) }

    let path = "\(outDir)/\(s.name).png"
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "harness", code: 3)
    }
    try png.write(to: URL(fileURLWithPath: path))
    return path
}

/// Two overlay views (e.g. two main-role instances) on one hub: one poller,
/// one fetch stream; tearing both down stops it and fetching stops.
func sharedPollerCheck() throws {
    let clock = Clock()
    let env = makeWorld(Scenario(name: "shared"), clock: clock)
    let hub = PollerHub(tickInterval: 0.01)
    let views = (0..<2).compactMap { _ in
        MatrixView(frame: NSRect(origin: .zero, size: size), isPreview: false, environment: env, pollerHub: hub)
    }
    views.forEach { $0.displayRoleOverride = true; $0.animateOneFrame() }
    let ok1 = hub.starts == 1 && hub.activeLeases == 2 && hub.isRunning
    _ = waitFor { clock.vitalsFetches >= 1 }
    for _ in 0..<20 { clock.advance(1); Thread.sleep(forTimeInterval: 0.01) }   // 20 fake s -> ~4 more vitals fetches
    _ = waitFor { clock.vitalsFetches >= 5 }
    let during = clock.vitalsFetches
    views[0].stopAnimation()
    let ok2 = hub.isRunning && hub.activeLeases == 1
    views[1].stopAnimation()
    let ok3 = !hub.isRunning && hub.activeLeases == 0
    let frozen = clock.vitalsFetches
    for _ in 0..<20 { clock.advance(5); Thread.sleep(forTimeInterval: 0.01) }
    let ok4 = clock.vitalsFetches == frozen
    print("shared poller: starts=\(hub.starts) leases-with-2-views ok=\(ok1) fetches(20s,2 views)=\(during) one-stopped-still-running=\(ok2) all-stopped=\(ok3) fetches-after-teardown-frozen=\(ok4)")
    guard ok1, ok2, ok3, ok4, during <= 6 else { throw NSError(domain: "harness: shared poller check failed", code: 5) }
}

/// Draw-time percentiles with the poller idle vs. with a deliberately slow
/// (40 ms, CPU-burning) vitals fetch running on the background queue every frame.
func frameTimeCheck() throws {
    func run(_ name: String, slow: Bool) throws -> (Double, Double, Int) {
        let clock = Clock()
        var env = makeWorld(Scenario(name: "timing-\(name)"), clock: clock)
        if slow {
            env.readVitals = {
                _ = clock.countFetch()
                let end = Date().addingTimeInterval(0.04)
                var x = 0.0; while Date() < end { x += sin(x) }   // burn CPU, not just sleep
                return HostVitals(load: [x.isNaN ? 0 : 1, 1, 1], memoryPressure: .normal, thermal: .nominal)
            }
        }
        let hub = PollerHub(tickInterval: 0.01)
        guard let view = MatrixView(frame: NSRect(origin: .zero, size: size), isPreview: false,
                                    environment: env, pollerHub: hub) else { throw NSError(domain: "harness", code: 1) }
        view.displayRoleOverride = true
        let (_, ctx) = try makeContext()
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        var times: [Double] = []
        for i in 0..<400 {
            view.animateOneFrame()
            let t = DispatchTime.now().uptimeNanoseconds
            view.draw(view.bounds)
            if i >= 50 { times.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6) }
            clock.advance(1)   // vitals due every frame-ish (throttled to 20 x its measured duration)
        }
        NSGraphicsContext.restoreGraphicsState()
        view.stopAnimation()
        times.sort()
        return (times[times.count / 2], times[Int(Double(times.count) * 0.99)], clock.vitalsFetches)
    }
    let idle = try run("idle", slow: false)
    let busy = try run("busy", slow: true)
    print(String(format: "frame time (ms): fast fetch p50=%.2f p99=%.2f fetches=%d | slow 40ms fetch p50=%.2f p99=%.2f fetches=%d",
                 idle.0, idle.1, idle.2, busy.0, busy.1, busy.2))
}

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for s in scenarios {
    let path = try autoreleasepool { try render(s) }
    print("wrote \(path)")
}
try autoreleasepool { try sharedPollerCheck() }
if ProcessInfo.processInfo.environment["TIMING"] == "1" { try autoreleasepool { try frameTimeCheck() } }


enum AtomicFileForHarness {
    static func write(_ data: Data, _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
