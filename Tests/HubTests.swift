//
//  HubTests.swift — the shared background poller (real threads, short tick):
//  several cores share one poller; it stops when the last one stops.
//

import Foundation

/// Thread-safe fake clock + fetch counter for the background queue.
private final class SharedFake {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_795_271_405)
    private var calls = 0
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    var vitalsCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
    func countCall() { lock.lock(); calls += 1; lock.unlock() }

    /// Captures `self` strongly: a tick already in flight on the hub queue can finish after the test
    /// releases its last lease, and must not touch a destroyed fake (that crashed intermittently).
    func env(home: String) -> DiagnosticsEnvironment {
        DiagnosticsEnvironment(now: { self.now },
                               homeDirectory: home,
                               configPath: ConfigLoader.defaultPath(home: home),
                               bootTime: Date(timeIntervalSince1970: 1_795_000_000),
                               timeZone: { TimeZone(identifier: "UTC")! },
                               readVitals: {
                                   self.countCall()
                                   return HostVitals(load: [1, 2, 3], memoryPressure: .normal, thermal: .fair)
                               },
                               readPower: { .noBattery })
    }
}

/// Spin until `cond` holds or `timeout` passes.
private func eventually(_ timeout: TimeInterval = 2, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return cond()
}

func hubTests() {
    test("two views share one poller; it stops when the last one stops") {
        let hub = PollerHub(tickInterval: 0.02)
        let fake = SharedFake()
        let home = makeTempDir("hub")
        let a = DiagnosticsCore(env: fake.env(home: home), polling: .shared(hub))
        let b = DiagnosticsCore(env: fake.env(home: home), polling: .shared(hub))
        expect(!hub.isRunning)

        a.startPolling(); b.startPolling(); a.startPolling()   // idempotent per core
        expect(hub.isRunning)
        expectEqual(hub.starts, 1)
        expectEqual(hub.activeLeases, 2)
        expect(eventually { b.panels()[0].value(of: "THERMAL") == "FAIR" }, "B sees polled data")
        expectEqual(a.panels()[0].value(of: "THERMAL"), "FAIR")
        expectEqual(fake.vitalsCalls, 1)   // one fetch serves both views

        fake.advance(5)
        expect(eventually { fake.vitalsCalls == 2 }, "still polling on schedule")

        a.stopPolling()
        expect(hub.isRunning, "B still holds a lease")
        fake.advance(5)
        expect(eventually { fake.vitalsCalls == 3 })

        b.stopPolling(); b.stopPolling()
        expect(!hub.isRunning)
        expectEqual(hub.activeLeases, 0)
        let frozen = fake.vitalsCalls
        fake.advance(60)
        Thread.sleep(forTimeInterval: 0.2)
        expectEqual(fake.vitalsCalls, frozen)
        // A stopped core shows no polled data (the render loop is gone anyway).
        expect(b.panels()[0].value(of: "THERMAL") == nil)

        // A later activation starts a fresh poller.
        let c = DiagnosticsCore(env: fake.env(home: home), polling: .shared(hub))
        c.startPolling()
        expectEqual(hub.starts, 2)
        expect(eventually { fake.vitalsCalls == frozen + 1 })
        c.stopPolling()
        expect(!hub.isRunning)
    }

    test("a core released without stopPolling still returns its lease") {
        let hub = PollerHub(tickInterval: 0.02)
        let fake = SharedFake()
        let home = makeTempDir("hub-deinit")
        do {
            let a = DiagnosticsCore(env: fake.env(home: home), polling: .shared(hub))
            a.startPolling()
            expect(hub.isRunning)
        }
        expect(!hub.isRunning)
    }

    test("overlay off: the core never starts the poller") {
        let hub = PollerHub(tickInterval: 0.02)
        let fake = SharedFake()
        let home = makeTempDir("hub-off")
        writeFile(ConfigLoader.defaultPath(home: home), #"{ "overlay": false }"#)
        let a = DiagnosticsCore(env: fake.env(home: home), polling: .shared(hub))
        a.startPolling()
        expect(!hub.isRunning)
        expectEqual(hub.starts, 0)
    }
}
