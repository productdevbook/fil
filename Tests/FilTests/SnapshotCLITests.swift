import Darwin
import Foundation
import Testing

/// How `fil scan` uses its snapshots across runs. Uses fseventsd, like the incremental tests (skip with
/// `--skip FSEvents`).
@Suite("Snapshot use in fil scan (FSEvents)", .serialized)
struct SnapshotCLITests {
    let cli = ErrorHandlingTests()

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
        // HH:mm today: the label comes from the snapshot's full scan, `denied` from the current tree.
        #expect(incremental.stdout.range(of: #"\nskipped \(as of full scan at \d\d:\d\d\)  denied 1 · "#,
                                         options: .regularExpression) != nil, "\(incremental.stdout)")
        #expect(incremental.stdout.contains("         firmlinked data dirs "), "\(incremental.stdout)")
    }
}
