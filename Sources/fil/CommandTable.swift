import CleanCore
import Foundation

/// What follows an option on the command line.
enum OptionValue {
    /// A whole number (`-j N`); nothing to complete.
    case number(String)
    /// A directory (`--home DIR`); completes directories only.
    case directory(String)
}

struct OptionSpec {
    /// Every spelling, e.g. `["-q", "--quiet"]`.
    let names: [String]
    let value: OptionValue?
    let summary: String

    /// The spellings, then the summary as the last string: `OptionSpec("-q", "--quiet", "no warning")`.
    init(_ spellingsAndSummary: String..., value: OptionValue? = nil) {
        self.names = Array(spellingsAndSummary.dropLast())
        self.summary = spellingsAndSummary.last!
        self.value = value
    }
}

/// What a command takes as arguments, for completion.
enum Operands {
    case none
    case directory
    case ruleIDs
    case shells
    case commands
}

struct CommandSpec {
    let name: String
    /// The invocation as the main help shows it, e.g. `scan [DIR]`.
    let usage: String
    /// The one-line summary in the main help.
    let summary: String
    let operands: Operands
    let options: [OptionSpec]
}

let noColorOption = OptionSpec(
    "--no-color", "plain output (also when NO_COLOR is set or stdout is not a terminal)")
let homeOption = OptionSpec("--home", "use DIR instead of the home folder", value: .directory("DIR"))
let jsonOption = OptionSpec("--json", "machine-readable output")
let timingsOption = OptionSpec("--timings", "phase and rule timings on stderr")

/// The one table of commands and options (chapter 05 §8). The main help's command list and the completion
/// scripts are generated from it; `CompletionTests` checks that each command's `--help` shows the same options.
/// `-h` and `--help` are accepted by every command and are added by the generators.
let commandTable: [CommandSpec] = [
    CommandSpec(
        name: "scan", usage: "scan [DIR]", summary: "Scan a directory and print its size (default: home folder)",
        operands: .directory,
        options: [
            OptionSpec("-j", "worker threads", value: .number("N")),
            OptionSpec("--private", "size in private (non-shared) bytes"),
            OptionSpec("--full", "ignore the snapshot and scan from scratch"),
            OptionSpec("--top", "list the N largest directories (0 = none, default 15)", value: .number("N")),
            OptionSpec("--naive", "time a plain FileManager walk instead"),
            OptionSpec("--porcelain", "one machine-readable line"),
            OptionSpec("--tolerant-hardlinks", "count unknown hard links and report them as uncertain"),
            OptionSpec("-q", "--quiet", "no warning about folders that could not be read"),
            OptionSpec("-v", "--verbose", "show timing details and skipped-entry counts"),
            noColorOption,
        ]),
    CommandSpec(
        name: "doctor", usage: "doctor", summary: "Check Full Disk Access for the terminal app", operands: .none,
        options: [
            OptionSpec("--no-open", "only print; do not open System Settings"),
            OptionSpec("--no-color", "plain output"),
        ]),
    CommandSpec(
        name: "list", usage: "list", summary: "List cleanup candidates in the home folder", operands: .none,
        options: [homeOption, jsonOption, timingsOption, noColorOption]),
    CommandSpec(
        name: "clean", usage: "clean <id|rule>...", summary: "Clean candidates (dry run unless --yes)",
        operands: .ruleIDs,
        options: [
            homeOption, OptionSpec("--yes", "clean for real (default: dry run)"), jsonOption, timingsOption,
            noColorOption,
        ]),
    CommandSpec(
        name: "completion", usage: "completion <shell>", summary: "Print a completion script for zsh, bash or fish",
        operands: .shells, options: []),
    CommandSpec(
        name: "help", usage: "help [command]", summary: "Show help for a command", operands: .commands,
        options: []),
]

/// The shells `fil completion` knows.
let completionShells = ["zsh", "bash", "fish"]

/// The "Commands:" lines of the main help, from the table.
func commandListLines() -> String {
    let width = commandTable.map(\.usage.count).max()! + 2
    return commandTable.map { "  " + $0.usage.padding(toLength: width, withPad: " ", startingAt: 0) + $0.summary }
        .joined(separator: "\n")
}

/// The rule ids `clean` accepts, in the order of `Rules.all`.
func ruleIDs() -> [String] { Rules.all.map(\.id) }
