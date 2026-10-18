import Foundation
import ScanCore

// fil scan [DIR] [-j N] [--private] [--full] [--top N] [--naive] [--porcelain] [--tolerant-hardlinks]
// Hard links are strict by default (an unknown old multiply-linked file makes the update fall back to a full
// scan); --tolerant-hardlinks counts it and reports `uncertain=` bytes, as the app does.
func runScan(_ arguments: [String]) throws {
    var args = arguments
    var path = NSHomeDirectory()
    var options = ScanOptions()
    var top = 15
    var naive = false
    var forceFull = false
    var porcelain = false

    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "-j": options.threads = Int(takeValue(&args, a)) ?? options.threads
        case "--private": options.privateSize = true
        case "--top": top = Int(takeValue(&args, a)) ?? top
        case "--naive": naive = true
        case "--full": forceFull = true
        case "--porcelain": porcelain = true
        case "--tolerant-hardlinks": options.strictHardlinks = false
        default:
            if a.hasPrefix("-") { usageError("unknown option \(a) for 'fil scan'", help: scanHelp) }
            path = (a as NSString).standardizingPath
        }
    }

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
    var usedIncremental = false
    var unchanged = false
    var tree: DiskTree?

    if !forceFull {
        let loadStart = clock.now
        if let cached = Snapshot.load(rootPath: path, privateSize: options.privateSize) {
            let loadTime = clock.now - loadStart
            switch Incremental.update(cached, options: options) {
            case .success(let report):
                tree = cached
                usedIncremental = true
                unchanged = report.events == 0
                mode = "incremental: load \(ms(loadTime)), \(report.events) events in \(ms(report.historyTime)), "
                    + "apply \(ms(report.applyTime)) (\(report.dirsRead) dirs re-read, "
                    + "\(report.subtreesScanned) subtrees walked, \(report.dirsRemoved) removed)"
            case .failure(let why):
                mode = "full scan (incremental not usable: \(why))"
                // Not with --porcelain, whose output must stay one line.
                if !porcelain, case .unattributedHardLink(let paths) = why {
                    for p in paths { print("  unattributed hard link: \(p)") }
                }
            }
        }
    }
    let scanned = try tree ?? Scanner.scan(path, options: options)
    let scanTime = clock.now - start
    let saveStart = clock.now
    // An incremental update with no events left the tree untouched: only the event id moves.
    if !(unchanged && Snapshot.advance(scanned)) { try Snapshot.save(scanned) }
    let saveTime = clock.now - saveStart

    let nodes = scanned.nodes
    let r = scanned.root
    let s = scanned.stats

    if porcelain {
        print("mode=\(usedIncremental ? "incremental" : "full") alloc=\(r.totalAlloc) logical=\(r.totalLogical) "
            + "files=\(r.totalFiles) dirs=\(r.totalDirs + 1)"
            + (options.strictHardlinks ? "" : " uncertain=\(scanned.uncertainBytes)"))
        return
    }

    print("""
    \(scanned.rootPath)
      on disk  \(human(r.totalAlloc))   (logical \(human(r.totalLogical)))
      files    \(r.totalFiles)   dirs \(r.totalDirs + 1)
      time     \(ms(scanTime))   [\(mode)]   snapshot saved in \(ms(saveTime))
    """)
    if scanned.uncertainBytes > 0 { print("  uncertain  \(human(scanned.uncertainBytes)) (hard links that may be counted twice)") }
    if mode.hasPrefix("full") {
        print("  skipped  denied \(s.openErrors)  errors \(s.entryErrors)  hardlinks \(s.hardlinkDupes)  mounts \(s.mountsSkipped)  cloud-dirs \(s.datalessDirs) (cloud-files \(human(s.datalessLogical)))")
    }

    guard top > 0 else { return }

    // Largest directories, skipping a parent when one child holds ≥90% of its size.
    var biggestChild = [Int64](repeating: 0, count: nodes.count)
    for i in nodes.indices.dropFirst() {
        let p = Int(nodes[i].parent)
        biggestChild[p] = max(biggestChild[p], nodes[i].totalAlloc)
    }
    let ranked = nodes.indices.dropFirst()
        .filter { nodes[$0].totalAlloc > r.totalAlloc / 200 && biggestChild[$0] * 10 < nodes[$0].totalAlloc * 9 }
        .sorted { nodes[$0].totalAlloc > nodes[$1].totalAlloc }
        .prefix(top)

    print("\nLargest directories:")
    for id in ranked {
        print(human(nodes[id].totalAlloc).padding(toLength: 12, withPad: " ", startingAt: 0) + scanned.path(of: id))
    }
}
