import Darwin
import Foundation
import Testing
@testable import fil

/// A dry run `fil clean` writes nothing (chapter 05 §6.2, #13); `--yes` output labels what it did (#8).
@Suite struct DryRunTests {
    let cli = ErrorHandlingTests()

    func makeHome(_ root: String) throws {
        let dir = root + "/home/Library/Logs/foo"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data(count: 2_000_000).write(to: URL(fileURLWithPath: dir + "/f"))
    }

    func contents(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
    }

    @Test func dryRunLeavesSnapshotDirectoryEmpty() throws {
        let root = try ErrorHandlingTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeHome(root)
        let snap = root + "/snap"
        try FileManager.default.createDirectory(atPath: snap, withIntermediateDirectories: true)

        let dry = try cli.run(["clean", "logs:Library/Logs/foo", "--home", root + "/home"], snapshotDir: snap)
        #expect(dry.status == 0, "\(dry.stderr)")
        #expect(dry.stdout.contains("Would clean"))
        #expect(dry.stdout.contains("-> Trash"))
        #expect(dry.stdout.contains("Would move"))
        #expect(!dry.stdout.contains("permanently"), "a Trash-only run must not warn about permanent removal")
        #expect(dry.stdout.contains("Dry run, nothing changed; add --yes to do it."))
        #expect(contents(snap).isEmpty, "a dry run wrote \(contents(snap))")
        // The folder is untouched.
        #expect(FileManager.default.fileExists(atPath: root + "/home/Library/Logs/foo/f"))

        // Control: `fil list` does save the snapshot, so the check above can fail.
        let list = try cli.run(["list", "--home", root + "/home"], snapshotDir: snap)
        #expect(list.status == 0, "\(list.stderr)")
        #expect(!contents(snap).isEmpty)
    }
}
