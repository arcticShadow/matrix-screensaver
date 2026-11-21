//
//  Network.swift
//  The trusted-network rule. Real names (repo names, calendar titles) are
//  shown only when the current Wi-Fi name is readable AND in the config's
//  `trustedSSIDs`. Everything else fails closed.
//
//  - `WiFiReader.currentSSID`: the live reader (SCDynamicStore). Undocumented
//    source, so any failure is nil (= unreadable).
//  - `WiFiStatus`: what the poller stores. Never prints the name.
//  - `NetworkTrust.decide`: the pure decision the core applies.
//

import Foundation
import SystemConfiguration

/// The poller's Wi-Fi sample. `ssid == nil` means unreadable (Wi-Fi off,
/// wired, not associated, OS redaction, decode failure).
struct WiFiStatus: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var ssid: String?

    var readable: Bool { !(ssid ?? "").isEmpty }

    // The name must never reach a log, a crash report or a test failure message.
    var description: String { readable ? "WiFiStatus(readable)" : "WiFiStatus(unreadable)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["readable": readable]) }
}

enum NetworkTrust: Equatable {
    /// Wi-Fi name readable and in `trustedSSIDs`: real names may be shown.
    case trusted
    /// Name readable but not trusted, or no trusted list configured: codenames.
    case untrusted
    /// Name unreadable, read failing, stale or not read yet: codenames plus
    /// the `NET: UNVERIFIED` tag.
    case unverified

    var isTrusted: Bool { self == .trusted }

    /// `trusted` / `untrusted` / `unverified`: the decision only, safe to log.
    var label: String {
        switch self {
        case .trusted: return "trusted"
        case .untrusted: return "untrusted"
        case .unverified: return "unverified"
        }
    }

    /// - Parameters:
    ///   - wifi: the latest Wi-Fi sample (nil = never read).
    ///   - current: false when the reading can't be relied on any more (the
    ///     last read failed, or the sample is older than 2× its poll interval).
    static func decide(trustedSSIDs: [String], wifi: WiFiStatus?, current: Bool) -> NetworkTrust {
        let trusted = Set(trustedSSIDs.filter { !$0.isEmpty })
        // No list: always codenames. The Wi-Fi state is irrelevant, so no tag.
        guard !trusted.isEmpty else { return .untrusted }
        guard current, let w = wifi, w.readable, let ssid = w.ssid else { return .unverified }
        return trusted.contains(ssid) ? .trusted : .untrusted
    }
}

enum WiFiReader {
    /// Classes allowed in the cached scan record archive (secure decoding).
    private static let archiveClasses: [AnyClass] = [NSDictionary.self, NSString.self, NSData.self,
                                                     NSNumber.self, NSArray.self, NSDate.self]

    /// The current Wi-Fi name, or nil when it can't be read. Never log it.
    ///
    /// `State:/Network/Interface/<if>/AirPort` holds a redacted top-level
    /// SSID, but its `CachedScanRecord` (an NSKeyedArchiver dictionary)
    /// carries `SSID_STR`. The Wi-Fi interface comes from the `Setup:` AirPort
    /// keys (never hardcode en0; `State:` also lists awdl0, which has no record).
    static func currentSSID() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "law.jude.SolarizedMatrix" as CFString, nil, nil) else {
            return nil
        }
        func interfaces(_ pattern: String) -> [String] {
            let keys = (SCDynamicStoreCopyKeyList(store, pattern as CFString) as? [String]) ?? []
            return keys.compactMap { k in
                let p = k.split(separator: "/")
                return p.count == 5 ? String(p[3]) : nil
            }
        }
        var ifs = interfaces("Setup:/Network/Interface/[^/]+/AirPort")
        if ifs.isEmpty { ifs = interfaces("State:/Network/Interface/[^/]+/AirPort") }
        for name in ifs.sorted() {
            guard let dict = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(name)/AirPort" as CFString)
                    as? [String: Any],
                  (dict["Power Status"] as? NSNumber)?.intValue != 0,   // radio off: record may linger
                  let data = dict["CachedScanRecord"] as? Data,
                  let obj = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: archiveClasses, from: data),
                  let rec = obj as? [String: Any] else { continue }
            if let s = rec["SSID_STR"] as? String, !s.isEmpty { return s }
            if let raw = rec["SSID"] as? Data, let s = String(data: raw, encoding: .utf8), !s.isEmpty { return s }
        }
        return nil
    }
}
