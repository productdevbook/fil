import CleanCore
import Darwin
import Foundation
import Testing
@testable import fil

/// `fil clean --json` against the schema of chapter 05 §6.4, for a dry run and `--yes`. Only fixture homes are
/// used, with `FIL_SNAPSHOT_DIR` set; `--yes` runs only on an info-only item or an item whose move fails, so
/// nothing reaches the real Trash.
@Suite struct CleanJSONTests {
    let cli = ErrorHandlingTests()

    static let itemKeys: Set<String> = [
        "id", "rule", "path", "bytes", "safety", "removal", "argv", "outcome", "trashPath", "error",
    ]
    static let leftOutKeys: Set<String> = ["id", "rule", "path", "bytes", "safety"]
    static let totalsKeys: Set<String> = ["trashBytes", "commandBytes", "handled", "failed"]

    func makeHome(_ root: String) throws {
        let dirs = ["home/Library/Logs/foo", "home/.Trash/x", "home/Library/Developer/Xcode/Archives/a.xcarchive"]
        for dir in dirs {
            try FileManager.default.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true)
            try Data(count: 2_000_000).write(to: URL(fileURLWithPath: root + "/" + dir + "/f"))
        }
    }

    /// A JSON integer (not a boolean, not a fraction).
    static func isInteger(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
        return n.doubleValue == n.doubleValue.rounded()
    }

    static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// Decodes `text` and checks every key and type of §6.4; returns the top-level object.
    static func decode(_ text: String, outcomes: Set<String>) throws -> [String: Any] {
        let top = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(top.keys) == ["dryRun", "home", "items", "leftOut", "totals"])
        #expect(isBool(top["dryRun"]))
        #expect(top["home"] is String)
        let items = try #require(top["items"] as? [[String: Any]])
        for item in items {
            #expect(Set(item.keys) == itemKeys, "\(item)")
            #expect(item["id"] is String && item["rule"] is String && item["path"] is String)
            #expect(isInteger(item["bytes"]))
            #expect(["safe", "review", "careful"].contains(item["safety"] as? String ?? ""))
            #expect(item["removal"] is String)
            #expect(item["argv"] is NSNull || item["argv"] is [String])
            #expect(outcomes.contains(item["outcome"] as? String ?? ""), "\(item)")
            #expect(item["trashPath"] is NSNull || item["trashPath"] is String)
            #expect(item["error"] is NSNull || item["error"] is String)
        }
        let leftOut = try #require(top["leftOut"] as? [[String: Any]])
        for item in leftOut {
            #expect(Set(item.keys) == leftOutKeys, "\(item)")
            #expect(item["id"] is String && item["rule"] is String && item["path"] is String)
            #expect(isInteger(item["bytes"]))
            #expect(item["safety"] is String)
        }
        let totals = try #require(top["totals"] as? [String: Any])
        #expect(Set(totals.keys) == totalsKeys)
        for key in totalsKeys { #expect(isInteger(totals[key]), "\(key)") }
        return top
    }

    @Test func dryRunMatchesTheSchema() throws {
        let root = try ErrorHandlingTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeHome(root)
        let snap = root + "/snap"
        let home = root + "/home"
        let before = (try? FileManager.default.contentsOfDirectory(atPath: snap)) ?? []
        let r = try cli.run(["clean", "logs", "trash", "xcode-archives", "--json", "--home", home], snapshotDir: snap)
        #expect(r.status == 0, "\(r.stderr)")
        #expect(r.stdout.hasPrefix("{") && r.stdout.hasSuffix("}\n"), "only the JSON document on stdout")
        let top = try Self.decode(r.stdout, outcomes: ["planned", "info-only"])
        #expect(top["dryRun"] as? Bool == true)
        #expect(top["home"] as? String == home)
        let items = try #require(top["items"] as? [[String: Any]])
        #expect(items.map { $0["id"] as? String } == ["logs:Library/Logs/foo", "trash:.Trash"], "selection order")
        #expect(items.map { $0["outcome"] as? String } == ["planned", "info-only"])
        #expect(items[0]["path"] as? String == home + "/Library/Logs/foo")
        #expect(items[0]["argv"] is NSNull && items[0]["trashPath"] is NSNull && items[0]["error"] is NSNull)
        #expect(items[1]["removal"] as? String == "info only")
        let leftOut = try #require(top["leftOut"] as? [[String: Any]])
        #expect(leftOut.map { $0["id"] as? String } == ["xcode-archives:Library/Developer/Xcode/Archives/a.xcarchive"])
        #expect(leftOut.first?["safety"] as? String == "careful")
        let totals = try #require(top["totals"] as? [String: Any])
        let logsBytes = try #require(items[0]["bytes"] as? Int64)
        #expect(totals["trashBytes"] as? Int64 == logsBytes)
        #expect(totals["commandBytes"] as? Int64 == 0)
        #expect(totals["handled"] as? Int == 1)
        #expect(totals["failed"] as? Int == 0)
        #expect(!r.stdout.contains("\u{1b}["))
        // A dry run moves nothing and writes no snapshot.
        #expect(FileManager.default.fileExists(atPath: home + "/Library/Logs/foo/f"))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: snap)) ?? []) == before)
    }

    @Test func yesMatchesTheSchema() throws {
        let root = try ErrorHandlingTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeHome(root)
        let home = root + "/home"
        let r = try cli.run(["clean", "trash", "--yes", "--json", "--home", home], snapshotDir: root + "/snap")
        #expect(r.status == 0, "\(r.stderr)")
        let top = try Self.decode(r.stdout, outcomes: ["trashed", "ran", "shared", "nothing", "failed"])
        #expect(top["dryRun"] as? Bool == false)
        let items = try #require(top["items"] as? [[String: Any]])
        #expect(items.map { $0["outcome"] as? String } == ["nothing"])
        #expect((top["leftOut"] as? [Any])?.isEmpty == true)
        let totals = try #require(top["totals"] as? [String: Any])
        #expect(totals["handled"] as? Int == 0 && totals["failed"] as? Int == 0)
        #expect(FileManager.default.fileExists(atPath: home + "/.Trash/x/f"), "an info-only item is never removed")
    }

    @Test func failedItemExitsThreeWithValidJSON() throws {
        guard getuid() != 0 else { return }  // root ignores the permission bits
        let root = try ErrorHandlingTests.tempDir()
        defer {
            chmod(root + "/home/Library/Logs", 0o755)
            try? FileManager.default.removeItem(atPath: root)
        }
        try makeHome(root)
        let home = root + "/home"
        // A read-only parent makes the move fail, so nothing reaches the Trash.
        #expect(chmod(home + "/Library/Logs", 0o555) == 0)
        let r = try cli.run(["clean", "logs", "trash", "--yes", "--json", "--home", home], snapshotDir: root + "/snap")
        #expect(r.status == 3, "\(r.stdout)\(r.stderr)")
        #expect(r.stderr == "fil: 1 item failed\n", "\(r.stderr)")
        let top = try Self.decode(r.stdout, outcomes: ["trashed", "ran", "shared", "nothing", "failed"])
        let items = try #require(top["items"] as? [[String: Any]])
        #expect(items.map { $0["outcome"] as? String } == ["failed", "nothing"])
        #expect((items[0]["error"] as? String)?.isEmpty == false)
        #expect(items[0]["trashPath"] is NSNull)
        let totals = try #require(top["totals"] as? [String: Any])
        #expect(totals["failed"] as? Int == 1 && totals["handled"] as? Int == 0)
        #expect(FileManager.default.fileExists(atPath: home + "/Library/Logs/foo/f"))
    }

    @Test func errorsPrintNothingOnStdout() throws {
        let root = try ErrorHandlingTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeHome(root)
        let snap = root + "/snap"
        let home = ["--home", root + "/home"]
        let usage = try cli.run(["clean", "--json"] + home, snapshotDir: snap)
        #expect(usage.status == 2)
        #expect(usage.stdout.isEmpty)
        let unknown = try cli.run(["clean", "logs", "--json", "--bogus"] + home, snapshotDir: snap)
        #expect(unknown.status == 2)
        #expect(unknown.stdout.isEmpty)
        let none = try cli.run(["clean", "no-such-rule", "--json", "--yes"] + home, snapshotDir: snap)
        #expect(none.status == 1)
        #expect(none.stdout.isEmpty)
        #expect(none.stderr == "fil: nothing matches 'no-such-rule'\n")
    }

    /// Outcomes a fixture cannot reach without the real Trash or a tool: trashed, ran and shared.
    @Test func everyOutcomeEncodesWithTheSchemaTypes() throws {
        let argv = ["/usr/bin/true", "x"]
        let trash = Candidate(id: "logs:a", ruleId: "logs", path: "/h/a", bytes: 10, safety: .safe)
        let cmd1 = Candidate(
            id: "go:1", ruleId: "pkg-caches", path: "/h/g", bytes: 20, safety: .safe,
            removal: .command(argv: argv))
        let cmd2 = Candidate(
            id: "go:2", ruleId: "pkg-caches", path: "/h/g2", bytes: 30, safety: .review,
            removal: .command(argv: argv))
        let failed = Candidate(id: "logs:b", ruleId: "logs", path: "/h/b", bytes: 40, safety: .safe)
        let doc = cleanJSON(
            home: "/h", dryRun: false,
            [
                (trash, .trashed(URL(fileURLWithPath: "/h/.Trash/a"))), (cmd1, .commandRan), (cmd2, .commandShared),
                (failed, .failed(.pathChanged)),
            ], leftOut: [])
        let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        let top = try Self.decode(
            String(decoding: data, as: UTF8.self), outcomes: ["trashed", "ran", "shared", "nothing", "failed"])
        let items = try #require(top["items"] as? [[String: Any]])
        #expect(items.map { $0["outcome"] as? String } == ["trashed", "ran", "shared", "failed"])
        #expect(items[0]["trashPath"] as? String == "/h/.Trash/a")
        #expect(items[1]["argv"] as? [String] == argv)
        #expect(items[1]["removal"] as? String == "/usr/bin/true x")
        #expect(items[3]["error"] as? String == Cleanup.Failure.pathChanged.description)
        let totals = try #require(top["totals"] as? [String: Any])
        #expect(totals["trashBytes"] as? Int64 == 10)
        #expect(totals["commandBytes"] as? Int64 == 50)
        #expect(totals["handled"] as? Int == 3)
        #expect(totals["failed"] as? Int == 1)

        let dry = cleanJSON(home: "/h", dryRun: true, [(trash, nil), (cmd1, nil)], leftOut: [])
        let dryTotals = try #require(dry["totals"] as? [String: Any])
        #expect(dryTotals["trashBytes"] as? Int64 == 10 && dryTotals["commandBytes"] as? Int64 == 20)
        #expect(dryTotals["handled"] as? Int == 2)
    }
}
