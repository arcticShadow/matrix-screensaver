//
//  LiveDeps.swift
//  The collector's real-world implementations: keychain via /usr/bin/security
//  (the only client the Claude Code keychain items trust, so no prompts),
//  HTTP via URLSession behind an allowlist, and binary resolution from known
//  absolute locations (launchd's PATH is minimal).
//

import Foundation

enum LiveKeychain {
    /// `security` normally answers in milliseconds; a hang (locked keychain,
    /// stuck securityd) must not block the whole collector run.
    static let timeout: TimeInterval = 10

    /// `security find-generic-password -s <svc> -w`, run through `run` (live:
    /// LiveProcess.capture, which enforces `timeout`). The secret is read from
    /// the pipe into memory only; it is never logged or put on argv. A
    /// timeout or launch failure is `.failed` (the account's KEYCHAIN error).
    static func read(service: String,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     run: (ProcessSpec) throws -> ProcessOutput = LiveProcess.capture) -> KeychainRead {
        let spec = ProcessSpec(executable: "/usr/bin/security",
                               arguments: ["find-generic-password", "-s", service, "-w"],
                               environment: environment,
                               workingDirectory: "/",
                               timeout: timeout)
        let out: ProcessOutput
        do { out = try run(spec) } catch { return .failed(-1) }
        if out.timedOut { return .failed(out.status) }
        switch out.status {
        case 0:
            let s = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .found(s)
        case 44: return .notFound
        default: return .failed(out.status)
        }
    }
}

enum LiveHTTP {
    struct Refused: Error, CustomStringConvertible { var description: String { "request not allowlisted" } }

    /// Defence in depth: the collector may only GET the usage endpoint. In
    /// particular it can never reach the OAuth token (refresh) endpoint.
    static func isAllowed(_ req: HTTPRequest) -> Bool {
        req.method == "GET" && req.url == UsageSource.endpoint
    }

    static func send(_ req: HTTPRequest) throws -> HTTPResponse {
        guard isAllowed(req), let url = URL(string: req.url) else { throw Refused() }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.httpMethod = req.method
        for (k, v) in req.headers { r.setValue(v, forHTTPHeaderField: k) }
        let cfg = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        var result: Result<HTTPResponse, Error> = .failure(Refused())
        session.dataTask(with: r) { data, resp, err in
            if let err { result = .failure(err) }
            else {
                result = .success(HTTPResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                                               body: data ?? Data()))
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }
}

enum BinaryResolver {
    /// Known absolute locations, in order, then PATH. Anything under a cmux
    /// per-terminal shim dir (`.cmuxterm`) is skipped: those are transient.
    static func resolve(_ name: String, home: String, path: String?,
                        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })
        -> String? {
        var candidates = ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        candidates += (path ?? "").split(separator: ":").map { "\($0)/\(name)" }
        return candidates.first { !$0.contains("/.cmuxterm/") && isExecutable($0) }
    }

    /// `claude-cli/<version> (external, cli)`. The version comes from the
    /// native installer's symlink target (…/versions/<version>) so no process
    /// is spawned; falls back to a known-good version.
    static func claudeUserAgent(home: String, path: String?) -> String {
        let fallback = "2.1.330"
        var version = fallback
        if let bin = resolve("claude", home: home, path: path),
           let target = try? FileManager.default.destinationOfSymbolicLink(atPath: bin) {
            let last = (target as NSString).lastPathComponent
            if last.first?.isNumber == true, last.allSatisfy({ $0.isNumber || $0 == "." }) { version = last }
        }
        return "claude-cli/\(version) (external, cli)"
    }
}

enum LiveProcess {
    /// Run a child with exactly `spec.environment` (the caller has already put
    /// HOME/USER in it), output discarded, terminated after `spec.timeout`.
    static func run(_ spec: ProcessSpec) throws -> ProcessResult {
        let r = try launch(spec, captureStdout: false)
        return ProcessResult(status: r.status, timedOut: r.timedOut)
    }

    /// Same, but stdout is captured (read concurrently, so a chatty child
    /// can't fill the pipe and stall). Used for `gws calendar +agenda`.
    static func capture(_ spec: ProcessSpec) throws -> ProcessOutput {
        try launch(spec, captureStdout: true)
    }

    private static func launch(_ spec: ProcessSpec, captureStdout: Bool) throws -> ProcessOutput {
        try? FileManager.default.createDirectory(atPath: spec.workingDirectory, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: spec.executable)
        p.arguments = spec.arguments
        p.environment = spec.environment
        p.currentDirectoryURL = URL(fileURLWithPath: spec.workingDirectory)
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let pipe = captureStdout ? Pipe() : nil
        p.standardOutput = pipe ?? FileHandle.nullDevice
        var output = Data()
        let readDone = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        if let pipe {
            DispatchQueue.global().async {
                output = pipe.fileHandleForReading.readDataToEndOfFile()
                readDone.signal()
            }
        } else {
            readDone.signal()
        }
        var timedOut = false
        if done.wait(timeout: .now() + spec.timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if done.wait(timeout: .now() + 5) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                done.wait()
            }
        }
        // EOF arrives once the child (and anything holding its stdout) exits.
        // (If it doesn't, the reader still owns `output`: return none of it.)
        guard readDone.wait(timeout: .now() + 5) == .success else {
            return ProcessOutput(status: p.terminationStatus, timedOut: true, stdout: Data())
        }
        return ProcessOutput(status: p.terminationStatus, timedOut: timedOut, stdout: output)
    }
}

/// Login name from the passwd database (USER may be missing under launchd).
func realUserName() -> String {
    if let pw = getpwuid(getuid()), let name = pw.pointee.pw_name { return String(cString: name) }
    return ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
}
