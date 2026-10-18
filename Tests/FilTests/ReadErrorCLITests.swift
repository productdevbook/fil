import Darwin
import Foundation
import Testing

/// `fil scan` with test faults (`FIL_TEST_FAULTS`, honoured by debug builds only).
extension ErrorHandlingTests {
    @Test func incompleteFolderIsCountedAndListed() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/root/x", withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: URL(fileURLWithPath: dir + "/root/x/a"))
        try Data(count: 10).write(to: URL(fileURLWithPath: dir + "/root/b"))
        let env = ["FIL_TEST_FAULTS": "bulk \(EIO) \(dir)/root/x"]

        let p = try run(["scan", dir + "/root", "--full", "--porcelain"], snapshotDir: dir + "/snap", env: env)
        #expect(p.status == 0)
        #expect(p.stdout.hasSuffix(" unreadable=1\n"), "\(p.stdout)")
        #expect(p.stdout.contains(" files=1 "), "\(p.stdout)")

        let h = try run(["scan", dir + "/root", "--full", "--top", "0"], snapshotDir: dir + "/snap", env: env)
        #expect(h.status == 0)
        #expect(h.stdout.contains("\n1 folder could not be read fully; sizes below it are too low.\n"), "\(h.stdout)")
        #expect(h.stdout.contains("\n  \(dir)/root/x  (could not be read completely)\n"), "\(h.stdout)")
        #expect(!h.stdout.contains("fil doctor"))
        let v = try run(["scan", dir + "/root", "--full", "--top", "0", "-v"], snapshotDir: dir + "/snap", env: env)
        #expect(v.stdout.contains("denied 0 "), "\(v.stdout)")

        let clean = try run(["scan", dir + "/root", "--full", "--porcelain"], snapshotDir: dir + "/snap")
        #expect(clean.stdout.hasSuffix(" unreadable=0\n"), "\(clean.stdout)")
    }
}
