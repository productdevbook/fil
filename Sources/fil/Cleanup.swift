import CleanCore
import Foundation
import ScanCore

// fil list [--home DIR] [--json]
// fil clean <candidate-id|rule-id>... [--home DIR] [--yes]
func runCleanup(_ command: String, _ arguments: [String]) async throws {
    var args = arguments
    var home = NSHomeDirectory()
    var json = false
    var yes = false
    var timings = false
    var selectors: [String] = []
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--home":
            guard !args.isEmpty else { fail("--home needs a directory") }
            home = (args.removeFirst() as NSString).standardizingPath
        case "--json": json = true
        case "--yes": yes = true
        case "--timings": timings = true
        default:
            if a.hasPrefix("-") { usageError("unknown option \(a) for 'fil \(command)'", help: command == "list" ? listHelp : cleanHelp) }
            selectors.append(a)
        }
    }

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
    if let cached = Snapshot.load(rootPath: home, privateSize: options.privateSize) {
        phase("snapshot load", t)
        t = clock.now
        switch Incremental.update(cached, options: options) {
        case .success(let report):
            tree = cached
            unchanged = report.events == 0
            phase("incremental update", t, "  (\(report.events) events"
                + (report.uncertainBytes > 0 ? ", \(report.uncertainBytes) uncertain bytes" : "") + ")")
        case .failure(let why):
            phase("incremental update", t, "  (not usable: \(why); full scan)")
        }
    }
    t = clock.now
    let scanned = try tree ?? Scanner.scan(home, options: options)
    if tree == nil { phase("full scan", t) }
    t = clock.now
    if !(unchanged && Snapshot.advance(scanned)) { try Snapshot.save(scanned) }
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
        print("Home: \(scan.home)")
        print("\nCategories:")
        for rule in Rules.all {
            let items = scan.candidates.filter { $0.ruleId == rule.id }
            guard !items.isEmpty else { continue }
            let total = items.reduce(Int64(0)) { $0 + $1.bytes }
            print("  " + human(total).padding(toLength: 10, withPad: " ", startingAt: 0)
                  + rule.id.padding(toLength: 24, withPad: " ", startingAt: 0) + "\(items.count) item(s)  \(rule.title)")
            print("             " + rule.explanation)
        }
        print("\nCandidates (largest first):")
        for c in scan.candidates {
            let mark = c.safety == .safe ? "[safe]   " : c.safety == .review ? "[review] " : "[CAREFUL]"
            let rel = c.path.hasPrefix(scan.home + "/") ? "~/" + c.path.dropFirst(scan.home.count + 1) : c.path
            print("  " + human(c.bytes).padding(toLength: 10, withPad: " ", startingAt: 0) + mark + " " + rel
                  + (c.note.map { "  (\($0))" } ?? ""))
            print("             \(c.id)  ->  \(removalText(c.removal))")
        }
        for s in scan.skippedCommands { print("\nSkipped: \(s)") }
        let total = scan.candidates.filter { $0.removal.isInfoOnly == false }.reduce(Int64(0)) { $0 + $1.bytes }
        print("\nTotal removable: \(human(total))   (\(ms(elapsed)))")
        return
    }

    // clean
    guard !selectors.isEmpty else { fail("clean needs at least one candidate id or rule id") }
    let resolution: Cleanup.Resolution
    do { resolution = try Cleanup.resolve(selectors, in: scan.candidates) } catch { fail("\(error)") }
    let chosen = resolution.chosen
    let leftOut = resolution.leftOut
    if !yes {
        print("Dry run (add --yes to do it):")
        for c in chosen {
            print("  \(human(c.bytes).padding(toLength: 10, withPad: " ", startingAt: 0))\(c.id)  ->  \(removalText(c.removal))")
        }
        for c in leftOut where !chosen.contains(where: { $0.id == c.id }) {
            print("  NOT selected (careful, name its id to remove): \(human(c.bytes))  \(c.id)")
        }
        print("Would free \(human(chosen.reduce(Int64(0)) { $0 + $1.bytes })) once the Trash is emptied.")
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
            print("  moved to Trash  \(human(c.bytes))  \(c.id)  -> \(url.path)")
        case .commandRan:
            moved += c.bytes
            handled += 1
            print("  ran command     \(human(c.bytes))  \(c.id)")
        case .commandShared:
            moved += c.bytes
            handled += 1
            print("  done by the same command  \(human(c.bytes))  \(c.id)")
        case .nothingToDo:
            print("  nothing to do   \(c.id)\(c.note.map { " (\($0))" } ?? "")")
        case .failed(let why):
            failures += 1
            print("  FAILED          \(c.id): \(why.description)")
        }
    }
    let skippedCareful = leftOut.filter { c in !chosen.contains(where: { $0.id == c.id }) }
    if handled == 0 {
        print(chosen.isEmpty ? "Nothing was cleaned: no safe or review items matched."
                             : "Nothing was cleaned.")
    } else {
        print("Handled \(human(moved)) in \(handled) item(s). Space is freed when you empty the Trash.")
    }
    if !skippedCareful.isEmpty {
        print("Left out \(skippedCareful.count) careful item(s); name a candidate id to remove it:")
        for c in skippedCareful { print("  \(human(c.bytes).padding(toLength: 10, withPad: " ", startingAt: 0))\(c.id)") }
    }
    if failures != 0 { exit(2) }
}

extension Removal {
    var isInfoOnly: Bool { if case .none = self { return true } else { return false } }
}
