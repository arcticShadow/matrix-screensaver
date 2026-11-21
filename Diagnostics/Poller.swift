//
//  Poller.swift
//  Background polling of data sources.
//
//  - `DiagSnapshot`: immutable value the render thread reads (one typed slot
//    per source + every source's schedule).
//  - `PollSource` + `PollSources.standard`: the source registry. Adding a
//    source = a reader in DiagnosticsEnvironment, a slot in DiagSnapshot, one
//    `.make(...)` line in `standard`, and its panel lines.
//  - `PollEngine`: single-threaded; `tick(now:)` runs every due source once,
//    timing it with the environment clock and updating its SourceSchedule.
//    Tests drive it directly (manual polling mode).
//  - `PollerHub`: the one shared background poller. Views lease it; the first
//    lease starts a timer on a background queue, the last release stops it.
//

import Foundation

/// A source's latest good value and when it was fetched.
struct Sample<T: Equatable>: Equatable {
    var value: T
    var fetchedAt: Date
}

struct DiagSnapshot: Equatable {
    var vitals: Sample<HostVitals>?
    var power: Sample<PowerStatus>?
    var sessions: Sample<SessionScan>?
    var wifi: Sample<WiFiStatus>?
    /// Every registered source's schedule, by id (staleness, debug stats).
    var schedules: [SourceID: SourceSchedule] = [:]
}

struct PollSource {
    let id: SourceID
    let baseInterval: TimeInterval
    /// Reads the source (may throw) and returns how to store the result.
    let fetch: () throws -> (inout DiagSnapshot, Date) -> Void

    /// Typed registration: `read` produces a T stored into `slot`.
    static func make<T: Equatable>(_ id: SourceID, every base: TimeInterval,
                                   read: @escaping () throws -> T,
                                   into slot: WritableKeyPath<DiagSnapshot, Sample<T>?>) -> PollSource {
        PollSource(id: id, baseInterval: base) {
            let value = try read()
            return { snap, at in snap[keyPath: slot] = Sample(value: value, fetchedAt: at) }
        }
    }
}

enum SourceIDs {
    static let vitals: SourceID = "VIT"
    static let power: SourceID = "PWR"
    static let sessions: SourceID = "SES"
    static let wifi: SourceID = "NET"
}

enum PollSources {
    /// Display order of the debug lines (the registry order).
    static let order: [SourceID] = [SourceIDs.vitals, SourceIDs.power, SourceIDs.sessions, SourceIDs.wifi]

    /// The saver's sources, in display order for the debug lines.
    static func standard(_ env: DiagnosticsEnvironment) -> [PollSource] {
        [
            .make(SourceIDs.vitals, every: 5, read: env.readVitals, into: \.vitals),
            .make(SourceIDs.power, every: 60, read: env.readPower, into: \.power),
            .make(SourceIDs.sessions, every: 2, read: { [home = env.homeDirectory, alive = env.isProcessAlive] in
                try SessionReader.scan(home: home, isAlive: alive)
            }, into: \.sessions),
            .make(SourceIDs.wifi, every: 30, read: { [read = env.readWiFi] in
                WiFiStatus(ssid: try read())
            }, into: \.wifi),
        ]
    }
}

final class PollEngine {
    private let sources: [PollSource]
    private let clock: () -> Date
    private(set) var snapshot = DiagSnapshot()

    init(sources: [PollSource], clock: @escaping () -> Date) {
        self.sources = sources
        self.clock = clock
        for s in sources { snapshot.schedules[s.id] = SourceSchedule(baseInterval: s.baseInterval) }
    }

    /// Run every source that is due at `now`. Returns true if anything ran.
    @discardableResult
    func tick(now: Date? = nil) -> Bool {
        let now = now ?? clock()
        var ran = false
        for src in sources {
            var sched = snapshot.schedules[src.id] ?? SourceSchedule(baseInterval: src.baseInterval)
            guard sched.isDue(now: now) else { continue }
            ran = true
            let start = clock()
            do {
                let store = try src.fetch()
                let end = clock()
                store(&snapshot, end)
                sched.recordSuccess(at: end, duration: end.timeIntervalSince(start))
            } catch {
                let end = clock()
                sched.recordFailure(at: end, duration: end.timeIntervalSince(start))
            }
            snapshot.schedules[src.id] = sched
        }
        return ran
    }
}

/// The single background poller shared by every MatrixView in the process.
/// Thread-safe. The engine (and its sources) come from the FIRST lease's
/// factory; later leases just share it.
final class PollerHub {
    static let shared = PollerHub()

    private let queue = DispatchQueue(label: "law.jude.SolarizedMatrix.poller", qos: .utility)
    private let lock = NSLock()
    private let tickInterval: TimeInterval
    // Guarded by lock:
    private var leaseCount = 0
    private var generation = 0
    private var timer: DispatchSourceTimer?
    private var published = DiagSnapshot()
    private var startCount = 0

    init(tickInterval: TimeInterval = 0.25) { self.tickInterval = tickInterval }

    /// Start polling (if this is the first lease) and return a lease that
    /// stops it again on release (if it is the last).
    func acquire(_ makeEngine: @escaping () -> PollEngine) -> PollerLease {
        lock.lock(); defer { lock.unlock() }
        leaseCount += 1
        if leaseCount == 1 { start(makeEngine) }
        return PollerLease(hub: self)
    }

    /// Latest snapshot (cheap: a struct copy under a lock).
    func snapshot() -> DiagSnapshot {
        lock.lock(); defer { lock.unlock() }
        return published
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return timer != nil }
    var activeLeases: Int { lock.lock(); defer { lock.unlock() }; return leaseCount }
    /// How many times a poller has been started (diagnostics/tests).
    var starts: Int { lock.lock(); defer { lock.unlock() }; return startCount }

    fileprivate func release() {
        lock.lock(); defer { lock.unlock() }
        guard leaseCount > 0 else { return }
        leaseCount -= 1
        if leaseCount == 0 { stop() }
    }

    // Both called with lock held.
    private func start(_ makeEngine: @escaping () -> PollEngine) {
        generation += 1
        startCount += 1
        published = DiagSnapshot()
        let gen = generation
        var engine: PollEngine?   // confined to `queue`
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: tickInterval, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            if engine == nil { engine = makeEngine() }
            guard let self, let e = engine, e.tick() else { return }
            let snap = e.snapshot
            self.lock.lock()
            if self.generation == gen { self.published = snap }
            self.lock.unlock()
        }
        // Drop the engine (and its readers) on the queue once cancelled.
        t.setCancelHandler { engine = nil }
        timer = t
        t.resume()
    }

    private func stop() {
        generation += 1
        timer?.cancel()
        timer = nil
        published = DiagSnapshot()
    }
}

/// A view's claim on the shared poller. Release is idempotent and also
/// happens on deinit.
final class PollerLease {
    private weak var hub: PollerHub?
    private var released = false
    private let lock = NSLock()

    fileprivate init(hub: PollerHub) { self.hub = hub }

    func release() {
        lock.lock()
        let first = !released
        released = true
        lock.unlock()
        if first { hub?.release() }
    }

    deinit { release() }
}
