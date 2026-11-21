//
//  main.swift — the matrix-diag collector (unsandboxed; run by launchd every
//  60 s, or by hand). One run: load state, fetch due sources, write state
//  atomically, exit. See Collector.swift.
//
//  Usage: matrix-diag-collector [--state PATH] [--log PATH] [--config PATH] [--force]
//    --state   state file   (default ~/.local/state/matrix-diag/collector-state.json)
//    --log     log file     (default ~/Library/Logs/matrix-diag/collector.log; "-" = stderr only)
//    --config  config file  (default ~/.config/matrix-diag/config.json)
//    --force   fetch every source now, ignoring the schedule
//  Exit status: 0 = state written; 1 = state write failed; 2 = bad arguments.
//  Prints nothing on success (stdout/stderr may be launchd's log files).
//

import Foundation

let home = realHomeDirectory()
var statePath = CollectorStateStore.defaultPath(home: home)
var logPath: String? = CollectorLog.defaultPath(home: home)
var configPath = ConfigLoader.defaultPath(home: home)
var force = false

var argv = CommandLine.arguments.dropFirst()
while let a = argv.popFirst() {
    switch a {
    case "--state": if let v = argv.popFirst() { statePath = v } else { exit(2) }
    case "--log": if let v = argv.popFirst() { logPath = v == "-" ? nil : v } else { exit(2) }
    case "--config": if let v = argv.popFirst() { configPath = v } else { exit(2) }
    case "--force": force = true
    case "-h", "--help":
        print("usage: matrix-diag-collector [--state PATH] [--log PATH|-] [--config PATH] [--force]")
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown argument \(a)\n".utf8))
        exit(2)
    }
}

let log = CollectorLog(path: logPath, now: Date.init)
let envPath = ProcessInfo.processInfo.environment["PATH"]
let ctx = CollectorContext(now: Date.init,
                           home: home,
                           config: ConfigLoader.load(path: configPath).config,
                           readKeychain: LiveKeychain.read(service:),
                           http: LiveHTTP.send,
                           userAgent: BinaryResolver.claudeUserAgent(home: home, path: envPath),
                           log: log)
let report = Collector.run(statePath: statePath, sources: CollectorSources.standard(), ctx: ctx, force: force)
if logPath == nil { for l in log.lines { FileHandle.standardError.write(Data((l + "\n").utf8)) } }
exit(report.wrote ? 0 : 1)
