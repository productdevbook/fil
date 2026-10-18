import Foundation

let version = "0.1.1"

let mainHelp = """
Usage: fil <command> [options]

Commands:
  scan [DIR]    Scan a directory and print its size (default: home folder)
  list          List cleanup candidates in the home folder
  clean <id>... Move cleanup candidates to the Trash (dry run unless --yes)
  help [cmd]    Show help for a command

Options:
  --help, -h    Show this help
  --version     Print the version

Run 'fil help <command>' for details.
"""

let scanHelp = """
Usage: fil scan [DIR] [-j N] [--private] [--full] [--top N] [--naive] [--porcelain] [--tolerant-hardlinks]
           [-v] [--no-color]

  DIR                   directory to scan (default: home folder)
  -j N                  worker threads
  --private             size in private (non-shared) bytes
  --full                ignore the snapshot and scan from scratch
  --top N               list the N largest directories (0 = none, default 15)
  --naive               time a plain FileManager walk instead
  --porcelain           one machine-readable line
  --tolerant-hardlinks  count unknown hard links and report them as uncertain
  -v, --verbose         show timing details and skipped-entry counts
  --no-color            plain output (also when NO_COLOR is set or stdout is not a terminal)

Output is styled only on a terminal. --porcelain output never changes.
"""

let listHelp = """
Usage: fil list [--home DIR] [--json] [--no-color]

  --home DIR   use DIR instead of the home folder
  --json       machine-readable output
  --no-color   plain output (also when NO_COLOR is set or stdout is not a terminal)
"""

let cleanHelp = """
Usage: fil clean <candidate-id|rule-id>... [--home DIR] [--yes] [--no-color]

  --home DIR   use DIR instead of the home folder
  --yes        actually move the items to the Trash (default: dry run)
  --no-color   plain output (also when NO_COLOR is set or stdout is not a terminal)
"""

func helpText(for command: String) -> String? {
    switch command {
    case "scan": return scanHelp
    case "list": return listHelp
    case "clean": return cleanHelp
    default: return nil
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func usageError(_ msg: String, help: String = mainHelp) -> Never {
    FileHandle.standardError.write(Data((msg + "\n\n" + help + "\n").utf8))
    exit(2)
}

/// The value after an option; a missing one is a usage error.
func takeValue(_ args: inout [String], _ option: String) -> String {
    guard !args.isEmpty else { usageError("\(option) needs a value") }
    return args.removeFirst()
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else { usageError("missing command") }
let command = arguments.removeFirst()
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
    if arguments.contains("--help") || arguments.contains("-h") { print(scanHelp); exit(0) }
    try runScan(arguments)
case "list", "clean":
    if arguments.contains("--help") || arguments.contains("-h") { print(helpText(for: command)!); exit(0) }
    try await runCleanup(command, arguments)
default:
    usageError("unknown command '\(command)'")
}
