//
//  CollectorState.swift
//  The collector's JSON state file: the ONE schema shared by the collector
//  (writer, Collector/) and the saver (reader, every 5 s on the poller).
//  Compiled into both executables. UI-free, Foundation only.
//
//  Path: ~/.local/state/matrix-diag/collector-state.json (real home).
//  Written atomically (temp file in the same directory + rename), so a reader
//  sees either the old file or the new one, never a partial one.
//
//  Layout (schema 1):
//    { "schema": 1, "generatedAt": <date>,
//      "schedules": { "<SourceID>": SourceSchedule, ... },   // collector's adaptive policy state
//      "usage": { "generatedAt": <date>, "accounts": [AccountUsage, ...] },
//      "refresh": { "sessions": [RefreshSession, ...] },       // #10, optional
//      "calendar": { "generatedAt": <date>, "events": [CalendarEvent, ...] } }  // #11, optional
//  Each section carries its own generatedAt (time of its last successful
//  fetch) and each account its own. Later tickets add sibling sections
//  (calendar, refresh sessions) as optional members: old readers ignore
//  unknown keys, so adding a section never needs a schema bump.
//
//  Account folder names live only in this local file (`dir`, the config dir
//  basename) so the saver can map them to profile tags; they are never
//  logged or drawn.
//

import Foundation

struct CollectorState: Codable, Equatable {
    static let currentSchema = 1

    var schema: Int = CollectorState.currentSchema
    /// End of the collector run that wrote this file.
    var generatedAt: Date? = nil
    /// The collector's per-source scheduling state, persisted between its
    /// 60 s launchd runs. The saver reads it for staleness.
    var schedules: [SourceID: SourceSchedule] = [:]
    var usage: UsageSection? = nil
    /// The collector's own `claude -p` token-refresh runs. The saver hides
    /// these session ids from the AGENTS panel.
    var refresh: RefreshSection? = nil
    /// Upcoming events from `gws calendar +agenda` (#11).
    var calendar: CalendarSection? = nil

    init(schema: Int = CollectorState.currentSchema, generatedAt: Date? = nil,
         schedules: [SourceID: SourceSchedule] = [:], usage: UsageSection? = nil,
         refresh: RefreshSection? = nil, calendar: CalendarSection? = nil) {
        self.schema = schema
        self.generatedAt = generatedAt
        self.schedules = schedules
        self.usage = usage
        self.refresh = refresh
        self.calendar = calendar
    }

    /// Session ids the AGENTS panel must never show or count.
    var hiddenSessionIDs: Set<String> { Set((refresh?.sessions ?? []).map(\.sessionId)) }
}

struct RefreshSection: Codable, Equatable {
    /// Recent refresh runs (pruned after a week), oldest first.
    var sessions: [RefreshSession]
}

struct RefreshSession: Codable, Equatable {
    /// The id passed to `claude --session-id`, recorded before launch.
    var sessionId: String
    /// Config dir basename of the refreshed account. Local file only.
    var dir: String
    var startedAt: Date
    var finishedAt: Date? = nil
    /// "running", "ok", "exit <status>", "timeout" or "launch failed".
    var outcome: String? = nil
}

/// Source ids the collector registers (keys of `CollectorState.schedules`).
enum CollectorSourceIDs {
    static let usage: SourceID = "USAGE"
    static let calendar: SourceID = "CALENDAR"
}

struct CalendarSection: Codable, Equatable {
    /// Last successful agenda fetch; nil = never succeeded (see lastError).
    var generatedAt: Date?
    /// Events from now to the end of the agenda window, by start time. Titles
    /// live only in this local file; the saver shows them on trusted networks only.
    var events: [CalendarEvent]
    /// Short, non-sensitive category of the last failure (`AUTH`, `EXIT 2`,
    /// `TIMEOUT`, `PARSE`, `NO GWS`); nil after a success.
    var lastError: String? = nil
}

struct CalendarEvent: Codable, Equatable {
    var summary: String
    var start: Date
    var end: Date
    /// All-day events (a bare `YYYY-MM-DD` start) are kept but never shown.
    var allDay: Bool
}

struct UsageSection: Codable, Equatable {
    /// Last successful usage run.
    var generatedAt: Date?
    /// One per discovered `~/.claude*` config dir, sorted (`.claude` first).
    var accounts: [AccountUsage]
}

struct AccountUsage: Codable, Equatable {
    enum TokenState: String, Codable, Equatable {
        /// Token present and (as far as we know) valid.
        case ok
        /// Token past its expiry, or rejected (401) by the usage endpoint.
        /// The data shown is whatever was last fetched: STALE.
        case expired
        /// No keychain item for this config dir.
        case none
        /// Keychain read failed for another reason.
        case error
    }

    /// Config dir basename, e.g. ".claude". Local file only; never shown.
    var dir: String
    var token: TokenState
    /// The access token's expiry (from the keychain item), if known.
    var tokenExpiresAt: Date? = nil
    /// Last successful usage fetch for this account.
    var generatedAt: Date? = nil
    var fiveHour: UsageWindow? = nil
    var sevenDay: UsageWindow? = nil
    var extra: ExtraUsage? = nil
    /// Short, non-sensitive category of the last failure (`HTTP 503`,
    /// `NETWORK`, `PARSE`, `KEYCHAIN`); nil after a success.
    var lastError: String? = nil
}

struct UsageWindow: Codable, Equatable {
    /// Percent, 0–100 (the endpoint's own scale, verified live).
    var utilization: Double
    var resetsAt: Date?
}

struct ExtraUsage: Codable, Equatable {
    var enabled: Bool
    /// Amounts in minor units of `currency`; divide by 10^decimalPlaces.
    var usedMinor: Double?
    /// nil = no monthly limit set.
    var limitMinor: Double?
    var currency: String
    var decimalPlaces: Int
}

enum CollectorStateStore {
    static let relativePath = ".local/state/matrix-diag/collector-state.json"

    static func defaultPath(home: String) -> String {
        (home as NSString).appendingPathComponent(relativePath)
    }

    // ISO-8601 with milliseconds: readable, and precise enough that the
    // persisted schedule round-trips (sub-second fetch durations).
    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    static func encode(_ state: CollectorState) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let f = formatter()
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        return try enc.encode(state)
    }

    static func decode(_ data: Data) throws -> CollectorState {
        let dec = JSONDecoder()
        let f = formatter()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let d = f.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date")
            }
            return d
        }
        let state = try dec.decode(CollectorState.self, from: data)
        guard state.schema <= CollectorState.currentSchema else {
            throw ReaderError(description: "collector state schema \(state.schema) is newer than this build")
        }
        return state
    }

    /// nil when the file doesn't exist; throws when it exists but can't be decoded.
    static func load(path: String) throws -> CollectorState? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try decode(data)
    }
}
