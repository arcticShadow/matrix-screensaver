//
//  TestKit.swift
//  A deliberately tiny assertion helper: no XCTest, no Xcode. Each `test`
//  block runs a closure; `expect*` record failures with file:line; the runner
//  in main.swift exits non-zero if anything failed.
//

import Foundation

enum TestKit {
    static var passed = 0
    static var failed = 0
    static var current = ""
    private static var currentFailed = false

    static func test(_ name: String, _ body: () throws -> Void) {
        current = name
        currentFailed = false
        do { try body() } catch {
            fail("threw \(error)", file: #fileID, line: #line)
        }
        if currentFailed { failed += 1 } else { passed += 1 }
    }

    static func fail(_ message: String, file: String, line: Int) {
        currentFailed = true
        print("FAIL  \(current)\n      \(file):\(line): \(message)")
    }

    static func finish() -> Never {
        print("\(passed + failed) tests, \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

func test(_ name: String, _ body: () throws -> Void) { TestKit.test(name, body) }

func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
                               file: String = #fileID, line: Int = #line) {
    if actual != expected {
        TestKit.fail("expected \(expected)\n      but got  \(actual)", file: file, line: line)
    }
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "condition was false",
            file: String = #fileID, line: Int = #line) {
    if !condition { TestKit.fail(message(), file: file, line: line) }
}

/// A fresh scratch directory under build/ (never the user's real home).
func makeTempDir(_ name: String) -> String {
    let dir = FileManager.default.currentDirectoryPath + "/build/test-tmp/\(name)-\(UUID().uuidString.prefix(8))"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func writeFile(_ path: String, _ contents: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? contents.write(toFile: path, atomically: true, encoding: .utf8)
}
