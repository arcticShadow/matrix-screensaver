//
//  SysPanelTests.swift — the SYS panel model seam: injected clock/boot time in,
//  Panel value out. Asserts on what the panel says, never on drawing.
//

import Foundation

/// 2026-11-21 14:30:05 UTC (a Saturday).
private let fixedNow = Date(timeIntervalSince1970: 1_795_271_405)
private let utc = TimeZone(identifier: "UTC")!

private func sys(now: Date = fixedNow,
                 bootAgo: TimeInterval = 3600,
                 saverAgo: TimeInterval = 60,
                 tz: TimeZone = utc) -> Panel {
    SysPanel.build(SysInputs(now: now,
                             bootTime: now.addingTimeInterval(-bootAgo),
                             saverStart: now.addingTimeInterval(-saverAgo),
                             timeZone: tz))
}

func sysPanelTests() {
    test("SYS panel shows clock and date from the injected clock") {
        let p = sys()
        expectEqual(p.title, "SYS")
        expectEqual(p.value(of: "SYS.CLOCK"), "14:30:05")
        expectEqual(p.value(of: "SYS.DATE"), "2026-11-21 SAT")
    }

    test("clock and date follow the injected time zone") {
        let p = sys(tz: TimeZone(secondsFromGMT: 13 * 3600)!)
        expectEqual(p.value(of: "SYS.CLOCK"), "03:30:05")
        expectEqual(p.value(of: "SYS.DATE"), "2026-11-22 SUN")
    }

    test("construct (system) uptime of several days reads 4d 03:12") {
        let p = sys(bootAgo: 4 * 86400 + 3 * 3600 + 12 * 60 + 59)
        expectEqual(p.value(of: "CONSTRUCT.UPTIME"), "4d 03:12")
    }

    test("uptime under a day shows hh:mm:ss") {
        expectEqual(sys(bootAgo: 3 * 3600 + 12 * 60 + 45).value(of: "CONSTRUCT.UPTIME"), "03:12:45")
        expectEqual(sys(saverAgo: 125).value(of: "SAVER.UPTIME"), "00:02:05")
    }

    test("uptime rolls over into days at 24h") {
        expectEqual(sys(bootAgo: 86399).value(of: "CONSTRUCT.UPTIME"), "23:59:59")
        expectEqual(sys(bootAgo: 86400).value(of: "CONSTRUCT.UPTIME"), "1d 00:00")
        expectEqual(sys(saverAgo: 86400 * 2 + 61).value(of: "SAVER.UPTIME"), "2d 00:01")
    }

    test("a start time in the future (clock skew) reads as zero, not negative") {
        expectEqual(sys(saverAgo: -30).value(of: "SAVER.UPTIME"), "00:00:00")
    }

    test("SYS panel layout: clock, date, rule, both uptimes") {
        expectEqual(sys(bootAgo: 90, saverAgo: 5).lines, [
            .field("SYS.CLOCK", "14:30:05"),
            .field("SYS.DATE", "2026-11-21 SAT"),
            .rule,
            .field("CONSTRUCT.UPTIME", "00:01:30"),
            .field("SAVER.UPTIME", "00:00:05"),
        ])
    }
}
