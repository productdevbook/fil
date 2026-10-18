import Foundation
import Subprocess
import System

/// What a query command produced.
public enum CommandResult: Sendable, Equatable {
    /// Exit status 0; standard output.
    case success(String)
    /// Non-zero exit, a launch failure or a signal; a short reason.
    case failed(String)
    /// Did not finish in time; the child's process group was killed.
    case timedOut
}

/// Runs a read-only query command. A seam so tests never need the real tools.
public protocol CommandRunner: Sendable {
    /// Runs `argv` (argv[0] is an absolute path) without a shell and stops it after `timeout`.
    func run(_ argv: [String], timeout: Duration) async -> CommandResult
}

/// The real runner: swift-subprocess, the child in its own session so a timeout kills its children too.
public struct SystemCommandRunner: CommandRunner {
    /// Working directory of the child (the home directory, so no project-local config is picked up).
    public var workingDirectory: String?

    /// Keeps queries from updating, prompting or downloading anything.
    static let quietEnvironment: [String: String] = [
        "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "NO_UPDATE_NOTIFIER": "1",
        "npm_config_update_notifier": "false", "COREPACK_ENABLE_NETWORK": "0",
        "COREPACK_ENABLE_DOWNLOAD_PROMPT": "0", "PIP_DISABLE_PIP_VERSION_CHECK": "1", "GOTOOLCHAIN": "local",
    ]

    public init(workingDirectory: String? = nil) { self.workingDirectory = workingDirectory }

    public func run(_ argv: [String], timeout: Duration) async -> CommandResult {
        guard let exe = argv.first else { return .failed("empty command") }
        // The tool's own directory first in PATH: npm, pnpm and yarn are node scripts (`#!/usr/bin/env node`).
        let dir = (exe as NSString).deletingLastPathComponent
        let realDir = (resolvedPath(exe) as NSString).deletingLastPathComponent
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        var env: [Environment.Key: String?] = [:]
        for (k, v) in Self.quietEnvironment { env[Environment.Key(rawValue: k)!] = v }
        env["PATH"] = [dir, realDir, inherited].joined(separator: ":")
        let workingDirectory = workingDirectory
        let environment = env
        return await withTaskGroup(of: CommandResult?.self) { group in
            group.addTask {
                await collect(argv, environment: environment, workingDirectory: workingDirectory)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return Task.isCancelled ? nil : .timedOut
            }
            // The first answer wins; cancelling the other task kills the child (teardown) or stops the timer.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .timedOut
        }
    }
}

/// Runs one command to completion. Returns nil when cancelled (the timeout fired first).
private func collect(_ argv: [String], environment: [Environment.Key: String?], workingDirectory: String?) async -> CommandResult? {
    var options = PlatformOptions()
    options.createSession = true
    options.teardownSequence = [.send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .zero)]
    do {
        let r = try await run(.path(FilePath(argv[0])), arguments: Arguments(Array(argv.dropFirst())),
                              environment: .inherit.updating(environment), workingDirectory: workingDirectory.map { FilePath($0) },
                              platformOptions: options, output: .string(limit: 16 << 20),
                              error: .string(limit: 1 << 20))
        if Task.isCancelled { return nil }
        guard r.terminationStatus.isSuccess else {
            let err = r.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            let line = err.split(separator: "\n").first.map(String.init) ?? ""
            return .failed("\(r.terminationStatus)" + (line.isEmpty ? "" : ": \(line.prefix(200))"))
        }
        return .success(r.standardOutput)
    } catch {
        return Task.isCancelled ? nil : .failed("\(error)")
    }
}

func resolvedPath(_ p: String) -> String {
    guard let r = realpath(p, nil) else { return p }
    defer { free(r) }
    return String(cString: r)
}

enum Commands {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Runs a removal command (argv[0] is an absolute path) without a shell and without a timeout: deleting a
    /// simulator runtime can take a while. Returns its standard output.
    /// Runs in `workingDirectory` (home) with the quiet environment, so `go clean` neither picks up a project's
    /// `go.mod` nor downloads a toolchain.
    static func output(_ argv: [String], workingDirectory: String? = nil) async throws -> String {
        var env: [Environment.Key: String?] = [:]
        for (k, v) in SystemCommandRunner.quietEnvironment { env[Environment.Key(rawValue: k)!] = v }
        let r = try await run(.path(FilePath(argv[0])), arguments: Arguments(Array(argv.dropFirst())),
                              environment: .inherit.updating(env), workingDirectory: workingDirectory.map { FilePath($0) },
                              output: .string(limit: 16 << 20), error: .string(limit: 1 << 20))
        guard r.terminationStatus.isSuccess else {
            let err = r.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(description: "\((argv[0] as NSString).lastPathComponent) failed: \(r.terminationStatus) \(err)")
        }
        return r.standardOutput
    }
}
