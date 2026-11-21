//
//  BackgroundAgents.swift
//  Background-agent counts per session (#5), computed on the poller queue as
//  part of the sessions scan. Per config dir:
//
//  - Subagents: `projects/<project>/<sessionId>/subagents/agent-*.meta.json`
//    without `finished: true` whose sibling `.jsonl` changed within
//    `BackgroundCfg.subagentFreshness` (guards against crashed subagents;
//    `finished` is only ever `true` or absent). `<project>` is the session's
//    cwd sanitised the way Claude Code does it, in the session's OWN config
//    dir. When that path doesn't hold the session (worktrees can move cwd),
//    a fallback lists every project dir looking for the session id; its
//    result is cached per session so it stays off the 2 s hot path.
//  - Jobs (`jobs/*/state.json`, running states) and daemon workers
//    (`daemon/roster.json`, live pids only), deduplicated by session id and
//    attributed to the session whose id they carry. Ones that match no
//    session still count in the total. Both are optional: absent → zero.
//
//  Nothing here throws: a missing or malformed background file is zero, never
//  SIGNAL LOST. Meta `description` and job `needs`/`name` are never read out.
//

import Foundation

enum BackgroundCfg {
    /// An unfinished subagent counts only if its transcript changed this recently.
    static let subagentFreshness: TimeInterval = 5 * 60
    /// How long a failed fallback lookup is remembered before retrying.
    static let fallbackRetry: TimeInterval = 60
    /// Job `state` values that mean "running".
    static let runningJobStates: Set<String> = ["working", "starting"]
}

/// Claude Code's project-dir name for a cwd: every non-alphanumeric UTF-16
/// code unit becomes `-`; past 200 units it is truncated and suffixed with
/// `-` + base36 of |javaHash(cwd)|.
enum ProjectDirName {
    static let maxLength = 200

    static func from(cwd: String) -> String {
        let units = Array(cwd.utf16)
        var name = String(String.UnicodeScalarView(units.map { u -> Unicode.Scalar in
            let isAlnum = (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A)
            return Unicode.Scalar(isAlnum ? UInt8(u) : 0x2D)
        }))
        guard units.count > maxLength else { return name }
        var h: Int32 = 0
        for u in units { h = (h &<< 5) &- h &+ Int32(u) }
        name = String(name.prefix(maxLength)) + "-" + String(abs(Int64(h)), radix: 36)
        return name
    }
}

/// Stateful (it caches fallback lookups across scans); one per poll engine,
/// used only on the poller queue.
final class BackgroundAgentScanner {
    /// How many times the slow fallback (listing every project dir) ran.
    private(set) var fallbackLookups = 0
    /// "configDir/sessionId" → project dir found by the fallback (nil = not
    /// found) and when that was decided.
    private var resolved: [String: (project: String?, at: Date)] = [:]

    struct Result {
        var perSession: [String: Int] = [:]
        var unattributed = 0
    }

    /// Counts for the given sessions of one config dir.
    func count(home: String, configDir: String, sessions: [(sessionId: String, cwd: String)],
               isAlive: LivenessChecker, now: Date) -> Result {
        let root = "\(home)/\(configDir)"
        var result = Result()
        for s in sessions where !s.sessionId.isEmpty {
            guard let dir = sessionDir(root: root, configDir: configDir, sessionId: s.sessionId,
                                       cwd: s.cwd, now: now) else { continue }
            let n = runningSubagents(in: "\(dir)/subagents", now: now)
            if n > 0 { result.perSession[s.sessionId, default: 0] += n }
        }
        // Jobs and workers: one unit per session id (a job runs in a worker).
        var units: [String: Set<String>] = [:]   // unit key → session ids it may belong to
        for (key, ids) in runningJobs(root: root) { units[key, default: []].formUnion(ids) }
        for (key, ids) in liveWorkers(root: root, isAlive: isAlive) { units[key, default: []].formUnion(ids) }
        let known = Set(sessions.map(\.sessionId))
        for ids in units.values {
            if let owner = ids.sorted().first(where: known.contains) {
                result.perSession[owner, default: 0] += 1
            } else {
                result.unattributed += 1
            }
        }
        return result
    }

    /// Forget cached lookups for sessions that no longer exist.
    func retain(keys: Set<String>) { resolved = resolved.filter { keys.contains($0.key) } }

    static func key(_ configDir: String, _ sessionId: String) -> String { "\(configDir)/\(sessionId)" }

    // MARK: Subagents

    private func sessionDir(root: String, configDir: String, sessionId: String, cwd: String, now: Date) -> String? {
        let fm = FileManager.default
        let projects = "\(root)/projects"
        let primary = "\(projects)/\(ProjectDirName.from(cwd: cwd))"
        // The primary path resolves when it holds the session's transcript or dir.
        if fm.fileExists(atPath: "\(primary)/\(sessionId)") { return "\(primary)/\(sessionId)" }
        if fm.fileExists(atPath: "\(primary)/\(sessionId).jsonl") { return nil }

        let key = Self.key(configDir, sessionId)
        if let hit = resolved[key] {
            if let p = hit.project, fm.fileExists(atPath: "\(projects)/\(p)/\(sessionId)") {
                return "\(projects)/\(p)/\(sessionId)"
            }
            if hit.project == nil, now.timeIntervalSince(hit.at) < BackgroundCfg.fallbackRetry { return nil }
        }
        fallbackLookups += 1
        var found: String?
        for p in ((try? fm.contentsOfDirectory(atPath: projects)) ?? []).sorted() {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: "\(projects)/\(p)/\(sessionId)", isDirectory: &isDir), isDir.boolValue {
                found = p
                break
            }
        }
        resolved[key] = (found, now)
        return found.map { "\(projects)/\($0)/\(sessionId)" }
    }

    private func runningSubagents(in dir: String, now: Date) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return 0 }
        var n = 0
        for f in files where f.hasPrefix("agent-") && f.hasSuffix(".meta.json") {
            guard let data = fm.contents(atPath: "\(dir)/\(f)"),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if (meta["finished"] as? Bool) == true { continue }
            let transcript = "\(dir)/\(f.dropLast(".meta.json".count)).jsonl"
            guard let mtime = (try? fm.attributesOfItem(atPath: transcript))?[.modificationDate] as? Date,
                  now.timeIntervalSince(mtime) < BackgroundCfg.subagentFreshness else { continue }
            n += 1
        }
        return n
    }

    // MARK: Jobs and workers

    /// Running jobs: unit key (session id, else job dir) → candidate owner ids.
    private func runningJobs(root: String) -> [String: Set<String>] {
        let fm = FileManager.default
        let jobs = "\(root)/jobs"
        var out: [String: Set<String>] = [:]
        for id in (try? fm.contentsOfDirectory(atPath: jobs)) ?? [] where !id.hasPrefix(".") {
            guard let data = fm.contents(atPath: "\(jobs)/\(id)/state.json"),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = obj["state"] as? String,
                  BackgroundCfg.runningJobStates.contains(state) else { continue }
            let ids = Set([obj["sessionId"], obj["resumeSessionId"]].compactMap { $0 as? String }.filter { !$0.isEmpty })
            out[(obj["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "job:\(id)", default: []]
                .formUnion(ids)
        }
        return out
    }

    /// Live daemon workers (the roster can be stale, so each pid is checked).
    private func liveWorkers(root: String, isAlive: LivenessChecker) -> [String: Set<String>] {
        guard let data = FileManager.default.contents(atPath: "\(root)/daemon/roster.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workers = obj["workers"] as? [String: Any] else { return [:] }
        var out: [String: Set<String>] = [:]
        for (id, value) in workers {
            guard let w = value as? [String: Any],
                  let pid = (w["pid"] as? NSNumber)?.int32Value, pid > 0,
                  isAlive(pid, w["procStart"] as? String) else { continue }
            let sid = (w["sessionId"] as? String) ?? ""
            out[sid.isEmpty ? "worker:\(id)" : sid, default: []].formUnion(sid.isEmpty ? [] : [sid])
        }
        return out
    }
}
