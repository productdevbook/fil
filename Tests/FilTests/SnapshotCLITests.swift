import Darwin
import Foundation
import Testing

/// How `fil scan` uses its snapshots across runs. Uses fseventsd, like the incremental tests (skip with
/// `--skip FSEvents`).
@Suite("Snapshot use in fil scan (FSEvents)", .serialized)
struct SnapshotCLITests {
    let cli = ErrorHandlingTests()

    @Test func plainAndPrivateRunsKeepTheirOwnSnapshots() throws {
        let dir = try ErrorHandlingTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let root = dir + "/root", snap = dir + "/snap"
        try FileManager.default.createDirectory(atPath: root + "/a", withIntermediateDirectories: true)
        try Data(count: 4096).write(to: URL(fileURLWithPath: root + "/a/file"))
        var modes: [String] = []
        for i in 0..<6 {
            let r = try cli.run(["scan", root, "--porcelain"] + (i % 2 == 1 ? ["--private"] : []), snapshotDir: snap)
            modes.append(r.stdout.split(separator: " ").first.map(String.init) ?? r.stdout)
        }
        #expect(modes == ["mode=full", "mode=full"] + Array(repeating: "mode=incremental", count: 4))
        #expect(try FileManager.default.contentsOfDirectory(atPath: snap).filter { $0.hasSuffix(".bin") }.count == 2)
    }

    @Test func saysWhyASnapshotWasNotUsed() throws {
        let dir = try ErrorHandlingTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let root = dir + "/root", snap = dir + "/snap"
        try FileManager.default.createDirectory(atPath: root + "/a", withIntermediateDirectories: true)
        let args = ["scan", root, "-v", "--top", "0", "-q"]

        let first = try cli.run(args, snapshotDir: snap)
        #expect(first.stdout.contains("[full scan (snapshot not used: missing)]"), "\(first.stdout)")
        let files = try FileManager.default.contentsOfDirectory(atPath: snap).filter { $0.hasSuffix(".bin") }
        #expect(files.count == 1)
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: snap + "/" + files[0]))
        let second = try cli.run(args, snapshotDir: snap)
        #expect(second.stdout.contains("[full scan (snapshot not used: not a snapshot)]"), "\(second.stdout)")
        // A snapshot that exists but cannot be read says so, with the reason.
        #expect(chmod(snap + "/" + files[0], 0o000) == 0)
        let denied = try cli.run(args, snapshotDir: snap)
        #expect(denied.stdout.contains("[full scan (snapshot not used: unreadable (Permission denied))]"),
                "\(denied.stdout)")
        // --full does not look at the snapshot.
        let full = try cli.run(args + ["--full"], snapshotDir: snap)
        #expect(full.stdout.contains("[full scan]"), "\(full.stdout)")

        let list = try cli.run(["list", "--home", root, "--timings"], snapshotDir: snap + "-list")
        #expect(list.stderr.range(of: #"snapshot load\s+\d+ ms  \(not used: missing; full scan\)"#,
                                  options: .regularExpression) != nil, "\(list.stderr)")
    }

    @Test func incrementalRunShowsFullScanStatsLabelled() throws {
        let dir = try ErrorHandlingTests.tempDir()
        defer {
            chmod(dir + "/root/locked", 0o755)
            try? FileManager.default.removeItem(atPath: dir)
        }
        let root = dir + "/root", snap = dir + "/snap"
        try FileManager.default.createDirectory(atPath: root + "/locked", withIntermediateDirectories: true)
        try Data(count: 4096).write(to: URL(fileURLWithPath: root + "/file"))
        #expect(chmod(root + "/locked", 0o000) == 0)
        let args = ["scan", root, "-v", "--top", "0", "-q"]

        let full = try cli.run(args, snapshotDir: snap)
        #expect(full.stdout.contains("\nskipped  denied 1 · "), "\(full.stdout)")
        let incremental = try cli.run(args, snapshotDir: snap)
        #expect(incremental.stdout.contains("[incremental: "), "\(incremental.stdout)")
        // `denied` is current and outside the label; the other counters are labelled with the full scan's time.
        #expect(incremental.stdout.range(of: #"\nskipped  denied 1 · as of full scan at \d\d:\d\d: errors 0 · "#,
                                         options: .regularExpression) != nil, "\(incremental.stdout)")
        #expect(incremental.stdout.contains("         firmlinked data dirs "), "\(incremental.stdout)")
        // Same definition in both modes: a forced full scan of the unchanged disk shows the same value.
        let again = try cli.run(args + ["--full"], snapshotDir: snap)
        #expect(again.stdout.contains("\nskipped  denied 1 · errors 0 · "), "\(again.stdout)")

        // A second denied folder seen only by an update is counted at once.
        try FileManager.default.createDirectory(atPath: root + "/locked2", withIntermediateDirectories: true)
        #expect(chmod(root + "/locked2", 0o000) == 0)
        defer { chmod(root + "/locked2", 0o755) }
        let updated = try cli.run(args, snapshotDir: snap)
        #expect(updated.stdout.contains("[incremental: "), "\(updated.stdout)")
        #expect(updated.stdout.contains("\nskipped  denied 2 · as of full scan at "), "\(updated.stdout)")
    }
}
