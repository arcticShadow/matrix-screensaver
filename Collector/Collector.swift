//
//  Collector.swift
//  The collector's run loop, independent of where its inputs come from:
//
//      load state  ->  select due sources  ->  fetch each  ->  atomic write
//
//  Sources are pluggable (`CollectorSource`); each owns one section of the
//  shared `CollectorState` (Diagnostics/CollectorState.swift) and is scheduled
//  by the shared `SourceSchedule` policy, persisted in the state file.
//  Everything external (clock, home, keychain, HTTP, log) comes in through
//  `CollectorContext`, so tests drive it with fakes; main.swift wires the
//  live implementations (LiveDeps.swift).
//

import Foundation

struct HTTPRequest: Equatable {
    var method = "GET"
    var url: String
    var headers: [String: String] = [:]
}

struct HTTPResponse {
    var status: Int
    var body: Data
}

enum KeychainRead: Equatable {
    case found(String)
    /// `security` exit 44: no such item.
    case notFound
    /// Any other failure (exit status).
    case failed(Int32)
}

/// Everything a source may touch. Tests inject fakes for all of it.
struct CollectorContext {
    var now: () -> Date
    /// The user's real home (passwd entry).
    var home: String
    var config: DiagConfig
    /// Generic-password lookup by service name. Live: /usr/bin/security.
    var readKeychain: (String) -> KeychainRead
    /// Live: URLSession behind an allowlist (usage endpoint only).
    var http: (HTTPRequest) throws -> HTTPResponse
    var userAgent: String
    var log: CollectorLog

    // Child processes (#10 token refresh). Defaults make a context that can
    // never launch anything.
    /// Login name (passwd), passed to children as USER/LOGNAME.
    var user: String = ""
    /// The collector's own environment, the base for children's.
    var environment: [String: String] = [:]
    /// Resolved `claude` binary (BinaryResolver), nil when not installed.
    var claudePath: String? = nil
    /// Live: Foundation.Process with a timeout (LiveProcess).
    var runProcess: (ProcessSpec) throws -> ProcessResult = { _ in throw ProcessSpec.NoRunner() }
    var newSessionID: () -> String = { UUID().uuidString.lowercased() }
    var sleep: (TimeInterval) -> Void = { _ in }
    /// Persist `state` now (mid-run). Collector.run wires it to the atomic writer.
    var checkpoint: (CollectorState) -> Void = { _ in }

    // Calendar (#11).
    /// Resolved `gws` binary (BinaryResolver), nil when not installed.
    var gwsPath: String? = nil
    /// Runs the agenda command and captures stdout. Live: LiveProcess.capture.
    /// Tests inject a fake: the real gws is never run from tests.
    var runAgenda: (ProcessSpec) throws -> ProcessOutput = { _ in throw ProcessSpec.NoRunner() }
}

/// A child process to run: absolute executable, explicit environment.
struct ProcessSpec: Equatable {
    struct NoRunner: Error {}
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: String
    /// Seconds before the child is terminated.
    var timeout: TimeInterval
}

struct ProcessResult: Equatable {
    var status: Int32
    var timedOut: Bool
}

/// A finished child whose stdout was captured (stderr is discarded).
struct ProcessOutput: Equatable {
    var status: Int32
    var timedOut: Bool
    var stdout: Data
}

/// One collector data source. `fetch` updates its own section of `state`
/// and throws to report a failed run (which drives backoff). It may leave
/// partial progress in `state` (e.g. per-account errors) before throwing.
protocol CollectorSource {
    var id: SourceID { get }
    var baseInterval: TimeInterval { get }
    func fetch(_ state: inout CollectorState, _ ctx: CollectorContext) throws
}

struct CollectorRunReport: Equatable {
    var ran: [SourceID] = []
    var skipped: [SourceID] = []
    var failed: [SourceID] = []
    var wrote = false
}

enum Collector {
    /// One collector run. `force` ignores the schedule (manual runs).
    /// `write` is the atomic writer (injectable to test write failures).
    @discardableResult
    static func run(statePath: String,
                    sources: [CollectorSource],
                    ctx: CollectorContext,
                    force: Bool = false,
                    write: @escaping (Data, String) throws -> Void = { try AtomicFile.write($0, to: $1) }) -> CollectorRunReport {
        var report = CollectorRunReport()
        var ctx = ctx
        let log = ctx.log
        ctx.checkpoint = { s in
            do { try write(try CollectorStateStore.encode(s), statePath) } catch {
                log.error("state checkpoint failed: \(error)")
            }
        }
        var state: CollectorState
        do {
            state = try CollectorStateStore.load(path: statePath) ?? CollectorState()
        } catch {
            ctx.log.error("state file unreadable (\(type(of: error))); starting fresh")
            state = CollectorState()
        }

        for src in sources {
            var sched = state.schedules[src.id] ?? SourceSchedule(baseInterval: src.baseInterval)
            // The registry, not the file, owns the base interval.
            sched.baseInterval = src.baseInterval
            guard force || sched.isDue(now: ctx.now()) else {
                report.skipped.append(src.id)
                state.schedules[src.id] = sched
                continue
            }
            report.ran.append(src.id)
            let wasFailing = sched.consecutiveFailures > 0
            let start = ctx.now()
            do {
                try src.fetch(&state, ctx)
                let end = ctx.now()
                sched.recordSuccess(at: end, duration: end.timeIntervalSince(start))
                if wasFailing { ctx.log.change("\(src.id) source recovered") }
            } catch {
                let end = ctx.now()
                sched.recordFailure(at: end, duration: end.timeIntervalSince(start))
                report.failed.append(src.id)
                ctx.log.error("\(src.id) source failed (\(sched.consecutiveFailures)x): \(error); "
                              + "next try in \(Int(sched.effectiveInterval))s")
            }
            state.schedules[src.id] = sched
        }

        state.schema = CollectorState.currentSchema
        state.generatedAt = ctx.now()
        do {
            let fileExisted = FileManager.default.fileExists(atPath: statePath)
            try write(try CollectorStateStore.encode(state), statePath)
            report.wrote = true
            if !fileExisted { ctx.log.change("state file created") }
        } catch {
            ctx.log.error("state write failed: \(error)")
        }
        return report
    }
}

/// Write-then-rename in the destination directory: readers see the old file
/// or the new one, never a partial file. The temp file is removed on failure.
enum AtomicFile {
    static func write(_ data: Data, to path: String,
                      beforeRename: () throws -> Void = {}) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = (dir as NSString).appendingPathComponent(
            ".\((path as NSString).lastPathComponent).tmp-\(getpid())-\(UUID().uuidString.prefix(8))")
        do {
            guard FileManager.default.createFile(atPath: tmp, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw ReaderError(description: "cannot create temp file")
            }
            try beforeRename()
            guard rename(tmp, path) == 0 else {
                throw ReaderError(description: "rename failed (errno \(errno))")
            }
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            throw error
        }
    }
}
