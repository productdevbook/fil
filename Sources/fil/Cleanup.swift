import CleanCore
import Foundation
import ScanCore

// fil list [--home DIR] [--json]
// fil clean <candidate-id|rule-id>... [--home DIR] [--yes]
func runCleanup(_ command: String, _ arguments: [String]) async throws {
    var args = arguments
    var givenHome = NSHomeDirectory()
    var json = false
    var yes = false
    var timings = false
    var noColor = false
    var selectors: [String] = []
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--home":
            guard !args.isEmpty else { fail("--home needs a directory") }
            givenHome = args.removeFirst()
        case "--json": json = true
        case "--yes": yes = true
        case "--timings": timings = true
        case "--no-color": noColor = true
        default:
            if a.hasPrefix("-") { usageError("unknown option \(a) for 'fil \(command)'") }
            selectors.append(a)
        }
    }

    UI.setup(noColor: noColor)
    let home = try resolveDirectory(givenHome)
    let clock = ContinuousClock()
    let start = clock.now
    func phase(_ name: String, _ since: ContinuousClock.Instant, _ extra: String = "") {
        if timings { FileHandle.standardError.write(Data("  \(name.padding(toLength: 22, withPad: " ", startingAt: 0))\(ms(clock.now - since))\(extra)\n".utf8)) }
    }
    // Tolerant hard links, like the app: an unknown old hard link is counted and reported as uncertain.
    let options = ScanOptions(strictHardlinks: false)
    // The simctl query runs while the tree loads and updates.
    let simulators = Cleanup.startSimulatorQuery(home: home)
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
            phase("incremental update", t, "  (\(report.events) events"
                + (report.uncertainBytes > 0 ? ", \(report.uncertainBytes) uncertain bytes" : "") + ")")
        case .failure(let why):
            phase("incremental update", t, "  (not usable: \(why); full scan)")
        }
    }
    t = clock.now
    let scanned = try tree ?? withPath(home) { try Scanner.scan(home, options: options) }
    if tree == nil { phase("full scan", t) }
    t = clock.now
    if !(unchanged && Snapshot.advance(scanned)) { saveSnapshot(scanned) }
    phase("snapshot save", t, unchanged ? "  (advance only)" : "")
    t = clock.now
    let scan = await Cleanup.scan(home: home, tree: scanned, simulators: simulators)
    phase("rules total", t)
    if timings { for r in scan.ruleTimes { FileHandle.standardError.write(Data(String(format: "    %@ %.1f ms\n", r.rule.padding(toLength: 24, withPad: " ", startingAt: 0), r.seconds * 1000).utf8)) } }
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
                ["id": $0.id, "rule": $0.ruleId, "path": $0.path, "bytes": $0.bytes, "safety": $0.safety.rawValue,
                 "note": $0.note?.description as Any? ?? NSNull(), "removal": removalText($0.removal)]
            }
            let data = try JSONSerialization.data(withJSONObject: ["home": scan.home, "candidates": items],
                                                  options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
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
            print("\n" + UI.bold(rule.title) + "  " + UI.bold(human(total)) + UI.dim("  \(items.count) item\(items.count == 1 ? "" : "s") · \(rule.id)"))
            print(UI.dim("  " + rule.explanation))
            for c in items { print(row(c)); print(UI.dim("  " + String(repeating: " ", count: 9) + "  id \(c.id) -> \(removalText(c.removal))")) }
        }
        for s in scan.skippedCommands { print("\n" + UI.yellow("Skipped: \(s)")) }
        let total = scan.candidates.filter { $0.removal.isInfoOnly == false }.reduce(Int64(0)) { $0 + $1.bytes }
        print("\n" + UI.bold("Total removable  \(human(total))") + UI.dim("  (\(humanDuration(elapsed)))"))
        print(UI.dim("Move items to the Trash with: fil clean <id|rule> --yes"))
        return
    }

    // clean
    guard !selectors.isEmpty else { fail("clean needs at least one candidate id or rule id") }
    let resolution: Cleanup.Resolution
    do { resolution = try Cleanup.resolve(selectors, in: scan.candidates) } catch { fail("\(error)") }
    let chosen = resolution.chosen
    let leftOut = resolution.leftOut
    if !yes {
        print(UI.bold("Would move to the Trash") + "  " + UI.tilde(scan.home))
        for c in chosen {
            let target = c.removal.isInfoOnly ? "info only" : removalText(c.removal)
            print("  " + UI.lpad(human(c.bytes), 9) + "  " + UI.safety(c.safety) + "  " + c.id + UI.dim("  -> \(target)"))
        }
        for c in leftOut where !chosen.contains(where: { $0.id == c.id }) {
            print("  " + UI.lpad(human(c.bytes), 9) + "  " + UI.safety(c.safety) + "  " + c.id
                + UI.dim("  not selected, name its id to remove"))
        }
        print("\n" + UI.bold("Would free \(human(chosen.reduce(Int64(0)) { $0 + $1.bytes }))") + " once the Trash is emptied.")
        print(UI.yellow("Dry run, nothing moved; add --yes to do it."))
        return
    }
    var moved: Int64 = 0
    var handled = 0
    var failures = 0
    for (c, outcome) in await Cleanup.execute(chosen, home: scan.home) {
        switch outcome {
        case .trashed(let url):
            moved += c.bytes
            handled += 1
            print("  " + UI.green("✓") + " " + UI.lpad(human(c.bytes), 9) + "  \(c.id)" + UI.dim("  -> \(url.path)"))
        case .commandRan:
            moved += c.bytes
            handled += 1
            print("  " + UI.green("✓") + " " + UI.lpad(human(c.bytes), 9) + "  \(c.id)" + UI.dim("  ran command"))
        case .commandShared:
            moved += c.bytes
            handled += 1
            print("  " + UI.green("✓") + " " + UI.lpad(human(c.bytes), 9) + "  \(c.id)" + UI.dim("  done by the same command"))
        case .nothingToDo:
            print("  " + UI.dim("-") + " " + UI.lpad("", 9) + "  \(c.id)" + UI.dim("  nothing to do\(c.note.map { " (\($0))" } ?? "")"))
        case .failed(let why):
            failures += 1
            print("  " + UI.red("✗") + " " + UI.lpad(human(c.bytes), 9) + "  \(c.id)" + UI.red("  failed: \(why.description)"))
        }
    }
    let skippedCareful = leftOut.filter { c in !chosen.contains(where: { $0.id == c.id }) }
    if handled == 0 {
        print(chosen.isEmpty ? "Nothing was cleaned: no safe or review items matched."
                             : "Nothing was cleaned.")
    } else {
        print("\n" + UI.bold("Handled \(human(moved))") + " in \(handled) item\(handled == 1 ? "" : "s"). Space is freed when you empty the Trash.")
    }
    if !skippedCareful.isEmpty {
        print("Left out \(skippedCareful.count) careful item(s); name a candidate id to remove it:")
        for c in skippedCareful { print("  " + UI.lpad(human(c.bytes), 9) + "  " + UI.safety(c.safety) + "  \(c.id)") }
    }
    if failures != 0 { exit(2) }
}

extension Removal {
    var isInfoOnly: Bool { if case .none = self { return true } else { return false } }
}
