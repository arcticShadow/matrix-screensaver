//
//  Sessions.swift
//  Claude Code session discovery: every `~/.claude*` DIRECTORY under the real
//  home that has a `sessions/` dir; in it, only canonical `<pid>.json` files
//  (the `<pid>.<hash>.key` files, dotfiles and anything else are skipped).
//
//  Runs on the poller's background queue (sessions source, every 2 s). The
//  liveness check (proc_pidinfo) happens here too, so the render thread never
//  makes syscalls. Private free text (`name`, `formerNames`, the `waitingFor`
//  command) never leaves this file: `waitingFor` is reduced to a category in
//  `WaitCategory.parse` and the raw string is dropped.
//

import Foundation
import Darwin

/// What a waiting session is blocked on. Only this category is kept.
enum WaitCategory: Equatable {
    /// `approve <Tool>[: …]` (tool name uppercased, capped; `mcp__…` tools → MCP).
    case approveTool(String)
    case approvePlan
    /// Generic permission / sandbox / worker request (no tool name available).
    case approve
    case inputNeeded
    /// Anything else, including empty or missing.
    case attention

    /// Panel text: `APPROVE BASH`, `APPROVE PLAN`, `APPROVE`, `INPUT NEEDED`, `ATTENTION`.
    var label: String {
        switch self {
        case let .approveTool(t): return "APPROVE " + t
        case .approvePlan: return "APPROVE PLAN"
        case .approve: return "APPROVE"
        case .inputNeeded: return "INPUT NEEDED"
        case .attention: return "ATTENTION"
        }
    }

    static let maxToolLength = 10

    /// Orchestrator mapping (see #4 comment). Text after the tool name is
    /// never retained.
    static func parse(_ raw: String?) -> WaitCategory {
        let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s == "approve plan" { return .approvePlan }
        if s.hasPrefix("approve ") {
            let rest = s.dropFirst("approve ".count)
            let tool = rest.prefix { $0 != ":" && $0 != " " }
            guard !tool.isEmpty else { return .approve }
            if tool.hasPrefix("mcp__") { return .approveTool("MCP") }
            let clean = tool.filter { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !clean.isEmpty else { return .approve }
            return .approveTool(String(clean.uppercased().prefix(maxToolLength)))
        }
        if ["permission prompt", "sandbox request", "worker request"].contains(s) { return .approve }
        if ["input needed", "dialog open", "goal proposal"].contains(s) || s.contains("elicit") {
            return .inputNeeded
        }
        return .attention
    }
}

/// One session file, reduced to what the panels need.
struct SessionRecord: Equatable {
    var pid: Int32
    var sessionId: String
    /// The session's working directory (worktrees: their own path). Used only
    /// to derive the display name and to count repos; never shown as is.
    var cwd: String
    /// Basename of the owning config dir (`.claude`, `.claude-xyz`); mapped to
    /// a profile tag before display, never shown as is.
    var configDir: String
    var kind: String
    var entrypoint: String
    var status: String
    /// Only set when status == waiting.
    var waitCategory: WaitCategory?
    /// When the status last changed (statusUpdatedAt, else updatedAt).
    var statusSince: Date?
    var startedAt: Date?
    /// Process exists and its start time matches procStart.
    var alive: Bool
}

struct SessionScan: Equatable {
    var sessions: [SessionRecord] = []
    /// Config dirs that have a sessions/ dir.
    var configDirs: [String] = []
    /// Session files skipped because they didn't parse.
    var unreadable: Int = 0
}

/// pid, procStart (UTC `ps -o lstart` text) -> alive with that start time.
typealias LivenessChecker = (Int32, String?) -> Bool

enum SessionReader {
    struct SignalLost: Error, CustomStringConvertible { var description: String }

    /// Scan every `~/.claude*` config dir. Throws (→ AGENT.LINK: SIGNAL LOST)
    /// when the home or a sessions dir can't be listed, or when session files
    /// exist but none of them parse (a format change must never read as zero).
    static func scan(home: String, isAlive: LivenessChecker) throws -> SessionScan {
        let fm = FileManager.default
        let entries: [String]
        do { entries = try fm.contentsOfDirectory(atPath: home) } catch {
            throw SignalLost(description: "home not listable")
        }
        var scan = SessionScan()
        var candidates = 0
        for dir in entries.sorted() where dir == ".claude" || dir.hasPrefix(".claude") {
            var isDir: ObjCBool = false
            let sessions = "\(home)/\(dir)/sessions"
            guard fm.fileExists(atPath: "\(home)/\(dir)", isDirectory: &isDir), isDir.boolValue,
                  fm.fileExists(atPath: sessions, isDirectory: &isDir), isDir.boolValue else { continue }
            scan.configDirs.append(dir)
            let files: [String]
            do { files = try fm.contentsOfDirectory(atPath: sessions) } catch {
                throw SignalLost(description: "sessions dir not listable")
            }
            for f in files.sorted() where f.hasSuffix(".json") && !f.hasPrefix(".") {
                let stem = String(f.dropLast(5))
                guard let pid = Int32(stem), String(pid) == stem, pid > 0 else { continue }
                candidates += 1
                guard let data = fm.contents(atPath: "\(sessions)/\(f)"),
                      let rec = parse(data, pid: pid, configDir: dir, isAlive: isAlive) else {
                    scan.unreadable += 1
                    continue
                }
                scan.sessions.append(rec)
            }
        }
        if candidates > 0, scan.sessions.isEmpty {
            throw SignalLost(description: "no session file parsed")
        }
        return scan
    }

    /// Required: pid (matching the file name), cwd, status. Everything else is
    /// optional (the format is internal and varies between versions).
    static func parse(_ data: Data, pid: Int32, configDir: String,
                      isAlive: LivenessChecker) -> SessionRecord? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let p = (obj["pid"] as? NSNumber)?.int32Value, p == pid,
              let cwd = obj["cwd"] as? String,
              let status = obj["status"] as? String else { return nil }
        let ms = { (k: String) -> Date? in
            (obj[k] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        let procStart = obj["procStart"] as? String
        return SessionRecord(pid: pid,
                             sessionId: obj["sessionId"] as? String ?? "",
                             cwd: cwd,
                             configDir: configDir,
                             kind: obj["kind"] as? String ?? "interactive",
                             entrypoint: obj["entrypoint"] as? String ?? "",
                             status: status,
                             waitCategory: status == "waiting" ? WaitCategory.parse(obj["waitingFor"] as? String) : nil,
                             statusSince: ms("statusUpdatedAt") ?? ms("updatedAt"),
                             startedAt: ms("startedAt"),
                             alive: isAlive(pid, procStart))
    }
}

enum Liveness {
    /// proc_pidinfo (allowed in the saver sandbox; kill(pid,0) is not). Dead
    /// pid → false. With a procStart, the process start second must match it
    /// (±1 s) or the pid was reused → false.
    static func check(pid: Int32, procStart: String?) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        guard let ps = procStart else { return true }
        guard let expected = parseProcStart(ps) else { return false }
        return abs(Int64(info.pbi_start_tvsec) - Int64(expected.timeIntervalSince1970)) <= 1
    }

    /// `"Fri Nov 20 19:37:21 2026"` (ctime-style, `%e` day padding), always UTC.
    static func parseProcStart(_ s: String) -> Date? {
        let collapsed = s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return procStartFormatter.date(from: collapsed)
    }

    /// Inverse of parseProcStart (tests, probes): ctime style in UTC.
    static func formatProcStart(_ d: Date) -> String {
        var t = time_t(d.timeIntervalSince1970)
        var tmv = tm()
        gmtime_r(&t, &tmv)
        var buf = [Int8](repeating: 0, count: 64)
        strftime(&buf, buf.count, "%a %b %e %H:%M:%S %Y", &tmv)
        return String(cString: buf)
    }

    private static let procStartFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()
}
