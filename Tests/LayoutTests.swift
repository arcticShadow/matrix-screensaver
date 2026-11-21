//
//  LayoutTests.swift — clockwise burn-in rotation of the panel corners,
//  driven through the core's layout() with an injected clock.
//

import Foundation

/// The start of a rotation cycle (step 0) near the fixture date.
private func cycleStart(_ interval: TimeInterval) -> Date {
    let t = 1_795_271_405.0
    return Date(timeIntervalSince1970: (t / (4 * interval)).rounded(.down) * 4 * interval)
}

private func corners(_ core: DiagnosticsCore) -> [String: PanelCorner] {
    Dictionary(uniqueKeysWithValues: core.layout().map { ($0.panel.title, $0.corner) })
}

func layoutTests() {
    test("rotation: the default interval is about 10 minutes") {
        expectEqual(PanelRotation().interval, 600)
        let w = FakeWorld("rot-default")
        expectEqual(DiagnosticsCore(env: w.env, polling: .manual).rotation.interval, 600)
    }

    test("rotation: initial corners are SYS top-left, AGENTS bottom-right") {
        let w = FakeWorld("rot-initial", now: cycleStart(600))
        let core = DiagnosticsCore(env: w.agentsEnv(), polling: .manual)
        expectEqual(corners(core), ["SYS": .topLeft, "AGENTS": .bottomRight])
        w.advance(599)   // still inside the first interval
        expectEqual(corners(core), ["SYS": .topLeft, "AGENTS": .bottomRight])
    }

    test("rotation: both panels step one corner clockwise after each interval, back to the start") {
        let w = FakeWorld("rot-cycle", now: cycleStart(600))
        let core = DiagnosticsCore(env: w.agentsEnv(), polling: .manual)
        var sys: [PanelCorner] = [], agents: [PanelCorner] = []
        for _ in 0...4 {
            let c = corners(core)
            sys.append(c["SYS"]!); agents.append(c["AGENTS"]!)
            w.advance(600)
        }
        expectEqual(sys, [.topLeft, .topRight, .bottomRight, .bottomLeft, .topLeft])
        expectEqual(agents, [.bottomRight, .bottomLeft, .topLeft, .topRight, .bottomRight])
    }

    test("rotation: the two panels are always diagonally opposite") {
        let w = FakeWorld("rot-opposite", now: cycleStart(600))
        let core = DiagnosticsCore(env: w.agentsEnv(), polling: .manual)
        var seen = Set<String>()
        for _ in 0..<40 {   // 40 x 97 s spans several intervals at odd offsets
            let c = corners(core)
            expectEqual(c["AGENTS"], c["SYS"]?.opposite)
            expect(c["SYS"]?.isTop != c["AGENTS"]?.isTop && c["SYS"]?.isLeft != c["AGENTS"]?.isLeft,
                   "\(c) not diagonal")
            seen.insert("\(c["SYS"]!)")
            w.advance(97)
        }
        expectEqual(seen.count, 4)
    }

    test("rotation: a shortened interval rotates on its own cadence") {
        let w = FakeWorld("rot-short", now: cycleStart(5))
        let core = DiagnosticsCore(env: w.agentsEnv(), polling: .manual)
        core.rotation = PanelRotation(interval: 5)
        expectEqual(corners(core)["SYS"], .topLeft)
        w.advance(5)
        expectEqual(corners(core)["SYS"], .topRight)
        w.advance(10)
        expectEqual(corners(core)["SYS"], .bottomLeft)
    }

    test("rotation: the AGENTS line budget is asked for AGENTS' current corner") {
        let w = FakeWorld("rot-capacity", now: cycleStart(600))
        for i in 1...30 { w.writeSession(FakeSession(pid: Int32(i), cwd: "/r/\(i)", status: "busy")) }
        let core = DiagnosticsCore(env: w.agentsEnv(), polling: .manual)
        core.pollNow()
        let budget: [PanelCorner: Int] = [.topLeft: 12, .topRight: 20, .bottomRight: 9, .bottomLeft: 16]
        for _ in 0..<4 {
            var asked: [PanelCorner] = []
            let placed = core.layout { asked.append($0); return budget[$0]! }
            let agents = placed.first { $0.panel.title == "AGENTS" }!
            expectEqual(asked, [agents.corner])
            expectEqual(agents.panel.lines.count, budget[agents.corner]!)
            w.advance(600)
        }
    }
}
