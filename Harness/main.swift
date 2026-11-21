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
    /// Fake `~/.claude*` session files written into the scratch home.
    var sessions: [HarnessSession] = []
    /// Frames to render (nil = the command-line count).
    var frames: Int? = nil
    /// What the fake Wi-Fi reader returns (nil = unreadable). Made-up names only.
    var wifi: String? = nil
    /// Collector state file written into the fake home (nil = none: COLLECTOR OFFLINE).
    var collector: CollectorState? = nil
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

/// One fake session file (neutral names and paths only).
struct HarnessSession {
    var dir = ".claude"
    var pid: Int32
    var cwd: String
    var status: String
    var waitingFor: String? = nil
    var entrypoint = "cli"
    var kind = "interactive"
    /// Seconds before t0 that the status last changed.
    var ago: TimeInterval
    /// false = GHOST (the fake liveness checker reports it dead).
    var alive = true
    /// Running subagents (fresh, unfinished meta files under projects/).
    var subagents = 0
    /// A running background job attributed to this session.
    var job = false
}

/// A busy mixed workload: every state, several config dirs, CLI and desktop.
let demoSessions: [HarnessSession] = {
    var s: [HarnessSession] = [
        .init(pid: 4101, cwd: "/home/demo/code/alpha", status: "waiting",
              waitingFor: "approve Bash: make deploy", ago: 95, subagents: 1),
        .init(dir: ".claude-alpha", pid: 4102, cwd: "/home/demo/code/beta", status: "waiting",
              waitingFor: "input needed", entrypoint: "claude-desktop", ago: 20),
        .init(pid: 4103, cwd: "/home/demo/code/gamma", status: "busy", ago: 640, subagents: 3, job: true),
        .init(dir: ".claude-beta", pid: 4104, cwd: "/home/demo/code/delta", status: "busy", ago: 75, subagents: 2),
        .init(pid: 4105, cwd: "/home/demo/code/alpha/.claude/worktrees/w1", status: "shell", ago: 12),
        .init(dir: ".claude-alpha", pid: 4106, cwd: "/home/demo/code/epsilon", status: "idle",
              entrypoint: "claude-desktop", ago: 180),
        .init(pid: 4107, cwd: "/home/demo/code/zeta", status: "idle", ago: 610),
        .init(pid: 4108, cwd: "/home/demo/code/eta", status: "busy", ago: 30, alive: false),
        .init(pid: 4109, cwd: "/home/demo/code/theta", status: "busy", kind: "daemon", ago: 5),
    ]
    for i in 0..<14 {
        s.append(.init(dir: i % 3 == 0 ? ".claude-beta" : ".claude", pid: Int32(4200 + i),
                       cwd: "/home/demo/code/repo\(i % 6)", status: "idle", ago: Double(3600 * (i + 1))))
    }
    return s
}()

/// Two sessions at a prompt (25 s and 12 s ago) among busy/idle ones.
let alertSessions: [HarnessSession] = [
    .init(pid: 4101, cwd: "/home/demo/code/alpha", status: "waiting",
          waitingFor: "approve Bash: make deploy", ago: 25),
    .init(dir: ".claude-alpha", pid: 4102, cwd: "/home/demo/code/beta", status: "waiting",
          waitingFor: "permission prompt", ago: 12),
    .init(pid: 4103, cwd: "/home/demo/code/gamma", status: "busy", ago: 640),
    .init(dir: ".claude-beta", pid: 4106, cwd: "/home/demo/code/epsilon", status: "idle", ago: 180),
]

let scenarios = [
    Scenario(name: "overlay"),
    Scenario(name: "overlay-off", configJSON: #"{ "overlay": false }"#),
    Scenario(name: "preview", isPreview: true),
    Scenario(name: "secondary-display", mainDisplay: false),
    Scenario(name: "overlay-debug", debugLines: true, power: .battery(percent: 64, onAC: true, charging: true),
             thermal: .serious),
    Scenario(name: "overlay-stale", debugLines: true, vitalsFailAfterFirst: true, clockStep: 0.2),
    Scenario(name: "overlay-desktop", power: .noBattery),
    Scenario(name: "agents", configJSON: #"{ "codenameSalt": "harness-demo" }"#, sessions: demoSessions),
    Scenario(name: "agents-signal-lost", sessions: [.init(pid: 1, cwd: "/x", status: "busy", ago: 1)]),
    // Attention alerts. The oldest waiting session (4101) reaches 30 s at
    // frame 150 (5 s), so the banner starts there: frame 162 is inside the
    // opening glitch burst, frame 210 in the steady red tint, frame 300 after
    // the banner (pulse only, rain washing back). Frame 126: pulse at its peak, no banner yet.
    Scenario(name: "alert-pulse", configJSON: #"{ "codenameSalt": "harness-demo" }"#,
             sessions: alertSessions, frames: 126),
    Scenario(name: "alert-glitch", configJSON: #"{ "codenameSalt": "harness-demo" }"#,
             sessions: alertSessions, frames: 162),
    Scenario(name: "alert-banner", configJSON: #"{ "codenameSalt": "harness-demo" }"#,
             sessions: alertSessions, frames: 210),
    Scenario(name: "alert-after", configJSON: #"{ "codenameSalt": "harness-demo" }"#,
             sessions: alertSessions, frames: 300),
    // Trusted network: real (fake) repo names. Unreadable Wi-Fi: codenames + NET UNVERIFIED.
    Scenario(name: "agents-trusted",
             configJSON: #"{ "codenameSalt": "harness-demo", "trustedSSIDs": ["TrustedNet"] }"#,
             sessions: demoSessions, wifi: "TrustedNet"),
    Scenario(name: "agents-unverified",
             configJSON: #"{ "codenameSalt": "harness-demo", "trustedSSIDs": ["TrustedNet"] }"#,
             sessions: demoSessions, wifi: nil),
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
    for f in s.sessions {
        let ms = { (d: Date) in Int64(d.timeIntervalSince1970 * 1000) }
        var obj: [String: Any] = ["pid": Int(f.pid), "sessionId": "s-\(f.pid)", "cwd": f.cwd,
                                  "status": f.status, "kind": f.kind, "entrypoint": f.entrypoint,
                                  "procStart": "Fri Nov 20 19:37:21 2026",
                                  "statusUpdatedAt": ms(t0.addingTimeInterval(-f.ago)),
                                  "updatedAt": ms(t0.addingTimeInterval(-f.ago))]
        if let w = f.waitingFor { obj["waitingFor"] = w }
        let dir = "\(home)/\(f.dir)/sessions"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let body = s.name == "agents-signal-lost" ? Data("{truncated".utf8)
                                                   : (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        FileManager.default.createFile(atPath: "\(dir)/\(f.pid).json", contents: body)
        let sub = "\(home)/\(f.dir)/projects/\(ProjectDirName.from(cwd: f.cwd))/s-\(f.pid)/subagents"
        for i in 0..<f.subagents {
            try? FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: "\(sub)/agent-a\(i).meta.json",
                                           contents: Data(#"{"agentType":"general-purpose"}"#.utf8))
            FileManager.default.createFile(atPath: "\(sub)/agent-a\(i).jsonl", contents: Data("{}".utf8),
                                           attributes: [.modificationDate: t0.addingTimeInterval(-20)])
        }
        if f.job {
            let job = "\(home)/\(f.dir)/jobs/\(String(format: "%08x", f.pid))"
            try? FileManager.default.createDirectory(atPath: job, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: "\(job)/state.json",
                                           contents: Data(#"{"state":"working","sessionId":"s-\#(f.pid)"}"#.utf8))
        }
    }
    let dead = Set(s.sessions.filter { !$0.alive }.map(\.pid))
    let thermal = s.thermal, power = s.power, failAfterFirst = s.vitalsFailAfterFirst, wifi = s.wifi
    var env = DiagnosticsEnvironment(now: { clock.now },
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
    env.isProcessAlive = { pid, _ in !dead.contains(pid) }
    env.readWiFi = { wifi }
    return env
}

/// Wait (real time) for the background poller to catch up.
func waitFor(_ timeout: TimeInterval = 2, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.005) }
    return cond()
}

func makeContext(_ size: NSSize = size) throws -> (NSBitmapImageRep, NSGraphicsContext) {
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
    for i in 0..<(s.frames ?? frames) {
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

/// Draw time while the takeover banner + red glitch run vs. the same view
/// without it (alertSessions: banner from frame 150 to 270, bursts in
/// 150..<174 and 261..<270).
func alertTimingCheck() throws {
    let clock = Clock()
    let env = makeWorld(Scenario(name: "timing-alert", configJSON: #"{ "codenameSalt": "harness-demo" }"#,
                                 sessions: alertSessions), clock: clock)
    let hub = PollerHub(tickInterval: 0.01)
    guard let view = MatrixView(frame: NSRect(origin: .zero, size: size), isPreview: false,
                                environment: env, pollerHub: hub) else { throw NSError(domain: "harness", code: 1) }
    view.displayRoleOverride = true
    let (_, ctx) = try makeContext()
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    var plain: [Double] = [], glitch: [Double] = [], burst: [Double] = []
    for i in 0..<420 {
        view.animateOneFrame()
        if i == 0 { _ = waitFor { clock.vitalsFetches > 0 } }
        let t = DispatchTime.now().uptimeNanoseconds
        view.draw(view.bounds)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
        switch i {
        case 150..<174, 262..<270: burst.append(ms); glitch.append(ms)
        case 150..<270: glitch.append(ms)
        case 50..<145, 280...: plain.append(ms)
        default: break
        }
        clock.advance(1.0 / 30.0)
        if i % 30 == 0 { Thread.sleep(forTimeInterval: 0.005) }   // let the poller re-read sessions
    }
    NSGraphicsContext.restoreGraphicsState()
    view.stopAnimation()
    func stats(_ a: [Double]) -> String {
        let s = a.sorted()
        return String(format: "p50=%.2f p99=%.2f max=%.2f n=%d", s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.99))], s.last!, s.count)
    }
    print("alert frame time (ms): no banner \(stats(plain)) | banner \(stats(glitch)) | burst \(stats(burst))")
}

/// Burn-in rotation with a shortened interval (5 s per corner): one PNG per
/// position, rotation-<label>-<step>-sys-<corner>.png, with the busy AGENTS
/// roster so the per-corner height cap and logo clearance are visible.
func renderRotation(_ size: NSSize, label: String) throws {
    let interval: TimeInterval = 5
    let clock = Clock()
    let s = Scenario(name: "rotation", configJSON: #"{ "codenameSalt": "harness-demo" }"#, sessions: demoSessions)
    let env = makeWorld(s, clock: clock)
    let hub = PollerHub(tickInterval: 0.01)
    guard let view = MatrixView(frame: NSRect(origin: .zero, size: size), isPreview: false,
                                environment: env, pollerHub: hub) else { throw NSError(domain: "harness", code: 1) }
    view.displayRoleOverride = true
    view.panelRotationInterval = interval
    // Start at the beginning of a rotation cycle (step 0).
    let cycle = 4 * interval
    clock.advance(cycle - clock.now.timeIntervalSince1970.truncatingRemainder(dividingBy: cycle))
    let (_, ctx) = try makeContext(size)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    let perStep = max(1, frames / 2)
    let step = (interval - 0.1) / Double(perStep)   // stay inside the interval while the rain fills
    for k in 0..<4 {
        for i in 0..<perStep {
            view.animateOneFrame()
            if i == 0, k == 0 { _ = waitFor { clock.vitalsFetches > 0 }; Thread.sleep(forTimeInterval: 0.05) }
            view.draw(view.bounds)
            clock.advance(step)
        }
        let corner = PanelRotation(interval: interval).sysCorner(at: clock.now)
        let path = "\(outDir)/rotation-\(label)-\(k)-sys-\(corner).png"
        // Snapshot the live context (the rep's PNG encoding is cached after
        // the first call, so re-encoding the rep would repeat frame one).
        ctx.flushGraphics()
        guard let img = ctx.cgContext.makeImage(),
              let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
        else { throw NSError(domain: "harness", code: 3) }
        try png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
        clock.advance(0.1)   // cross into the next interval
    }
    NSGraphicsContext.restoreGraphicsState()
    view.stopAnimation()
}

/// REAL_HOME=1: render once against the live environment (real home, real
/// clock, real liveness), read-only. For a local check only: the screenshot
/// shows real totals and salted codenames, never folder or repo names.
func renderRealHome() throws {
    let hub = PollerHub(tickInterval: 0.05)
    guard let view = MatrixView(frame: NSRect(origin: .zero, size: size), isPreview: false,
                                environment: .live(), pollerHub: hub) else { throw NSError(domain: "harness", code: 1) }
    view.displayRoleOverride = true
    let (rep, ctx) = try makeContext()
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    for i in 0..<frames {
        view.animateOneFrame()
        if i == 0 { Thread.sleep(forTimeInterval: 0.5) }   // let the first real fetches land
        view.draw(view.bounds)
    }
    NSGraphicsContext.restoreGraphicsState()
    view.stopAnimation()
    let path = "\(outDir)/agents-real.png"
    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
if ProcessInfo.processInfo.environment["REAL_HOME"] == "1" {
    try autoreleasepool { try renderRealHome() }
    exit(0)
}
for s in scenarios {
    let path = try autoreleasepool { try render(s) }
    print("wrote \(path)")
}
try autoreleasepool { try renderRotation(NSSize(width: 1728, height: 1117), label: "1728x1117") }
try autoreleasepool { try renderRotation(size, label: "1440x900") }
try autoreleasepool { try sharedPollerCheck() }
if ProcessInfo.processInfo.environment["TIMING"] == "1" {
    try autoreleasepool { try frameTimeCheck() }
    try autoreleasepool { try alertTimingCheck() }
}


enum AtomicFileForHarness {
    static func write(_ data: Data, _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
