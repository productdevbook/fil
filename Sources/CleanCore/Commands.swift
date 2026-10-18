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
    /// How long the child's process group gets after SIGTERM before SIGKILL when the command is stopped.
    /// Zero (queries): SIGKILL at once. Removals use 5 s so a tool can clean up.
    public var gracePeriod: Duration

    /// Keeps queries from updating, prompting or downloading anything.
    static let quietEnvironment: [String: String] = [
        "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "NO_UPDATE_NOTIFIER": "1",
        "npm_config_update_notifier": "false", "COREPACK_ENABLE_NETWORK": "0",
        "COREPACK_ENABLE_DOWNLOAD_PROMPT": "0", "PIP_DISABLE_PIP_VERSION_CHECK": "1", "GOTOOLCHAIN": "local",
    ]

    public init(workingDirectory: String? = nil, gracePeriod: Duration = .zero) {
        self.workingDirectory = workingDirectory
        self.gracePeriod = gracePeriod
    }

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
        let gracePeriod = gracePeriod
        let environment = env
        let timer = timeout
        return await withTaskGroup(of: Racer.self) { group in
            group.addTask {
                .command(
                    await collect(
                        argv, environment: environment, workingDirectory: workingDirectory,
                        gracePeriod: gracePeriod))
            }
            group.addTask {
                try? await Task.sleep(for: timer)
                return .timer
            }
            // The first answer ends the race; cancelling the other task kills the child (teardown) or stops the
            // timer. A command that finished on its own at the same moment keeps its real result.
            var command: CommandResult?
            var cancelled = false
            for await racer in group {
                if case .command(let r) = racer { command = r }
                if !cancelled { cancelled = true; group.cancelAll() }
            }
            return command ?? .timedOut
        }
    }
}

private enum Racer: Sendable {
    /// nil: the command was stopped (timeout or cancellation) and has no result of its own.
    case command(CommandResult?)
    case timer
}

/// The child's pid, remembered so a stopped run can SIGKILL its whole process group.
private final class ChildPid: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    func set(_ p: pid_t) { lock.withLock { pid = p } }
    var value: pid_t { lock.withLock { pid } }
    private var stop = false
    /// Set when a stop (timeout or cancellation) began, i.e. when we are about to send SIGTERM.
    func markStopping() { lock.withLock { stop = true } }
    var stopping: Bool { lock.withLock { stop } }
}

/// Runs one command to completion. Returns nil when it was stopped (timeout or cancellation), whatever status the
/// command exits with after the stop began; a command that finished before any stop returns its real result.
private func collect(
    _ argv: [String], environment: [Environment.Key: String?], workingDirectory: String?,
    gracePeriod: Duration
) async -> CommandResult? {
    var options = PlatformOptions()
    options.createSession = true
    var teardown: [TeardownStep] = []
    if gracePeriod > .zero {
        teardown.append(.gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: gracePeriod))
    }
    teardown.append(.send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .zero))
    options.teardownSequence = teardown
    let configuration = Configuration(
        executable: .path(FilePath(argv[0])), arguments: Arguments(Array(argv.dropFirst())),
        environment: .inherit.updating(environment), workingDirectory: workingDirectory.map { FilePath($0) },
        platformOptions: options)
    let child = ChildPid()
    // swift-subprocess watches only the group leader: when the leader exits on SIGTERM its SIGKILL step is
    // skipped and a helper that ignores SIGTERM would survive. A stopped run therefore ends with one SIGKILL to
    // the whole group (harmless, ESRCH, when nothing is left). The group id stays reserved while any member lives.
    func killLeftovers() {
        let pid = child.value
        if pid > 0 { _ = kill(-pid, SIGKILL) }
    }
    do {
        let r = try await withTaskCancellationHandler {
            try await run(
                configuration, input: .none, output: .string(limit: 16 << 20),
                error: .string(limit: 1 << 20)
            ) { execution in
                child.set(execution.processIdentifier.value)
            }
        } onCancel: {
            child.markStopping()
        }
        if Task.isCancelled { killLeftovers() }
        // Once we sent the stop, whatever the tool does with SIGTERM (exit 0, exit 143, its own status, a
        // signal) is the stop outcome, not a result of its own.
        if child.stopping { return nil }
        guard r.terminationStatus.isSuccess else {
            let err = r.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            let line = err.split(separator: "\n").first.map(String.init) ?? ""
            return .failed("\(r.terminationStatus)" + (line.isEmpty ? "" : ": \(line.prefix(200))"))
        }
        return .success(r.standardOutput)
    } catch {
        if Task.isCancelled { killLeftovers() }
        return Task.isCancelled ? nil : .failed("\(error)")
    }
}

func resolvedPath(_ p: String) -> String {
    guard let r = realpath(p, nil) else { return p }
    defer { free(r) }
    return String(cString: r)
}
