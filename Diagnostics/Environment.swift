//
//  Environment.swift
//  Everything the diagnostics core reads from the outside world, injected.
//  Tests build a fake one rooted at a scratch home dir with a settable clock;
//  the saver uses `.live()`. New data sources (Wi-Fi, liveness, ...) should be
//  added here as injectable members rather than called directly.
//

import Foundation
import Darwin

struct DiagnosticsEnvironment {
    var now: () -> Date
    /// The user's REAL home (passwd entry). The sandboxed saver host's
    /// NSHomeDirectory() is its container, so never use that.
    var homeDirectory: String
    var configPath: String
    var bootTime: Date
    var timeZone: () -> TimeZone

    static func live() -> DiagnosticsEnvironment {
        let home = realHomeDirectory()
        return DiagnosticsEnvironment(now: Date.init,
                                      homeDirectory: home,
                                      configPath: ConfigLoader.defaultPath(home: home),
                                      bootTime: systemBootTime() ?? Date(),
                                      timeZone: { TimeZone.current })
    }
}

/// Home directory from the passwd database (getpwuid), immune to sandbox
/// container redirection and to $HOME. Falls back to NSHomeDirectory().
func realHomeDirectory() -> String {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        let s = String(cString: dir)
        if !s.isEmpty { return s }
    }
    return NSHomeDirectory()
}

/// kern.boottime via sysctl.
func systemBootTime() -> Date? {
    var tv = timeval()
    var size = MemoryLayout<timeval>.stride
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
}
