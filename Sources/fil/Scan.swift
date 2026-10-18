import Foundation
import ScanCore

// fil scan [DIR] [-j N] [--private] [--full] [--top N] [--naive] [--porcelain] [--tolerant-hardlinks] [-v] [--no-color]
// Hard links are strict by default (an unknown old multiply-linked file makes the update fall back to a full
// scan); --tolerant-hardlinks counts it and reports `uncertain=` bytes, as the app does.
func runScan(_ arguments: [String]) throws {
    var args = arguments
    var given = NSHomeDirectory()
    var options = ScanOptions()
    var top = 15
    var naive = false
    var forceFull = false
    var porcelain = false
    var verbose = false
    var quiet = false
    var noColor = false

    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "-j": options.threads = Int(takeValue(&args, a)) ?? options.threads
        case "--private": options.privateSize = true
        case "--top": top = Int(takeValue(&args, a)) ?? top
        case "--naive": naive = true
        case "--full": forceFull = true
        case "--porcelain": porcelain = true
        case "-q", "--quiet": quiet = true
        case "-v", "--verbose": verbose = true
        case "--no-color": noColor = true
        case "--tolerant-hardlinks": options.strictHardlinks = false
        default:
            if a.hasPrefix("-") { usageError("unknown option \(a) for 'fil scan'") }
            given = a
        }
    }

    UI.setup(noColor: noColor)
    let path = try resolveDirectory(given)

    if naive {
        // What most cleaner apps do: FileManager enumerator + per-file resource values.
        let start = ContinuousClock.now
        var total: Int64 = 0, files = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        if let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys,
                                                  options: [], errorHandler: { _, _ in true }) {
            for case let url as URL in e {
                if let v = try? url.resourceValues(forKeys: Set(keys)), v.isDirectory != true {
                    total += Int64(v.totalFileAllocatedSize ?? 0)
                    files += 1
                }
            }
        }
        print("naive  \(human(total))  \(files) files  \(ms(ContinuousClock.now - start))")
        return
    }

    let clock = ContinuousClock()
    let start = clock.now
    var mode = "full scan"
    var summary = "full scan"
    var unattributed: [String] = []
    let liveProgress = ScanProgress()
    let spinner = Progress(label: "Scanning", progress: liveProgress)
    if !porcelain { spinner.start() }
    var usedIncremental = false
    var unchanged = false
    var tree: DiskTree?

    if !forceFull {
        let loadStart = clock.now
        let loaded = Snapshot.load(rootPath: path, options: options)
        // A tolerant run (`fil list`, `--tolerant-hardlinks`) may have left bytes that are perhaps counted twice; a
        // strict scan never presents that tree as exact. The full scan's tree starts again at 0.
        if let cached = loaded, options.strictHardlinks && cached.uncertainBytes > 0 {
            mode = "full scan (snapshot has uncertain bytes)"
        } else if let cached = loaded {
            let loadTime = clock.now - loadStart
            switch Incremental.update(cached, options: options) {
            case .success(let report):
                tree = cached
                usedIncremental = true
                // Labelled by what the update did to the tree: events outside it change nothing, while a mount or
                // unmount (no event) does.
                unchanged = !report.treeChanged
                let changes = report.events + report.mountChanges
                summary = unchanged ? "up to date from snapshot"
                    : "updated from snapshot, \(count(Int64(changes))) change\(changes == 1 ? "" : "s")"
                mode = "incremental: load \(ms(loadTime)), \(report.events) events in \(ms(report.historyTime)), "
                    + (report.mountChanges > 0 ? "\(report.mountChanges) mount changes, " : "")
                    + "apply \(ms(report.applyTime)) (\(report.dirsRead) dirs re-read, "
                    + "\(report.subtreesScanned) subtrees walked, \(report.dirsRemoved) removed)"
            case .failure(let why):
                mode = "full scan (incremental not usable: \(why))"
                // Not with --porcelain, whose output must stay one line.
                if case .unattributedHardLink(let paths) = why { unattributed = paths }
            }
        }
    }
    let scanned: DiskTree
    do {
        scanned = try tree ?? withPath(path) { try Scanner.scan(path, options: options, progress: liveProgress) }
    } catch {
        spinner.finish()
        throw error
    }
    let scanTime = clock.now - start
    spinner.finish()
    let saveStart = clock.now
    // An incremental update with no events left the tree untouched: only the event id moves.
    if !(unchanged && Snapshot.advance(scanned)) { saveSnapshot(scanned) }
    let saveTime = clock.now - saveStart

    let nodes = scanned.nodes
    let r = scanned.root
    let s = scanned.stats

    // Allocated bytes shared by full clones and counted once (du counts them per file). Not with --private,
    // where `alloc` is already private bytes.
    let shared = options.privateSize ? 0 : r.totalAlloc - r.totalCloneAware

    let unreadable = Permissions.unreadable(in: scanned)
    let unreadableCount = unreadable.count

    if porcelain {
        // New fields are only ever appended, so existing parsers keep working.
        print("mode=\(usedIncremental ? "incremental" : "full") alloc=\(r.totalAlloc) logical=\(r.totalLogical) "
            + "files=\(r.totalFiles) dirs=\(r.totalDirs + 1)"
            + (options.strictHardlinks ? "" : " uncertain=\(scanned.uncertainBytes)")
            + " cloneaware=\(r.totalCloneAware)" + (options.privateSize ? "" : " shared=\(shared)")
            + " unreadable=\(unreadableCount)")
        return
    }

    for p in unattributed { print("  unattributed hard link: \(p)") }
    // Ranked and shown by real usage: clone-aware bytes, or private bytes with --private.
    let size: (DirNode) -> Int64 = options.privateSize ? { $0.totalAlloc } : { $0.totalCloneAware }
    let total = size(r)
    print(UI.bold(UI.tilde(scanned.rootPath)) + "  " + UI.bold(human(total)) + UI.dim(options.privateSize ? " private" : " on disk"))
    print(UI.dim("\(human(r.totalLogical)) logical · \(count(r.totalFiles)) files · \(count(r.totalDirs + 1)) folders · "
        + "\(humanDuration(scanTime)) · \(summary)"))
    if shared > 0 {
        print(UI.dim("\(human(shared)) shared by clones, counted once (du without clone dedupe: \(human(r.totalAlloc)))"))
    }
    if scanned.uncertainBytes > 0 {
        print(UI.yellow("\(human(scanned.uncertainBytes)) uncertain (hard links that may be counted twice)"))
    }
    if verbose {
        print(UI.dim("""

        timing   \(ms(scanTime)) [\(mode)]
                 snapshot saved in \(ms(saveTime))
        """))
        // After an update the counters are the last full scan's, labelled as such (chapter 03 §9); `denied` is the
        // current number of unreadable folders. A snapshot without them shows none.
        let skipped: (label: String, denied: Int)? = !usedIncremental ? ("skipped", s.openErrors)
            : scanned.fullScanStart.map { ("skipped (as of full scan at \(lastKnownTime($0)))", unreadableCount) }
        if let skipped {
            print(UI.dim("\(skipped.label)  denied \(skipped.denied) · errors \(s.entryErrors) · hardlinks \(s.hardlinkDupes) · mounts \(s.mountsSkipped) · cloud-dirs \(s.datalessDirs) (cloud files \(human(s.datalessLogical)))"))
            print(UI.dim("         firmlinked data dirs \(s.firmlinksSkipped) · clone files counted once \(s.cloneDupes)"))
        }
    }

    defer {
        if !quiet {
            let lines = Permissions.warningLines(unreadable, terminalName: ResponsibleApp.find()?.name)
            if !lines.isEmpty { print("\n" + lines.map { UI.yellow($0) }.joined(separator: "\n")) }
        }
    }
    guard top > 0, total > 0 else { return }

    // Largest directories, skipping a parent when one child holds >= 90% of its size.
    var biggestChild = [Int64](repeating: 0, count: nodes.count)
    for i in nodes.indices.dropFirst() {
        let p = Int(nodes[i].parent)
        biggestChild[p] = max(biggestChild[p], size(nodes[i]))
    }
    let ranked = nodes.indices.dropFirst()
        .filter { !nodes[$0].isDead && size(nodes[$0]) > total / 200 && biggestChild[$0] * 10 < size(nodes[$0]) * 9 }
        .sorted { size(nodes[$0]) > size(nodes[$1]) }
        .prefix(top)
    printTree(Array(ranked), nodes: nodes, total: total, size: size)
}

/// Prints `ids` as a tree: each directory sits under its nearest listed ancestor, children ordered by size.
/// A name is the path relative to that ancestor, so skipped intermediate folders show as "a/b".
private func printTree(_ ids: [Int], nodes: [DirNode], total: Int64, size: (DirNode) -> Int64) {
    let listed = Set(ids)
    var children: [Int: [Int]] = [:]
    var label: [Int: String] = [:]
    for id in ids {
        var parts = [nodes[id].name]
        var p = Int(nodes[id].parent)
        while p > 0, !listed.contains(p) {
            parts.append(nodes[p].name)
            p = Int(nodes[p].parent)
        }
        children[max(p, 0), default: []].append(id)
        label[id] = parts.reversed().joined(separator: "/")
    }
    for k in children.keys { children[k]!.sort { size(nodes[$0]) > size(nodes[$1]) } }

    print("\n" + UI.bold("Largest folders"))
    let fixed = 9 + 2 + 20 + 2 + 4 + 2  // size, bar, percent, gaps
    let termWidth = UI.width

    func walk(_ id: Int, prefix: String, last: Bool, depth: Int) {
        let bytes = size(nodes[id])
        let frac = Double(bytes) / Double(total)
        let guide = depth == 0 ? "" : prefix + (last ? "└─ " : "├─ ")
        let budget = max(8, termWidth - fixed - guide.count)
        let name = UI.truncate(label[id] ?? nodes[id].name, budget)
        let pct = frac < 0.005 ? "<1%" : String(format: "%.0f%%", locale: nil, frac * 100)
        print(UI.share(UI.lpad(human(bytes), 9), frac) + "  " + UI.share(UI.bar(frac), frac) + "  "
            + UI.lpad(pct, 4) + "  " + UI.dim(guide) + name)
        let kids = children[id] ?? []
        let childPrefix = depth == 0 ? "" : prefix + (last ? "   " : "│  ")
        for (i, k) in kids.enumerated() { walk(k, prefix: childPrefix, last: i == kids.count - 1, depth: depth + 1) }
    }
    let tops = children[0] ?? []
    for t in tops { walk(t, prefix: "", last: true, depth: 0) }
}

/// Resolves a directory argument with `realpath(3)` (symlinks, `.`, `..`, relative paths) and checks that it is
/// a directory. Errors name the argument as the user typed it: `fil: <arg>: No such file or directory`,
/// `fil: <arg>: not a directory`.
func resolveDirectory(_ arg: String) throws -> String {
    guard let resolved = realpath(arg, nil) else {
        throw CLIError(description: errorMessage(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO), path: arg))
    }
    defer { free(resolved) }
    let path = String(cString: resolved)
    var st = stat()
    guard stat(path, &st) == 0 else {
        throw CLIError(description: errorMessage(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO), path: arg))
    }
    guard (st.st_mode & S_IFMT) == S_IFDIR else { throw CLIError(description: "\(arg): not a directory") }
    return path
}
