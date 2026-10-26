import Foundation
@testable import worktape

func withTemporaryDirectory<Result>(_ body: (String) throws -> Result) throws -> Result {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    return try body(directory)
}

func withTemporaryDirectory<Result>(_ body: (String) async throws -> Result) async throws -> Result {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    return try await body(directory)
}

private func makeTemporaryDirectory() throws -> String {
    let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("worktape-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
    return (directory as NSString).standardizingPath
}

func exitCode(of child: ChildProcess) async -> Int32? {
    while !child.hasExited() {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return child.exitCode
}

struct Output {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) throws -> Output {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    process.environment = environment
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let error = standardError.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Output(
        status: process.terminationStatus,
        standardOutput: String(decoding: output, as: UTF8.self),
        standardError: String(decoding: error, as: UTF8.self)
    )
}
