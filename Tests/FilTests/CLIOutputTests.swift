import Darwin
import Foundation
import Testing
@testable import fil

/// `list --json` keys, colour switches and the `clean` dry run versus `--yes` text. Only fixture homes are used,
/// with `FIL_SNAPSHOT_DIR` set; `--yes` is run on an info-only item, so nothing reaches the real Trash.
@Suite struct CLIOutputTests {
    let cli = ErrorHandlingTests()
    static let esc = "\u{1b}["

    func makeHome(_ root: String) throws {
        let fm = FileManager.default
        for dir in ["home/Library/Logs/foo", "home/Library/Caches/com.apple.bird", "home/.Trash/x"] {
            try fm.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true)
            try Data(count: 2_000_000).write(to: URL(fileURLWithPath: root + "/" + dir + "/f"))
        }
    }

    /// Runs `fil` on a pseudo terminal (`script`), the only way to see the colour-on path from a test.
    func runOnTerminal(_ args: [String], snapshotDir: String, env extra: [String: String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", ErrorHandlingTests.binary.path] + args
        var env = ProcessInfo.processInfo.environment
        env["FIL_SNAPSHOT_DIR"] = snapshotDir
        env["TERM"] = "xterm-256color"
        env.removeValue(forKey: "NO_COLOR")
        env.merge(extra) { _, new in new }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func listJSONHasTheDocumentedKeys() throws {
        let root = try ErrorHandlingTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeHome(root)
        let r = try cli.run(["list", "--json", "--home", root + "/home"], snapshotDir: root + "/snap")
        #expect(r.status == 0, "\(r.stderr)")
        let top = try #require(try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any])
        #expect(Set(top.keys) == ["home", "candidates"])
        #expect(top["home"] as? String == root + "/home")
        let items = try #require(top["candidates"] as? [[String: Any]])
        #expect(items.count >= 3)
        for item in items {
            #expect(Set(item.keys) == ["id", "rule", "path", "bytes", "safety", "note", "removal"], "\(item)")
            #expect(item["id"] is String && item["rule"] is String && item["path"] is String)
            #expect(item["bytes"] is NSNumber)
            #expect(["safe", "review", "careful"].contains(item["safety"] as? String ?? ""))
            #expect(item["note"] is String || item["note"] is NSNull)
            #expect(item["removal"] is String)
        }
        let logs = try #require(items.first { $0["id"] as? String == "logs:Library/Logs/foo" })
        #expect(logs["note"] is NSNull)
        #expect(logs["removal"] as? String == "trash")
        let trash = try #require(items.first { $0["id"] as? String == "trash:.Trash" })
        #expect(trash["removal"] as? String == "info only")
        #expect(trash["note"] is String)
        #expect(r.stdout.contains(Self.esc) == false)
    }

    @Test func nonTerminalOutputIsPlain() throws {
        let root = try ErrorHandlingTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeHome(root)
        // NO_COLOR empty counts as unset; the pipe alone keeps the output plain.
        let r = try cli.run(["list", "--home", root + "/home"], snapshotDir: root + "/snap", env: ["NO_COLOR": ""])
        #expect(r.status == 0, "\(r.stderr)")
        #expect(r.stdout.contains("Cleanup candidates"))
        #expect(!r.stdout.contains(Self.esc))
    }

    @Test func colourOnATerminalUnlessSwitchedOff() throws {
        let root = try ErrorHandlingTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeHome(root)
        let args = ["list", "--home", root + "/home"]
        let snap = root + "/snap"
        let colored = try runOnTerminal(args, snapshotDir: snap, env: [:])
        try #require(colored.contains("Cleanup candidates"), "no output through the terminal: \(colored)")
        #expect(colored.contains(Self.esc), "control: a terminal gets colour")
        let noEnv = try runOnTerminal(args, snapshotDir: snap, env: ["NO_COLOR": "1"])
        #expect(noEnv.contains("Cleanup candidates") && !noEnv.contains(Self.esc), "NO_COLOR=1")
        let noFlag = try runOnTerminal(args + ["--no-color"], snapshotDir: snap, env: [:])
        #expect(noFlag.contains("Cleanup candidates") && !noFlag.contains(Self.esc), "--no-color")
        let dumb = try runOnTerminal(args, snapshotDir: snap, env: ["TERM": "dumb"])
        #expect(dumb.contains("Cleanup candidates") && !dumb.contains(Self.esc), "TERM=dumb")
    }

    @Test func dryRunAndYesPrintDifferentText() throws {
        let root = try ErrorHandlingTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeHome(root)
        let snap = root + "/snap"

        let dry = try cli.run(["clean", "trash", "--home", root + "/home"], snapshotDir: snap)
        #expect(dry.status == 0, "\(dry.stderr)")
        #expect(dry.stdout.contains("Would clean"))
        #expect(dry.stdout.contains("trash:.Trash"))
        #expect(dry.stdout.contains("info only"))
        #expect(dry.stdout.contains("Nothing to clean among the selected items."))
        #expect(dry.stdout.contains("Dry run, nothing changed; add --yes to do it."))

        let yes = try cli.run(["clean", "trash", "--home", root + "/home", "--yes"], snapshotDir: snap)
        #expect(yes.status == 0, "\(yes.stderr)")
        #expect(!yes.stdout.contains("Would clean"))
        #expect(!yes.stdout.contains("Dry run"))
        #expect(yes.stdout.contains("trash:.Trash"))
        #expect(yes.stdout.contains("nothing to do"))
        #expect(yes.stdout.contains("Nothing was cleaned."))
        let after = (try? FileManager.default.contentsOfDirectory(atPath: root + "/home/.Trash/x")) ?? []
        #expect(after == ["f"], "an info-only item is never removed")
    }

    @Test func usageErrorsExitTwo() throws {
        let root = try ErrorHandlingTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let snap = root + "/snap"
        let cases: [([String], String)] = [
            (["list", "--bogus"], "fil: unknown option --bogus for 'fil list'\nRun 'fil help list' for usage.\n"),
            (
                ["clean", "logs", "--bogus"],
                "fil: unknown option --bogus for 'fil clean'\nRun 'fil help clean' for usage.\n"
            ),
            (["scan", "--top"], "fil: --top needs a value\nRun 'fil help scan' for usage.\n"),
            (["scan", "-j"], "fil: -j needs a value\nRun 'fil help scan' for usage.\n"),
        ]
        for (args, message) in cases {
            let r = try cli.run(args, snapshotDir: snap)
            #expect(r.status == 2, "\(args): \(r.status)")
            #expect(r.stdout.isEmpty, "\(args)")
            #expect(r.stderr == message, "\(args): \(r.stderr)")
        }
    }
}
