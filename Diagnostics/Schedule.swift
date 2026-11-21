//
//  Schedule.swift
//  The adaptive scheduling policy, as a pure Codable value: one per data
//  source. Shared by the saver's background poller and (ticket #9) the
//  collector, which persists a [SourceID: SourceSchedule] in its JSON state
//  file between its 60 s launchd runs. No clocks, threads or I/O in here:
//  callers pass `now` and the measured fetch duration.
//
//    refresh   = max(base, 20 × last fetch duration)      (throttle slow fetches to ≲5% wall time)
//    effective = refresh                                   after a success
//              = max(min(base × 2^failures, 10 × base), 20 × last duration)   while failing
//    stale     = data age > 2 × refresh
//
//  Staleness deliberately uses the un-backed-off refresh interval, so a
//  failing source shows its staleness marker instead of hiding behind its
//  own backoff.
//

import Foundation

typealias SourceID = String

struct SourceSchedule: Codable, Equatable {
    static let throttleFactor: Double = 20
    static let maxBackoffMultiple: Double = 10
    static let staleFactor: Double = 2

    /// The source's base interval. The collector should overwrite a persisted
    /// value with its current registry's base on load.
    var baseInterval: TimeInterval
    /// Duration of the most recent fetch attempt (success or failure).
    var lastDuration: TimeInterval = 0
    var consecutiveFailures: Int = 0
    /// End of the most recent attempt; nil = never fetched (due immediately).
    var lastAttempt: Date? = nil
    /// End of the most recent successful fetch (the data's timestamp).
    var lastSuccess: Date? = nil

    init(baseInterval: TimeInterval) { self.baseInterval = baseInterval }

    /// The interval this source runs at when healthy.
    var refreshInterval: TimeInterval {
        max(baseInterval, Self.throttleFactor * lastDuration)
    }

    /// The interval until the next attempt, including failure backoff.
    var effectiveInterval: TimeInterval {
        guard consecutiveFailures > 0 else { return refreshInterval }
        let backoff = min(baseInterval * pow(2, Double(min(consecutiveFailures, 30))),
                          Self.maxBackoffMultiple * baseInterval)
        return max(backoff, Self.throttleFactor * lastDuration)
    }

    var nextDue: Date? { lastAttempt.map { $0.addingTimeInterval(effectiveInterval) } }

    func isDue(now: Date) -> Bool { nextDue.map { now >= $0 } ?? true }

    mutating func recordSuccess(at end: Date, duration: TimeInterval) {
        lastDuration = max(0, duration)
        consecutiveFailures = 0
        lastAttempt = end
        lastSuccess = end
    }

    mutating func recordFailure(at end: Date, duration: TimeInterval) {
        lastDuration = max(0, duration)
        consecutiveFailures += 1
        lastAttempt = end
    }

    /// Age of the last good data, nil if there has never been any.
    func dataAge(now: Date) -> TimeInterval? { lastSuccess.map { max(0, now.timeIntervalSince($0)) } }

    /// True once the last good data is older than 2× the refresh interval.
    func isStale(now: Date) -> Bool {
        guard let age = dataAge(now: now) else { return false }
        return age > Self.staleFactor * refreshInterval
    }
}
