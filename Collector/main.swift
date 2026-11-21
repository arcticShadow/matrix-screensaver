//
//  main.swift — the matrix-diag collector (unsandboxed; run by launchd every
//  60 s, or by hand). One run: load state, fetch due sources, write state
//  atomically, exit. See Collector.swift.
//
//  Usage: matrix-diag-collector [--state PATH] [--log PATH] [--config PATH] [--force]
//         matrix-diag-collector --init-config [--config PATH]
//    --state   state file   (default ~/.local/state/matrix-diag/collector-state.json)
//    --log     log file     (default ~/Library/Logs/matrix-diag/collector.log; "-" = stderr only)
//    --config  config file  (default ~/.config/matrix-diag/config.json)
//    --force   fetch every source now, ignoring the schedule
//    --init-config  create the config with defaults + a random salt if it is
//              missing (never overwrites), print its path, and exit (no collection)
//  Exit status: 0 = state written; 1 = state write failed; 2 = bad arguments.
//  Prints nothing on success (stdout/stderr may be launchd's log files).
//

import Foundation

let home = realHomeDirectory()
var statePath = CollectorStateStore.defaultPath(home: home)
var logPath: String? = CollectorLog.defaultPath(home: home)
var configPath = ConfigLoader.defaultPath(home: home)
var force = false
var initConfig = false

var argv = CommandLine.arguments.dropFirst()
while let a = argv.popFirst() {
    switch a {
    case "--state": if let v = argv.popFirst() { statePath = v } else { exit(2) }
    case "--log": if let v = argv.popFirst() { logPath = v == "-" ? nil : v } else { exit(2) }
    case "--config": if let v = argv.popFirst() { configPath = v } else { exit(2) }
    case "--force": force = true
    case "--init-config": initConfig = true
    case "-h", "--help":
        print("usage: matrix-diag-collector [--state PATH] [--log PATH|-] [--config PATH] [--force]")
        print("       matrix-diag-collector --init-config [--config PATH]")
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown argument \(a)\n".utf8))
        exit(2)
    }
}

if initConfig {
    do {
        switch try ConfigInitializer.createIfMissing(path: configPath) {
        case .created: print("Created config \(configPath) (defaults + random codename salt; add trusted SSIDs there)")
        case .alreadyExists: print("Config \(configPath) exists; left unchanged")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("init-config failed: \(error)\n".utf8))
        exit(1)
    }
}

let log = CollectorLog(path: logPath, now: Date.init)
let processEnv = ProcessInfo.processInfo.environment
let envPath = processEnv["PATH"]
let ctx = CollectorContext(now: Date.init,
                           home: home,
                           config: ConfigLoader.load(path: configPath).config,
                           readKeychain: LiveKeychain.read(service:),
                           http: LiveHTTP.send,
                           userAgent: BinaryResolver.claudeUserAgent(home: home, path: envPath),
                           log: log,
                           user: realUserName(),
                           environment: processEnv,
                           claudePath: BinaryResolver.resolve("claude", home: home, path: envPath),
                           runProcess: LiveProcess.run,
                           newSessionID: { UUID().uuidString.lowercased() },
                           sleep: { Thread.sleep(forTimeInterval: $0) })
let report = Collector.run(statePath: statePath, sources: CollectorSources.standard(), ctx: ctx, force: force)
if logPath == nil { for l in log.lines { FileHandle.standardError.write(Data((l + "\n").utf8)) } }
exit(report.wrote ? 0 : 1)
