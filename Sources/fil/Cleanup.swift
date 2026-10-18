import CleanCore
import Foundation
import ScanCore

// fil list [--home DIR] [--json] [--timings] [--no-color]
// fil clean <candidate-id|rule-id>... [--home DIR] [--yes] [--json] [--timings] [--no-color]
func runCleanup(_ command: String, _ arguments: [String]) async throws {
    var args = CommandLineWords(arguments)
    var givenHome = NSHomeDirectory()
    var json = false
    var yes = false
    var timings = false
    var noColor = false
    var selectors: [String] = []
    let isList = command == "list"
    while let word = args.next() {
        switch word {
        case .option("--home"): givenHome = args.value(for: "--home")
        case .option("--timings"): timings = true
        case .option("--no-color"): noColor = true
        case .option("--json"): json = true
        case .option("--yes") where !isList: yes = true
        case .option(let a): unknownOption(a, command)
        case .operand(let a) where isList: usageError("unexpected argument '\(a)' for 'fil list'")
        case .operand(let a): selectors.append(a)
        }
    }
    if !isList && selectors.isEmpty { usageError("clean needs at least one candidate id or rule id") }

    UI.setup(noColor: noColor)
    let home = try resolveDirectory(givenHome)
    let clock = ContinuousClock()
    let start = clock.now
    func phase(_ name: String, _ since: ContinuousClock.Instant, _ extra: String = "") {
        if timings {
            FileHandle.standardError.write(
                Data(
                    "  \(name.padding(toLength: 22, withPad: " ", startingAt: 0))\(ms(clock.now - since))\(extra)\n"
                        .utf8))
        }
    }
    // Tolerant hard links (see docs/design/04-cleanup.md): an unknown old hard link is counted and reported as uncertain.
    let options = ScanOptions(strictHardlinks: false)
    // The simctl query runs while the tree loads and updates.
    // A dry run writes nothing: no snapshot, no tool-paths.json (chapter 05 §6.2, #13).
    let dryRun = command == "clean" && !yes
    let simulators = Cleanup.startToolQueries(home: home, writesPathCache: !dryRun)
    var tree: DiskTree?
    var unchanged = false
    var t = clock.now
    let loaded = Snapshot.load(rootPath: home, privateSize: options.privateSize)
    if case .failure(let why) = loaded { phase("snapshot load", t, "  (not used: \(why); full scan)") }
    if case .success(let cached) = loaded {
        phase("snapshot load", t)
        t = clock.now
        switch Incremental.update(cached, options: options) {
        case .success(let report):
            tree = cached
            unchanged = !report.treeChanged
            phase(
                "incremental update", t,
                "  (\(report.events) events"
                    + (report.uncertainBytes > 0 ? ", \(report.uncertainBytes) uncertain bytes" : "") + ")")
        case .failure(let why):
            phase("incremental update", t, "  (not usable: \(why); full scan)")
        }
    }
    t = clock.now
    let scanned = try tree ?? withPath(home) { try Scanner.scan(home, options: options) }
    if tree == nil { phase("full scan", t) }
    t = clock.now
    if !dryRun, !(unchanged && Snapshot.advance(scanned)) { saveSnapshot(scanned) }
    phase("snapshot save", t, unchanged ? "  (advance only)" : "")
    t = clock.now
    let scan = await Cleanup.scan(home: home, tree: scanned, simulators: simulators)
    phase("rules total", t)
    if timings {
        for r in scan.ruleTimes {
            FileHandle.standardError.write(
                Data(
                    String(
                        format: "    %@ %.1f ms\n", r.rule.padding(toLength: 24, withPad: " ", startingAt: 0),
                        r.seconds * 1000
                    ).utf8))
        }
    }
    let elapsed = clock.now - start
    phase("total", start)

    func removalText(_ r: Removal) -> String {
        switch r {
        case .trash: return "trash"
        case .command(let argv): return argv.joined(separator: " ")
        case .none: return "info only"
        }
    }

    if command == "list" {
        if json {
            let items: [[String: Any]] = scan.candidates.map {
                [
                    "id": $0.id, "rule": $0.ruleId, "path": $0.path, "bytes": $0.bytes, "safety": $0.safety.rawValue,
                    "note": $0.note?.description as Any? ?? NSNull(), "removal": removalText($0.removal),
                ]
            }
            try printJSON(["home": scan.home, "candidates": items])
            return
        }
        func row(_ c: Candidate) -> String {
            let note = c.note.map { UI.dim("  (\($0))") } ?? ""
            return "  " + UI.lpad(human(c.bytes), 9) + "  " + UI.safety(c.safety) + "  " + UI.tilde(c.path) + note
        }
        print(UI.bold("Cleanup candidates") + "  " + UI.tilde(scan.home))
        for rule in Rules.all {
            let items = scan.candidates.filter { $0.ruleId == rule.id }
            guard !items.isEmpty else { continue }
            let total = items.reduce(Int64(0)) { $0 + $1.bytes }
            print(
                "\n" + UI.bold(rule.title) + "  " + UI.bold(human(total))
                    + UI.dim("  \(items.count) item\(items.count == 1 ? "" : "s") · \(rule.id)"))
            print(UI.dim("  " + rule.explanation))
            for c in items {
                print(row(c));
                print(UI.dim("  " + String(repeating: " ", count: 9) + "  id \(c.id) -> \(removalText(c.removal))"))
            }
        }
        for s in scan.skippedCommands { print("\n" + UI.yellow("Skipped: \(s)")) }
        let total = scan.candidates.filter { $0.removal.isInfoOnly == false }.reduce(Int64(0)) { $0 + $1.bytes }
        print("\n" + UI.bold("Total removable  \(human(total))") + UI.dim("  (\(humanDuration(elapsed)))"))
        print(UI.dim("Move items to the Trash with: fil clean <id|rule> --yes"))
        return
    }

    // clean
    let resolution: Cleanup.Resolution
    do { resolution = try Cleanup.resolve(selectors, in: scan.candidates) } catch { fail("\(error)") }
    let chosen = resolution.chosen
    let leftOut = resolution.leftOut
    if json && !yes {
        try printJSON(cleanJSON(home: scan.home, dryRun: true, chosen.map { ($0, nil) }, leftOut: leftOut))
        return
    }
    if !yes {
        print(UI.bold("Would clean") + "  " + UI.tilde(scan.home))
        for c in chosen {
            let target: String
            switch c.removal {
            case .trash: target = "Trash"
            case .command(let argv): target = "would run: " + argv.joined(separator: " ")
            case .none: target = "info only"
            }
            print(
                "  " + UI.lpad(human(c.bytes), 9) + "  " + UI.safety(c.safety) + "  " + c.id + UI.dim("  -> \(target)"))
        }
        for c in leftOut where !chosen.contains(where: { $0.id == c.id }) {
            print(
                "  " + UI.lpad(human(c.bytes), 9) + "  " + UI.safety(c.safety) + "  " + c.id
                    + UI.dim("  not selected, name its id to remove"))
        }
        var trashBytes: Int64 = 0, commandBytes: Int64 = 0
        var trashCount = 0, commandCount = 0
        for c in chosen {
            switch c.removal {
            case .trash: trashBytes += c.bytes; trashCount += 1
            case .command: commandBytes += c.bytes; commandCount += 1
            case .none: break
            }
        }
        print("")
        if trashCount > 0 {
            print(
                UI.bold("Would move \(human(trashBytes)) to the Trash") + "; space is freed once the Trash is emptied.")
        }
        if commandCount > 0 {
            print(
                UI.yellow(
                    "Would remove \(human(commandBytes)) permanently with the tools' own commands; this cannot be undone from the Trash."
                ))
        }
        if trashCount == 0 && commandCount == 0 { print("Nothing to clean among the selected items.") }
        print(UI.yellow("Dry run, nothing changed; add --yes to do it."))
        return
    }
    var moved: Int64 = 0
    var removed: Int64 = 0
    var movedCount = 0, removedCount = 0
    var handled = 0
    var failures = 0
    // Ctrl-C: the removal commands run in their own session and no longer get the terminal's SIGINT, so cancel
    // the execute task; that stops the running command (SIGTERM, then SIGKILL).
    // The handler is installed before the task exists, so a Ctrl-C in between is not lost.
    let canceller = TaskCanceller()
    // Source first, then SIG_IGN: a Ctrl-C in the setup gap takes the default action instead of being lost.
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler { canceller.cancel() }
    interrupt.resume()
    signal(SIGINT, SIG_IGN)
    let work = Task { await Cleanup.executeReporting(chosen, home: scan.home) }
    canceller.attach(work)
    let (executed, interrupted) = await work.value
    interrupt.cancel()
    if json {
        // stdout holds only the JSON document; the reason for a non-zero exit goes to stderr.
        try printJSON(cleanJSON(home: scan.home, dryRun: false, executed.map { ($0, $1) }, leftOut: leftOut))
        let failed = executed.filter { if case .failed = $0.1 { true } else { false } }.count
        if interrupted {
            FileHandle.standardError.write(Data("fil: interrupted; the remaining items were not touched\n".utf8))
            exit(130)
        }
        if failed != 0 {
            FileHandle.standardError.write(Data("fil: \(failed) item\(failed == 1 ? "" : "s") failed\n".utf8))
            exit(3)
        }
        return
    }
    for (c, outcome) in executed {
        switch outcome {
        case .trashed(let url):
            moved += c.bytes
            movedCount += 1
            handled += 1
            print("  " + UI.green("✓") + " " + UI.lpad(human(c.bytes), 9) + "  \(c.id)" + UI.dim("  -> \(url.path)"))
        case .commandRan:
            removed += c.bytes
            removedCount += 1
            handled += 1
            let argv: String
            if case .command(let a) = c.removal { argv = a.joined(separator: " ") } else { argv = "command" }
            print(
                "  " + UI.green("✓") + " " + UI.lpad(human(c.bytes), 9) + "  \(c.id)"
                    + UI.dim("  ran: \(argv) (permanent)"))
        case .commandShared:
            removed += c.bytes
            removedCount += 1
            handled += 1
            print(
                "  " + UI.green("✓") + " " + UI.lpad(human(c.bytes), 9) + "  \(c.id)"
                    + UI.dim("  done by the same command"))
        case .nothingToDo:
            print(
                "  " + UI.dim("-") + " " + UI.lpad("", 9) + "  \(c.id)"
                    + UI.dim("  nothing to do\(c.note.map { " (\($0))" } ?? "")"))
        case .failed(let why):
            failures += 1
            print(
                "  " + UI.red("✗") + " " + UI.lpad(human(c.bytes), 9) + "  \(c.id)"
                    + UI.red("  failed: \(why.description)"))
        }
    }
    let skippedCareful = leftOut.filter { c in !chosen.contains(where: { $0.id == c.id }) }
    if handled == 0 {
        print(
            chosen.isEmpty
                ? "Nothing was cleaned: no safe or review items matched."
                : "Nothing was cleaned.")
    } else {
        print("")
        if movedCount > 0 {
            print(
                UI.bold("Moved \(human(moved)) to the Trash")
                    + " (\(movedCount) item\(movedCount == 1 ? "" : "s")). Space is freed when you empty the Trash.")
        }
        if removedCount > 0 {
            print(
                UI.bold("Removed \(human(removed)) permanently")
                    + " with the tools' own commands (\(removedCount) item\(removedCount == 1 ? "" : "s")).")
        }
    }
    if !skippedCareful.isEmpty {
        print("Left out \(skippedCareful.count) careful item(s); name a candidate id to remove it:")
        for c in skippedCareful { print("  " + UI.lpad(human(c.bytes), 9) + "  " + UI.safety(c.safety) + "  \(c.id)") }
    }
    if interrupted {
        print(UI.yellow("Interrupted; the remaining items were not touched."))
        exit(130)
    }
    if failures != 0 {
        print(UI.red("\(failures) item\(failures == 1 ? "" : "s") failed."))
        exit(3)
    }
}

/// Prints `object` the way every `--json` output is printed: pretty, keys sorted, one trailing newline
/// (chapter 05 §5.4).
func printJSON(_ object: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

/// The `clean --json` document (chapter 05 §6.4). `items` pairs each chosen candidate with its outcome; a nil
/// outcome is a dry run. Keys are only ever added, never removed or retyped.
func cleanJSON(home: String, dryRun: Bool, _ items: [(Candidate, Cleanup.Outcome?)], leftOut: [Candidate])
    -> [String: Any]
{
    var trashBytes: Int64 = 0, commandBytes: Int64 = 0
    var handled = 0, failed = 0
    let rows: [[String: Any]] = items.map { c, outcome in
        var argv: Any = NSNull()
        var trashPath: Any = NSNull()
        var error: Any = NSNull()
        let removal: String
        switch c.removal {
        case .trash: removal = "trash"
        case .command(let a): removal = a.joined(separator: " "); argv = a
        case .none: removal = "info only"
        }
        let name: String
        switch outcome {
        case nil:
            switch c.removal {
            case .trash: name = "planned"; trashBytes += c.bytes; handled += 1
            case .command: name = "planned"; commandBytes += c.bytes; handled += 1
            case .none: name = "info-only"
            }
        case .trashed(let url)?:
            name = "trashed"; trashPath = url.path; trashBytes += c.bytes; handled += 1
        case .commandRan?: name = "ran"; commandBytes += c.bytes; handled += 1
        case .commandShared?: name = "shared"; commandBytes += c.bytes; handled += 1
        case .nothingToDo?: name = "nothing"
        case .failed(let why)?: name = "failed"; error = why.description; failed += 1
        }
        return [
            "id": c.id, "rule": c.ruleId, "path": c.path, "bytes": c.bytes, "safety": c.safety.rawValue,
            "removal": removal, "argv": argv, "outcome": name, "trashPath": trashPath, "error": error,
        ]
    }
    // Careful items of a named rule that were not chosen, each once.
    var seen = Set(items.map { $0.0.id })
    let left: [[String: Any]] = leftOut.compactMap { c in
        guard seen.insert(c.id).inserted else { return nil }
        return ["id": c.id, "rule": c.ruleId, "path": c.path, "bytes": c.bytes, "safety": c.safety.rawValue]
    }
    return [
        "dryRun": dryRun, "home": home, "items": rows, "leftOut": left,
        "totals": ["trashBytes": trashBytes, "commandBytes": commandBytes, "handled": handled, "failed": failed],
    ]
}

extension Removal {
    var isInfoOnly: Bool { if case .none = self { return true } else { return false } }
}

/// Cancels a task that may not exist yet when the signal arrives.
private final class TaskCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<(results: [(Candidate, Cleanup.Outcome)], stoppedEarly: Bool), Never>?
    private var requested = false

    func attach(_ t: Task<(results: [(Candidate, Cleanup.Outcome)], stoppedEarly: Bool), Never>) {
        let now = lock.withLock { () -> Bool in
            task = t; return requested
        }
        if now { t.cancel() }
    }

    func cancel() {
        let t = lock.withLock { () -> Task<(results: [(Candidate, Cleanup.Outcome)], stoppedEarly: Bool), Never>? in
            requested = true
            return task
        }
        t?.cancel()
    }
}
