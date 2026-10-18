import CleanCore
import Darwin
import Foundation
import ScanCore

/// Why a folder could not be read.
enum UnreadableKind: Equatable {
    /// Protected by macOS privacy (TCC): Full Disk Access of the terminal app lifts it.
    case privacyProtected
    /// Owned by another user (or root) with POSIX permissions that exclude us; Full Disk Access does not help.
    case otherUser
    /// Our own folder with permissions that exclude us (for example mode 000).
    case noPermission
    /// Listed only in part (a read error); its size is a lower bound.
    case incomplete
}

enum Permissions {
    /// Paths (relative to the home folder) that macOS protects with TCC, besides the system ones below.
    static let protectedHomeFolders = ["Library", "Pictures", "Desktop", "Documents", "Downloads", "Movies", "Music"]
    static let protectedSystemPrefixes = ["/private/var/db", "/var/db", "/Library/Application Support/com.apple.TCC"]

    /// `ownerUID` is the folder's owner when known. A folder in a TCC-protected place counts as privacy-protected
    /// whoever owns it, except another user's home, which never matches `home`.
    static func classify(
        _ path: String, ownerUID: uid_t?, home: String = NSHomeDirectory(),
        myUID: uid_t = getuid()
    ) -> UnreadableKind {
        func under(_ prefix: String) -> Bool { path == prefix || path.hasPrefix(prefix + "/") }
        if protectedSystemPrefixes.contains(where: under) { return .privacyProtected }
        if protectedHomeFolders.contains(where: { under(home + "/" + $0) }) { return .privacyProtected }
        if let owner = ownerUID, owner != myUID { return .otherUser }
        return .noPermission
    }

    /// The unreadable and incomplete folders of a scan with their kind, privacy-protected first, incomplete last, then
    /// shallow before deep.
    static func unreadable(in tree: DiskTree, home: String = NSHomeDirectory()) -> [(
        path: String, kind: UnreadableKind
    )] {
        var out: [(path: String, kind: UnreadableKind)] = []
        for i in tree.nodes.indices
        where (tree.nodes[i].unreadable || tree.nodes[i].incomplete) && !tree.nodes[i].isDead {
            let path = tree.path(of: i)
            if !tree.nodes[i].unreadable {
                out.append((path, .incomplete))
                continue
            }
            var st = stat()
            let owner: uid_t? = stat(path, &st) == 0 ? st.st_uid : nil
            out.append((path, classify(path, ownerUID: owner, home: home)))
        }
        func rank(_ k: UnreadableKind) -> Int {
            switch k {
            case .privacyProtected: 0
            case .otherUser: 1
            case .noPermission: 2
            case .incomplete: 3
            }
        }
        return out.sorted {
            let (a, b) = (rank($0.kind), rank($1.kind))
            if a != b { return a < b }
            let (da, db) = ($0.path.split(separator: "/").count, $1.path.split(separator: "/").count)
            return da != db ? da < db : $0.path < $1.path
        }
    }

    /// The warning block for `fil scan`: empty when nothing was unreadable.
    static func warningLines(
        _ items: [(path: String, kind: UnreadableKind)], terminalName: String?,
        shown: Int = 5
    ) -> [String] {
        guard !items.isEmpty else { return [] }
        let n = items.count
        var lines =
            items.contains(where: { $0.kind == .incomplete })
            ? [
                "\(n) folder\(n == 1 ? "" : "s") could not be read fully; sizes below \(n == 1 ? "it are" : "them are") too low."
            ]
            : [
                "\(n) folder\(n == 1 ? "" : "s") could not be read (permission denied); sizes below \(n == 1 ? "it are" : "them are") missing."
            ]
        for item in items.prefix(shown) {
            let note: String
            switch item.kind {
            case .privacyProtected: note = ""
            case .otherUser: note = "  (owned by another user)"
            case .noPermission: note = "  (no permission)"
            case .incomplete: note = "  (could not be read completely)"
            }
            lines.append("  " + UI.tilde(item.path) + note)
        }
        if n > shown { lines.append("  … and \(n - shown) more") }
        if items.contains(where: { $0.kind == .privacyProtected }) {
            lines.append("Give \(terminalName ?? "your terminal app") Full Disk Access: run `fil doctor`")
        }
        if items.contains(where: { $0.kind == .otherUser }) {
            lines.append(
                "Folders owned by another user cannot be read without their permission; Full Disk Access does not change that."
            )
        }
        return lines
    }
}

/// Finding the terminal app that macOS holds responsible for this process.
enum ResponsibleApp {
    /// The outermost `.app` bundle in an executable path: `/A/Code.app/Contents/Frameworks/H.app/Contents/MacOS/H`
    /// gives `/A/Code.app`. Nil when the path is in no bundle.
    static func outermostBundle(in path: String) -> String? {
        var prefix = ""
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            prefix += "/" + part
            if part.hasSuffix(".app"), part.count > 4 { return prefix }
        }
        return nil
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(decoding: buffer[..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
    }

    /// Walks from this process up to launchd; the app bundle nearest to launchd wins (the terminal, not a helper).
    static func find() -> (bundlePath: String, name: String)? {
        var pid = getpid()
        var found: String?
        var steps = 0
        while pid > 1, steps < 64 {
            if let path = executablePath(of: pid), let bundle = outermostBundle(in: path) { found = bundle }
            guard let parent = parentPID(of: pid), parent != pid else { break }
            pid = parent
            steps += 1
        }
        guard let bundle = found else { return nil }
        return (bundle, displayName(ofBundleAt: bundle))
    }

    static func displayName(ofBundleAt path: String) -> String {
        let info = Bundle(path: path)?.infoDictionary
        if let name = info?["CFBundleName"] as? String, !name.isEmpty { return name }
        if let name = info?["CFBundleDisplayName"] as? String, !name.isEmpty { return name }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

/// Full Disk Access probe. Only a process with Full Disk Access can open the user TCC database or list
/// ~/Library/Safari; everyone else gets EPERM (or EACCES). ENOENT means the probe file is absent (inconclusive).
enum FullDiskAccess {
    enum Status: Equatable { case granted, denied, unknown }

    static func probe(home: String = NSHomeDirectory()) -> Status {
        let tcc = home + "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(tcc, O_RDONLY)
        if fd >= 0 { close(fd); return .granted }
        if errno == EPERM || errno == EACCES { return .denied }
        if let dir = opendir(home + "/Library/Safari") { closedir(dir); return .granted }
        if errno == EPERM || errno == EACCES { return .denied }
        return .unknown
    }
}

let fdaSettingsURL = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"

let doctorHelp = """
    Usage: fil doctor [--no-open] [--no-color]

    Checks whether the terminal app running fil has Full Disk Access. Without it, folders such as
    ~/Library/Mail, ~/Library/Containers/*, ~/Pictures/Photos Library and /private/var/db cannot be read and
    scan sizes come out too low. A command-line tool cannot request the permission itself and `sudo` does not
    help: macOS grants it to the terminal app (Terminal, iTerm2, Ghostty, Warp, VS Code, ...).

      --no-open    only print; do not open System Settings
      --no-color   plain output

    Exit status 0 when Full Disk Access is granted, 1 otherwise.
    """

func runDoctor(_ arguments: [String]) async -> Never {
    var open = true
    var noColor = false
    var args = CommandLineWords(arguments)
    while let word = args.next() {
        switch word {
        case .option("--no-open"): open = false
        case .option("--no-color"): noColor = true
        case .option(let a), .operand(let a): unknownOption(a, "doctor")
        }
    }
    UI.setup(noColor: noColor)
    let app = ResponsibleApp.find()
    let name = app?.name ?? "your terminal app"
    switch FullDiskAccess.probe() {
    case .granted:
        print(UI.green("✓") + " Full Disk Access is granted to \(name).")
        exit(0)
    case .unknown:
        print(UI.yellow("?") + " Could not tell whether \(name) has Full Disk Access (the probe files do not exist).")
        exit(1)
    case .denied:
        print(UI.red("✗") + " \(name) does not have Full Disk Access.")
        print(
            """

            Without it, protected folders (~/Library/Mail, ~/Library/Containers, Photos Library, /private/var/db)
            are skipped and scan sizes are too low. `sudo` does not help.

            1. Open System Settings → Privacy & Security → Full Disk Access.
            2. Turn on \(name) (use + to add it if it is not listed).
            3. Quit and reopen \(name), then run `fil doctor` again.
            """)
        if open {
            print("\nOpening System Settings…")
            let r = await SystemCommandRunner().run(["/usr/bin/open", fdaSettingsURL], timeout: .seconds(10))
            if case .success = r {} else { print(UI.yellow("Could not open System Settings; open it by hand.")) }
        }
        exit(1)
    }
}
