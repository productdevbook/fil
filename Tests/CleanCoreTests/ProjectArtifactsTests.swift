import CleanCore
import Foundation
import Testing
import TestSupport

@Suite("project-artifacts and the Trash")
struct ProjectArtifactsTrashTests {
    @Test("a project in the Trash gives no project-artifacts candidate; the same project outside still does")
    func ignoresTrash() async throws {
        let f = try Fixture(label: "home")
        defer { f.remove() }
        try f.mk(".Trash/old/package.json", bytes: 20)
        try f.mk(".Trash/old/node_modules/f", bytes: 4_000_000)
        try f.mk(".Trash/rust/Cargo.toml", bytes: 20)
        try f.mk(".Trash/rust/target/f", bytes: 2_000_000)
        try f.mk("proj/package.json", bytes: 20)
        try f.mk("proj/node_modules/f", bytes: 4_000_000)
        let scan = try await scanCandidates(f)
        let artifacts = scan.candidates.filter { $0.ruleId == "project-artifacts" }.map(\.id)
        #expect(artifacts == ["project-artifacts:proj/node_modules"])
        // The Trash itself is still reported once, as information only.
        #expect(scan.candidates.contains { $0.id == "trash:.Trash" })
    }
}
