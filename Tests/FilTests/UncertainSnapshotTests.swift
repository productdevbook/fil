import Darwin
import Foundation
import Testing

/// A tolerant run (`fil list`, or `fil scan --tolerant-hardlinks`) can leave uncertain bytes in the snapshot that a
/// strict `fil scan` shares; the strict scan must not present that tree as exact. Uses fseventsd, like the
/// incremental tests (skip with `--skip FSEvents`).
@Suite("Strict scan on a tolerant snapshot (FSEvents)", .serialized)
struct UncertainSnapshotTests {
    private func porcelain(_ r: ErrorHandlingTests.Run) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in r.stdout.split(whereSeparator: \.isWhitespace) {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        return fields
    }

    @Test func strictScanRunsAFullScanOnUncertainBytes() throws {
        let dir = try ErrorHandlingTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let root = dir + "/root", snap = dir + "/snap"
        try FileManager.default.createDirectory(atPath: root + "/orig", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/other", withIntermediateDirectories: true)
        try Data(count: 40_000).write(to: URL(fileURLWithPath: root + "/orig/file"))
        let cli = ErrorHandlingTests()
        let tolerant = ["scan", root, "--tolerant-hardlinks", "--porcelain"]

        let first = porcelain(try cli.run(tolerant, snapshotDir: snap))
        #expect(first["mode"] == "full")
        // A new link to a file older than the snapshot: the tolerant update counts it and flags its bytes.
        #expect(Darwin.link(root + "/orig/file", root + "/other/link") == 0)
        let second = porcelain(try cli.run(tolerant, snapshotDir: snap))
        #expect(second["mode"] == "incremental")
        #expect(Int(second["uncertain"] ?? "") ?? 0 > 0, "\(second)")

        let strict = try cli.run(["scan", root, "-v", "--top", "0", "-q"], snapshotDir: snap)
        #expect(strict.status == 0)
        #expect(strict.stdout.contains("[full scan (snapshot has uncertain bytes)]"), "\(strict.stdout)")
        #expect(!strict.stdout.contains("uncertain (hard links"), "\(strict.stdout)")

        // The full scan saved a tree without uncertain bytes: the next tolerant run starts clean.
        let after = porcelain(try cli.run(tolerant, snapshotDir: snap))
        #expect(after["mode"] == "incremental")
        #expect(after["uncertain"] == "0", "\(after)")
    }
}
