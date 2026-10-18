import Darwin
import Foundation
import Testing
@testable import fil

/// Locates the test bundle, which sits in the same products directory as `fil`.
private final class BundleMarker {}

/// Runs the built `fil` binary and checks that errors end in one `fil: <message>` line, never a trap.
@Suite struct ErrorHandlingTests {
    struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// The `fil` executable next to the test bundle (both live in the build products directory).
    static let binary: URL = {
        Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("fil")
    }()

    /// A fresh directory under the temporary directory, resolved through symlinks.
    static func tempDir() throws -> String {
        var template = Array((NSTemporaryDirectory() + "fil-test-errors-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let made = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard let resolved = realpath(made, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func run(_ args: [String], snapshotDir: String, cwd: String? = nil) throws -> Run {
        let p = Process()
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        p.executableURL = Self.binary
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["FIL_SNAPSHOT_DIR"] = snapshotDir
        env["NO_COLOR"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Run(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self),
                   stderr: String(decoding: e, as: UTF8.self))
    }

    @Test func missingRootIsOneLineAndExitOne() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for extra in [[], ["--porcelain"]] {
            let r = try run(["scan", "/nonexistent/x"] + extra, snapshotDir: dir + "/snap")
            #expect(r.status == 1, "\(extra)")
            #expect(r.stderr == "fil: /nonexistent/x: No such file or directory\n", "\(extra)")
            #expect(r.stdout.isEmpty, "\(extra)")
        }
    }

    @Test func fileRootIsNotADirectory() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data(count: 10).write(to: URL(fileURLWithPath: dir + "/f"))
        let r = try run(["scan", dir + "/f", "--porcelain"], snapshotDir: dir + "/snap")
        #expect(r.status == 1)
        #expect(r.stderr == "fil: \(dir)/f: not a directory\n")
        #expect(r.stdout.isEmpty)
    }

    @Test func symlinkRootIsResolved() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/real", withIntermediateDirectories: true)
        try Data(count: 10).write(to: URL(fileURLWithPath: dir + "/real/f"))
        try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: "real")
        let r = try run(["scan", dir + "/link", "--top", "0", "--full"], snapshotDir: dir + "/snap")
        #expect(r.status == 0)
        #expect(r.stdout.hasPrefix("\(dir)/real  "), "\(r.stdout)")
    }

    @Test func homeIsResolvedAndMustBeADirectory() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/home", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: "home")
        let r = try run(["list", "--home", dir + "/link", "--json"], snapshotDir: dir + "/snap")
        #expect(r.status == 0, "\(r.stderr)")
        let json = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        #expect(json?["home"] as? String == dir + "/home", "\(r.stdout)")
        try Data(count: 10).write(to: URL(fileURLWithPath: dir + "/f"))
        for command in ["list", "clean"] {
            let f = try run([command, "x", "--home", dir + "/f"], snapshotDir: dir + "/snap")
            #expect(f.status == 1, "\(command)")
            #expect(f.stderr == "fil: \(dir)/f: not a directory\n", "\(command)")
            #expect(f.stdout.isEmpty, "\(command)")
        }
    }

    @Test func dotKeysTheSnapshotByResolvedPath() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for name in ["a", "b"] {
            try FileManager.default.createDirectory(atPath: dir + "/" + name, withIntermediateDirectories: true)
            try Data(count: 10).write(to: URL(fileURLWithPath: dir + "/\(name)/f"))
            let r = try run(["scan", ".", "--porcelain"], snapshotDir: dir + "/snap", cwd: dir + "/" + name)
            #expect(r.status == 0)
            #expect(r.stdout.hasPrefix("mode=full "), "\(r.stdout)")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir + "/snap")
        #expect(files.count == 2, "\(files)")
    }

    @Test func unreadableRootIsOneLineAndExitOne() throws {
        guard getuid() != 0 else { return }  // root ignores the permission bits
        let dir = try Self.tempDir()
        defer {
            chmod(dir + "/locked", 0o755)
            try? FileManager.default.removeItem(atPath: dir)
        }
        try FileManager.default.createDirectory(atPath: dir + "/locked/child", withIntermediateDirectories: true)
        #expect(chmod(dir + "/locked", 0) == 0)
        let r = try run(["scan", dir + "/locked/child", "--porcelain"], snapshotDir: dir + "/snap")
        #expect(r.status == 1)
        #expect(r.stderr == "fil: \(dir)/locked/child: Permission denied\n")
        #expect(r.stdout.isEmpty)
    }

    @Test func missingHomeWithJSONPrintsNothingOnStdout() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let r = try run(["list", "--home", "/nonexistent/h", "--json"], snapshotDir: dir + "/snap")
        #expect(r.status == 1)
        #expect(r.stderr == "fil: /nonexistent/h: No such file or directory\n")
        #expect(r.stdout.isEmpty)
    }

    @Test func failedSnapshotSaveIsAWarning() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/root", withIntermediateDirectories: true)
        try Data(count: 10).write(to: URL(fileURLWithPath: dir + "/root/f"))
        try Data().write(to: URL(fileURLWithPath: dir + "/notadir"))
        let r = try run(["scan", dir + "/root", "--porcelain"], snapshotDir: dir + "/notadir/snap")
        #expect(r.status == 0)
        #expect(r.stderr == "fil: warning: could not save the snapshot (\(dir)/notadir: Not a directory); "
            + "the next run does a full scan\n")
        #expect(r.stdout.hasPrefix("mode=full alloc="))
        #expect(r.stdout.split(separator: "\n").count == 1)
    }

    @Test func usageErrorIsTwoLines() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = try run(["scan", "--bogus"], snapshotDir: dir)
        #expect(a.status == 2)
        #expect(a.stderr == "fil: unknown option --bogus for 'fil scan'\nRun 'fil help scan' for usage.\n")
        let b = try run(["bogus"], snapshotDir: dir)
        #expect(b.status == 2)
        #expect(b.stderr == "fil: unknown command 'bogus'\nRun 'fil --help' for usage.\n")
    }

    // A JSON encoding error cannot be provoked from outside; the top-level catch prints any error this way.
    @Test func messagesForEachKindOfError() {
        struct Own: Error, CustomStringConvertible { let description = "own message" }
        #expect(errorMessage(CLIError(description: "x: y")) == "x: y")
        #expect(errorMessage(Own()) == "own message")
        #expect(errorMessage(POSIXError(.ENOENT), path: "/a") == "/a: No such file or directory")
        let wrapped = CocoaError(.fileWriteUnknown, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR)),
            NSFilePathErrorKey: "/b",
        ])
        #expect(errorMessage(wrapped) == "/b: Not a directory")
        let plain = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Something broke."])
        #expect(errorMessage(plain) == "Something broke")
    }
}
