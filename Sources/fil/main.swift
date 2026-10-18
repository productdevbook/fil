import Foundation
import ScanCore

let version = "0.2.0"

let mainHelp = """
    Usage: fil <command> [options]

    Commands:
      scan [DIR]          Scan a directory and print its size (default: home folder)
      doctor              Check Full Disk Access for the terminal app
      list                List cleanup candidates in the home folder
      clean <id|rule>...  Clean candidates (dry run unless --yes)
      help [command]      Show help for a command

    Options:
      --help, -h          Show this help
      --version, -V       Print the version

    Exit status:
      0  success
      1  error (doctor: Full Disk Access missing or unknown)
      2  usage error
      3  clean --yes: one or more items failed

    Run 'fil help <command>' for details.
    """

let scanHelp = """
    Usage: fil scan [DIR] [-j N] [--private] [--full] [--top N] [--naive] [--porcelain] [--tolerant-hardlinks]
               [-q] [-v] [--no-color]

      DIR                   directory to scan (default: home folder)
      -j N                  worker threads
      --private             size in private (non-shared) bytes
      --full                ignore the snapshot and scan from scratch
      --top N               list the N largest directories (0 = none, default 15)
      --naive               time a plain FileManager walk instead
      --porcelain           one machine-readable line
      --tolerant-hardlinks  count unknown hard links and report them as uncertain
      -q, --quiet           no warning about folders that could not be read
      -v, --verbose         show timing details and skipped-entry counts
      --no-color            plain output (also when NO_COLOR is set or stdout is not a terminal)

    Sizes are on-disk bytes with each APFS clone family counted once; a scan of / counts each firmlinked
    directory once (see docs/design/02-size-accounting.md). Output is styled only on a terminal. --porcelain fields
    are only ever appended: alloc= stays du-compatible, cloneaware= is the clone-aware size and shared= the
    bytes du counts again for clones (not with --private); unreadable= is the number of folders that
    could not be read (permission denied). If some were privacy-protected, scan points to `fil doctor` (Full Disk
    Access for the terminal app).

    Exit status: 0 success, 1 error (DIR missing or not a directory), 2 usage error.
    """

let listHelp = """
    Usage: fil list [--home DIR] [--json] [--timings] [--no-color]

      --home DIR   use DIR instead of the home folder
      --json       machine-readable output
      --timings    phase and rule timings on stderr
      --no-color   plain output (also when NO_COLOR is set or stdout is not a terminal)

    Exit status: 0 success, 1 error, 2 usage error.
    """

let cleanHelp = """
    Usage: fil clean <candidate-id|rule-id>... [--home DIR] [--yes] [--json] [--timings] [--no-color]

      --home DIR   use DIR instead of the home folder
      --yes        clean for real (default: dry run)
      --json       machine-readable output
      --timings    phase and rule timings on stderr
      --no-color   plain output (also when NO_COLOR is set or stdout is not a terminal)

    A rule id selects its safe and review items; name a careful item by its candidate id. Most items move to
    the Trash; some rules run the tool's own removal command, which is permanent (shown as "would run:").

    Exit status: 0 success, 1 error (nothing matches), 2 usage error, 3 one or more items failed.
    """

func helpText(for command: String) -> String? {
    switch command {
    case "doctor": return doctorHelp
    case "scan": return scanHelp
    case "list": return listHelp
    case "clean": return cleanHelp
    default: return nil
    }
}

/// A runtime error with its final message; printed as `fil: <message>`, exit 1.
struct CLIError: Error, CustomStringConvertible {
    let description: String
}

/// The text after `fil: ` for an error: `description` for our own error types, `strerror` for POSIX errors
/// (also when a system error wraps one), else `localizedDescription`; the path goes in front when known.
func errorMessage(_ error: Error, path: String? = nil) -> String {
    var path = path
    let text: String
    if let e = error as? POSIXError {
        text = String(cString: strerror(e.code.rawValue))
    } else if !(error is CocoaError), !(type(of: error) is NSError.Type),
        let e = error as Any as? CustomStringConvertible
    {
        text = e.description
    } else {
        let ns = error as NSError
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain {
            text = String(cString: strerror(Int32(under.code)))
            path = path ?? ns.userInfo[NSFilePathErrorKey] as? String
        } else {
            text =
                ns.localizedDescription.hasSuffix(".")
                ? String(ns.localizedDescription.dropLast())
                : ns.localizedDescription
        }
    }
    return path.map { "\($0): \(text)" } ?? text
}

/// Runs `body`; an error it throws becomes a `CLIError` naming `path`.
func withPath<T>(_ path: String, _ body: () throws -> T) throws -> T {
    do { return try body() } catch let e as CLIError { throw e } catch {
        throw CLIError(description: errorMessage(error, path: path))
    }
}

/// Saves the snapshot; a failure is only a warning, since the result is correct and only the cache is missing.
func saveSnapshot(_ tree: DiskTree) {
    do { try Snapshot.save(tree) } catch {
        warn("could not save the snapshot (\(errorMessage(error))); the next run does a full scan")
    }
}

/// Prints `fil: warning: <msg>` on stderr.
func warn(_ msg: String) {
    FileHandle.standardError.write(Data("fil: warning: \(msg)\n".utf8))
}

/// Prints `fil: <msg>` on stderr and exits 1.
func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("fil: \(msg)\n".utf8))
    exit(1)
}

/// The command being run, for the usage hint; nil until one is recognised.
nonisolated(unsafe) var currentCommand: String?

/// Prints `fil: <msg>` and a pointer to the help on stderr and exits 2.
func usageError(_ msg: String) -> Never {
    let hint = currentCommand.map { "Run 'fil help \($0)' for usage." } ?? "Run 'fil --help' for usage."
    FileHandle.standardError.write(Data("fil: \(msg)\n\(hint)\n".utf8))
    exit(2)
}

/// One word of a command line after the command.
enum Word: Equatable {
    case option(String)
    case operand(String)
}

/// Reads the words after the command in order.
struct CommandLineWords {
    private var words: [String]
    private var optionsEnded = false

    init(_ words: [String]) { self.words = words }

    /// The next word, or nil at the end. A word starting with `-` is an option, until `--`: that word is
    /// dropped and every later one is an operand.
    mutating func next() -> Word? {
        while !words.isEmpty {
            let w = words.removeFirst()
            if optionsEnded { return .operand(w) }
            if w == "--" {
                optionsEnded = true
                continue
            }
            return w.hasPrefix("-") ? .option(w) : .operand(w)
        }
        return nil
    }

    /// The word after `option`, taken as is; a missing one is a usage error.
    mutating func value(for option: String) -> String {
        guard !words.isEmpty else { usageError("\(option) needs a value") }
        return words.removeFirst()
    }
}

/// Whether `--help` or `-h` comes before any `--`.
func wantsHelp(_ words: [String]) -> Bool {
    words.prefix { $0 != "--" }.contains { $0 == "--help" || $0 == "-h" }
}

/// `unknown option <opt> for 'fil <command>'`, exit 2.
func unknownOption(_ option: String, _ command: String) -> Never {
    usageError("unknown option \(option) for 'fil \(command)'")
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else { usageError("missing command") }
let command = arguments.removeFirst()
if helpText(for: command) != nil { currentCommand = command }
do {
    switch command {
    case "--help", "-h":
        print(mainHelp)
    case "--version", "-V":
        print("fil \(version)")
    case "help":
        if let name = arguments.first {
            guard let text = helpText(for: name) else { usageError("unknown command '\(name)'") }
            print(text)
        } else {
            print(mainHelp)
        }
    case "scan":
        if wantsHelp(arguments) { print(scanHelp); exit(0) }
        try runScan(arguments)
    case "doctor":
        if wantsHelp(arguments) { print(doctorHelp); exit(0) }
        await runDoctor(arguments)
    case "list", "clean":
        if wantsHelp(arguments) { print(helpText(for: command)!); exit(0) }
        try await runCleanup(command, arguments)
    default:
        usageError("unknown command '\(command)'")
    }
} catch {
    fail(errorMessage(error))
}
