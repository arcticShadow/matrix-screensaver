//
//  Flavour.swift
//  Film-atmosphere lines for the SYS panel: a scrolling hex stream and a
//  rotating status readout. Pure functions of the clock (no randomness), so
//  they animate on screen and stay deterministic in tests and snapshots.
//

import Foundation

enum Flavour {
    static let width = 34

    /// A fixed pseudo-random hex tape (LCG), scrolled by the clock.
    private static let tape: [Character] = {
        var x: UInt32 = 0x5EED_1999
        let digits = Array("0123456789ABCDEF")
        return (0..<512).map { i in
            if i % 5 == 4 { return " " }
            x = x &* 1_664_525 &+ 1_013_904_223
            return digits[Int(x >> 28)]
        }
    }()

    private static let readouts = [
        "TRACE PROGRAM: INACTIVE",
        "SECTOR 7G INTEGRITY %@",
        "CARRIER SIGNAL: LOCKED",
        "ZION MAINFRAME: NO ROUTE",
    ]

    static func lines(now: Date) -> [String] {
        let t = now.timeIntervalSince1970
        let offset = Int((t * 6).rounded(.down)) % tape.count
        let hex = String((0..<width).map { tape[(offset + $0) % tape.count] })
        let slot = Int(t / 20) % readouts.count
        var readout = readouts[slot]
        if readout.contains("%@") {
            let integrity = 97.0 + Double(Int(t / 20) % 29) / 10
            readout = readout.replacingOccurrences(of: "%@", with: String(format: "%.1f%%", integrity))
        }
        return [hex, readout]
    }
}
