//
//  PollerTests.swift — host vitals, battery and the adaptive scheduling policy,
//  asserted through the panel model (DiagnosticsCore in manual polling mode:
//  injected clock + fake readers with fake fetch durations, no threads).
//

import Foundation

private func core(_ w: FakeWorld, debug: Bool = false) -> DiagnosticsCore {
    DiagnosticsCore(env: w.env, polling: .manual, showDebug: debug)
}

func pollerTests() {
    test("after a poll the SYS panel shows load, memory pressure and thermal state") {
        let w = FakeWorld("poll-vitals")
        let c = core(w)
        c.pollNow()
        let p = c.panels()[0]
        expectEqual(p.value(of: "LOAD.AVG"), "0.42 0.38 0.31")
        expectEqual(p.line("MEM.PRESSURE"), .field("MEM.PRESSURE", "NOMINAL", .ok))
        expectEqual(p.line("THERMAL"), .field("THERMAL", "NOMINAL", .ok))
    }

    test("each thermal state maps to its label and severity") {
        let cases: [(HostVitals.Thermal, PanelLine)] = [
            (.nominal, .field("THERMAL", "NOMINAL", .ok)),
            (.fair, .field("THERMAL", "FAIR", .normal)),
            (.serious, .field("THERMAL", "SERIOUS", .warn)),
            (.critical, .field("THERMAL", "CRITICAL", .alert)),
        ]
        for (state, line) in cases {
            let w = FakeWorld("poll-thermal")
            w.vitals.thermal = state
            let c = core(w); c.pollNow()
            expectEqual(c.panels()[0].line("THERMAL"), line)
        }
    }

    test("memory pressure warn and critical are amber and red") {
        for (m, line) in [(HostVitals.MemoryPressure.warn, PanelLine.field("MEM.PRESSURE", "ELEVATED", .warn)),
                          (.critical, .field("MEM.PRESSURE", "CRITICAL", .alert))] {
            let w = FakeWorld("poll-mem")
            w.vitals.memoryPressure = m
            let c = core(w); c.pollNow()
            expectEqual(c.panels()[0].line("MEM.PRESSURE"), line)
        }
    }

    test("battery level and power source are shown under POWER") {
        let cases: [(PowerStatus, PanelLine)] = [
            (.battery(percent: 87, onAC: false, charging: false), .field("POWER.CELL", "87% BATTERY")),
            (.battery(percent: 18, onAC: false, charging: false), .field("POWER.CELL", "18% BATTERY", .warn)),
            (.battery(percent: 7, onAC: false, charging: false), .field("POWER.CELL", "7% BATTERY", .alert)),
            (.battery(percent: 64, onAC: true, charging: true), .field("POWER.CELL", "64% AC CHARGING", .ok)),
            (.battery(percent: 100, onAC: true, charging: false), .field("POWER.CELL", "100% AC", .ok)),
        ]
        for (status, line) in cases {
            let w = FakeWorld("poll-batt")
            w.power = status
            let c = core(w); c.pollNow()
            let p = c.panels()[0]
            expectEqual(p.line("POWER"), .section("POWER"))
            expectEqual(p.line("POWER.CELL"), line)
        }
    }

    test("a machine without a battery has no power section") {
        let w = FakeWorld("poll-nobatt")
        w.power = .noBattery
        let c = core(w); c.pollNow()
        let p = c.panels()[0]
        expect(p.line("POWER") == nil, "no POWER section expected")
        expect(p.line("POWER.CELL") == nil, "no POWER.CELL line expected")
    }

    test("before the first poll vitals read ACQUIRING and power is omitted") {
        let w = FakeWorld("poll-pending")
        let p = core(w).panels()[0]
        expectEqual(p.line("HOST.VITALS"), .section("HOST.VITALS"))
        expect(p.lines.contains(.text("ACQUIRING", .dim)))
        expect(p.line("LOAD.AVG") == nil)
        expect(p.line("POWER") == nil)
    }

    test("a source that has never succeeded reads NO SIGNAL") {
        let w = FakeWorld("poll-nosignal")
        w.vitalsFail = true
        let c = core(w); c.pollNow()
        expect(c.panels()[0].lines.contains(.text("NO SIGNAL", .dim)))
    }

    // MARK: scheduling policy (through the debug lines, fetch counts, marker)

    test("debug lines are hidden by default and list each source when enabled") {
        let w = FakeWorld("sched-debug")
        let hidden = core(w); hidden.pollNow()
        expect(hidden.panels()[0].line("DEBUG") == nil)
        expect(hidden.panels()[0].line("DBG.VIT") == nil)
        let shown = core(w, debug: true); shown.pollNow()
        let p = shown.panels()[0]
        expectEqual(p.line("DEBUG"), .section("DEBUG"))
        expectEqual(p.line("DBG.VIT"), .field("DBG.VIT", "1.0ms @5s", .dim))
        expectEqual(p.line("DBG.PWR"), .field("DBG.PWR", "2.0ms @60s", .dim))
    }

    test("a fast source runs at its base interval") {
        let w = FakeWorld("sched-base")
        let c = core(w, debug: true)
        c.pollNow()
        expectEqual(w.vitalsCalls, 1)
        w.advance(4.9); c.pollNow()
        expectEqual(w.vitalsCalls, 1)
        w.advance(0.1); c.pollNow()
        expectEqual(w.vitalsCalls, 2)
        expectEqual(w.powerCalls, 1)
        expectEqual(c.panels()[0].value(of: "DBG.VIT"), "1.0ms @5s")
    }

    test("a slow fetch throttles itself to 20x its duration") {
        let w = FakeWorld("sched-throttle")
        w.vitalsDuration = 0.5
        let c = core(w, debug: true)
        c.pollNow()
        expectEqual(c.panels()[0].value(of: "DBG.VIT"), "500ms @10s")
        w.advance(5); c.pollNow()
        expectEqual(w.vitalsCalls, 1)
        w.advance(5); c.pollNow()
        expectEqual(w.vitalsCalls, 2)
        // Faster again: back to the base interval.
        w.vitalsDuration = 0.001
        w.advance(10); c.pollNow()
        expectEqual(c.panels()[0].value(of: "DBG.VIT"), "1.0ms @5s")
    }

    test("failures back off exponentially, capped at 10x base") {
        let w = FakeWorld("sched-backoff")
        w.vitalsFail = true
        let c = core(w, debug: true)
        var seen: [String] = []
        for _ in 0..<6 {
            c.pollNow()
            seen.append(c.panels()[0].value(of: "DBG.VIT") ?? "-")
            let sched = c.panels()[0].value(of: "DBG.VIT") ?? ""
            let interval = Double(sched.split(separator: "@")[1].prefix { $0.isNumber })!
            let before = w.vitalsCalls
            w.advance(interval - 0.01); c.pollNow()
            expectEqual(w.vitalsCalls, before)   // not due during the backoff
            w.advance(0.01)
        }
        expectEqual(seen, ["1.0ms @10s F1", "1.0ms @20s F2", "1.0ms @40s F3",
                           "1.0ms @50s F4", "1.0ms @50s F5", "1.0ms @50s F6"])
        expectEqual(c.panels()[0].line("DBG.VIT")?.severity, .warn)
    }

    test("a success after failures recovers to the base interval and shows data") {
        let w = FakeWorld("sched-recover")
        w.vitalsFail = true
        let c = core(w, debug: true)
        c.pollNow(); w.advance(10)
        c.pollNow(); w.advance(20)
        expectEqual(c.panels()[0].value(of: "DBG.VIT"), "1.0ms @20s F2")
        w.vitalsFail = false
        c.pollNow()
        let p = c.panels()[0]
        expectEqual(p.line("DBG.VIT"), .field("DBG.VIT", "1.0ms @5s", .dim))
        expectEqual(p.value(of: "LOAD.AVG"), "0.42 0.38 0.31")
        w.advance(5); c.pollNow()
        expectEqual(w.vitalsCalls, 4)
    }

    test("staleness marker appears once data is older than 2x the interval") {
        let w = FakeWorld("stale-base")
        let c = core(w)
        c.pollNow()
        w.vitalsFail = true          // keep polling, but nothing new arrives
        w.advance(9.99); c.pollNow() // age ~10s (the fetch adds 1ms) = 2x5s: not yet stale
        expectEqual(c.panels()[0].line("HOST.VITALS"), .section("HOST.VITALS"))
        w.advance(2)                 // age ~12s
        expectEqual(c.panels()[0].line("HOST.VITALS"), .section("HOST.VITALS", marker: "·12s"))
        expectEqual(c.panels()[0].line("HOST.VITALS")?.severity, .dim)
        // Old data stays visible under the marker.
        expectEqual(c.panels()[0].value(of: "LOAD.AVG"), "0.42 0.38 0.31")
        // Fresh data clears it.
        w.vitalsFail = false
        w.advance(30); c.pollNow()
        expectEqual(c.panels()[0].line("HOST.VITALS"), .section("HOST.VITALS"))
    }

    test("staleness threshold follows the throttled interval") {
        let w = FakeWorld("stale-throttle")
        w.vitalsDuration = 0.5        // interval 10s -> stale after 20s
        let c = core(w)
        c.pollNow()
        w.advance(15)
        expectEqual(c.panels()[0].line("HOST.VITALS"), .section("HOST.VITALS"))
        w.advance(6)
        expectEqual(c.panels()[0].line("HOST.VITALS"), .section("HOST.VITALS", marker: "·21s"))
    }

    test("power goes stale on its own 60s interval") {
        let w = FakeWorld("stale-power")
        let c = core(w)
        c.pollNow()
        w.advance(119)
        expectEqual(c.panels()[0].line("POWER"), .section("POWER"))
        w.advance(5)
        expectEqual(c.panels()[0].line("POWER"), .section("POWER", marker: "·2m"))
    }

    test("schedule state round-trips through JSON (collector state file)") {
        var s = SourceSchedule(baseInterval: 300)
        let t = Date(timeIntervalSince1970: 1_795_271_405)
        s.recordSuccess(at: t, duration: 2.5)
        s.recordFailure(at: t.addingTimeInterval(300), duration: 0.4)
        let data = try JSONEncoder().encode(["usage": s])
        let back = try JSONDecoder().decode([SourceID: SourceSchedule].self, from: data)
        expectEqual(back["usage"], s)
        expect(back["usage"]!.isDue(now: t.addingTimeInterval(300 + 600)))
        expect(!back["usage"]!.isDue(now: t.addingTimeInterval(300 + 599)))
    }

    test("flavour lines: scrolling hex and a status readout") {
        let w = FakeWorld("flavour")
        let c = core(w)
        let a = c.panels()[0].lines.filter { $0.style == .text }.map(\.label)
        w.advance(1)
        let b = c.panels()[0].lines.filter { $0.style == .text }.map(\.label)
        expect(a.contains("TRACE PROGRAM: INACTIVE") || a.contains { $0.contains("INTEGRITY") }
               || a.contains { $0.contains("SIGNAL") || $0.contains("ZION") }, "readout present: \(a)")
        let hexA = a.first { $0.allSatisfy { "0123456789ABCDEF ".contains($0) } }
        let hexB = b.first { $0.allSatisfy { "0123456789ABCDEF ".contains($0) } }
        expect(hexA != nil && hexA != hexB, "hex line scrolls")
        expectEqual(hexA?.count, 34)
    }
}
