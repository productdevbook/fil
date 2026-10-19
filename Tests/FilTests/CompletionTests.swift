import CleanCore
import Foundation
import Testing

@testable import fil

/// The completion scripts and `man/fil.1` must cover every command and option that the help texts show
/// (chapter 05 §8). The help texts are read from the built binary, independently of `commandTable`.
@Suite struct CompletionTests {
    let cli = ErrorHandlingTests()

    static let manPage: String = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return (try? String(contentsOf: url.appendingPathComponent("man/fil.1"), encoding: .utf8)) ?? ""
    }()

    /// `word` appears as a whole word: not part of a longer option or identifier.
    static func mentions(_ text: String, _ word: String) -> Bool {
        let pattern = "(?<![A-Za-z0-9_-])" + NSRegularExpression.escapedPattern(for: word) + "(?![A-Za-z0-9_-])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// The first word of each line under "Commands:" in the main help.
    static func commands(inMainHelp help: String) -> [String] {
        var found: [String] = []
        var inList = false
        for line in help.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "Commands:" { inList = true; continue }
            if line.isEmpty { inList = false }
            if inList, let first = line.split(separator: " ").first { found.append(String(first)) }
        }
        return found
    }

    /// What `fil --help` and each `fil <command> --help` show: commands, options per command, exit codes.
    struct HelpFacts {
        var commands: [String] = []
        var options: [String: Set<String>] = [:]
        var mainOptions: Set<String> = []
        var exitCodes: [String] = []
    }

    func helpFacts() throws -> HelpFacts {
        let snap = try ErrorHandlingTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: snap) }
        var facts = HelpFacts()
        let main = try cli.run(["--help"], snapshotDir: snap).stdout
        facts.commands = Self.commands(inMainHelp: main)
        facts.mainOptions = ReadmeParityTests.options(in: main)
        for line in main.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if let code = parts.first, code.count == 1, code.first?.isNumber == true, parts.count == 2 {
                facts.exitCodes.append(String(code))
            }
        }
        for command in facts.commands where command != "help" {
            let help = try cli.run([command, "--help"], snapshotDir: snap)
            facts.options[command] = ReadmeParityTests.options(in: help.stdout)
        }
        return facts
    }

    /// Everything the help texts show that `text` never mentions.
    func missing(in text: String, _ facts: HelpFacts, fish: Bool = false) -> [String] {
        // fish writes `--home` as `-l home` and `-j` as `-s j`.
        func spelled(_ o: String) -> String {
            !fish ? o : (o.hasPrefix("--") ? "-l \(o.dropFirst(2))" : "-s \(o.dropFirst())")
        }
        var gone: [String] = []
        for c in facts.commands where !Self.mentions(text, c) { gone.append("command \(c)") }
        for (command, options) in facts.options {
            for o in options where !Self.mentions(text, spelled(o)) { gone.append("option \(o) of \(command)") }
        }
        for o in facts.mainOptions where !Self.mentions(text, spelled(o)) { gone.append("option \(o)") }
        for id in Rules.all.map(\.id) where !Self.mentions(text, id) { gone.append("rule \(id)") }
        for shell in ["zsh", "bash", "fish"] where !Self.mentions(text, shell) { gone.append("shell \(shell)") }
        return gone
    }

    @Test func helpFactsAreParsed() throws {
        let facts = try helpFacts()
        #expect(facts.commands == ["scan", "doctor", "list", "clean", "completion", "help"])
        #expect(facts.options["scan"]?.contains("--tolerant-hardlinks") == true)
        #expect(facts.options["clean"]?.contains("--yes") == true)
        #expect(facts.exitCodes == ["0", "1", "2", "3"])
    }

    @Test func tableMatchesTheHelpTexts() throws {
        let facts = try helpFacts()
        #expect(facts.commands == commandTable.map(\.name))
        for spec in commandTable where spec.name != "help" {
            let tabled = Set(spec.options.flatMap(\.names))
            #expect(tabled == facts.options[spec.name], "options of 'fil \(spec.name)': table and --help differ")
        }
    }

    @Test(arguments: ["zsh", "bash", "fish"])
    func scriptCoversEveryCommandOptionAndRule(shell: String) throws {
        let snap = try ErrorHandlingTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: snap) }
        let r = try cli.run(["completion", shell], snapshotDir: snap)
        #expect(r.status == 0)
        #expect(r.stderr.isEmpty)
        #expect(r.stdout == completionScript(shell: shell))
        let gone = missing(in: r.stdout, try helpFacts(), fish: shell == "fish")
        #expect(gone.isEmpty, "\(gone)")
    }

    @Test func aScriptWithAMissingOptionIsReported() throws {
        let facts = try helpFacts()
        let script = try #require(completionScript(shell: "bash"))
        #expect(missing(in: script, facts).isEmpty)
        let cut = script.replacingOccurrences(of: "--tolerant-hardlinks", with: "")
        #expect(missing(in: cut, facts) == ["option --tolerant-hardlinks of scan"])
        let noCommand = script.replacingOccurrences(of: "doctor", with: "")
        #expect(missing(in: noCommand, facts).contains("command doctor"))
    }

    @Test func manPageCoversEveryCommandOptionAndExitStatus() throws {
        let facts = try helpFacts()
        let man = Self.manPage
        #expect(man.contains(".Sh EXIT STATUS"), "man/fil.1 not found next to Tests/")
        for c in facts.commands {
            #expect(man.contains("Cm \(c)"), "man page lacks command \(c)")
        }
        let allOptions = facts.options.values.reduce(facts.mainOptions) { $0.union($1) }
        for o in allOptions.sorted() {
            // mdoc writes -x as `Fl x` and --long as `Fl -long`.
            #expect(Self.mentions(man, "Fl \(o.dropFirst())"), "man page lacks \(o)")
        }
        for code in facts.exitCodes { #expect(man.contains(".It Li \(code)\n"), "man page lacks exit status \(code)") }
        for name in ["NO_COLOR", "TERM", "FIL_SNAPSHOT_DIR"] { #expect(man.contains("Ev \(name)")) }
    }

    @Test func manPageLintsClean() throws {
        guard let mandoc = Self.tool("mandoc") else { return }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let r = try Self.run(mandoc, ["-T", "lint", url.appendingPathComponent("man/fil.1").path])
        // An out-of-date whatis database on the machine is not a fault of the page.
        let problems = (r.stdout + r.stderr).split(separator: "\n").filter { !$0.contains("mandoc.db") }
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test func completionNeedsOneKnownShell() throws {
        let snap = try ErrorHandlingTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: snap) }
        for args in [["completion"], ["completion", "tcsh"], ["completion", "zsh", "bash"], ["completion", "--zsh"]] {
            let r = try cli.run(args, snapshotDir: snap)
            #expect(r.status == 2, "\(args)")
            #expect(r.stdout.isEmpty)
        }
        let none = try cli.run(["completion"], snapshotDir: snap)
        #expect(none.stderr.hasPrefix("fil: completion needs one of: zsh, bash, fish\n"))
        let help = try cli.run(["help", "completion"], snapshotDir: snap)
        #expect(help.status == 0 && help.stdout.hasPrefix("Usage: fil completion"))
    }

    // MARK: shells

    /// Whether `name` is an executable in a standard place or on PATH.
    static func tool(_ name: String) -> String? {
        let path =
            (ProcessInfo.processInfo.environment["PATH"] ?? "") + ":/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin"
        return path.split(separator: ":").map { "\($0)/\(name)" }.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    static func run(_ tool: String, _ args: [String], cwd: String? = nil) throws -> ErrorHandlingTests.Run {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return .init(
            status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self),
            stderr: String(decoding: e, as: UTF8.self))
    }

    /// Writes the script for `shell` to a fresh directory and returns it and the script's path.
    func writeScript(_ shell: String, name: String) throws -> (dir: String, script: String) {
        let dir = try ErrorHandlingTests.tempDir()
        let script = dir + "/" + name
        try (completionScript(shell: shell) ?? "").write(toFile: script, atomically: true, encoding: .utf8)
        return (dir, script)
    }

    @Test func scriptsHaveValidSyntax() throws {
        for (shell, tool, flags) in [
            ("zsh", "zsh", ["-n"]), ("bash", "bash", ["-n"]), ("fish", "fish", ["--no-execute"]),
        ] {
            guard let exe = Self.tool(tool) else { continue }  // fish is optional
            let (dir, script) = try writeScript(shell, name: "script")
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let r = try Self.run(exe, flags + [script])
            #expect(r.status == 0, "\(tool) \(flags): \(r.stderr)")
        }
    }

    @Test func bashCompletesCommandsOptionsDirectoriesAndRules() throws {
        guard let bash = Self.tool("bash") else { return }
        let (dir, script) = try writeScript("bash", name: "fil.bash")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/subdir", withIntermediateDirectories: false)
        func complete(_ words: [String]) throws -> [String] {
            let quoted = words.map { "'\($0)'" }.joined(separator: " ")
            let program = """
                source '\(script)'
                COMP_WORDS=(\(quoted)); COMP_CWORD=\(words.count - 1); _fil
                printf '%s\\n' "${COMPREPLY[@]}"
                """
            let r = try Self.run(bash, ["-c", program], cwd: dir)
            #expect(r.status == 0, "\(words): \(r.stderr)")
            return r.stdout.split(separator: "\n").map(String.init)
        }
        #expect(try complete(["fil", "sc"]) == ["scan"])
        #expect(try complete(["fil", "comp"]) == ["completion"])
        #expect(try complete(["fil", "scan", "--to"]) == ["--top", "--tolerant-hardlinks"])
        #expect(try complete(["fil", "scan", "--top", ""]).isEmpty)
        #expect(try complete(["fil", "scan", "sub"]) == ["subdir"])
        #expect(try complete(["fil", "list", "--home", "sub"]) == ["subdir"])
        #expect(try complete(["fil", "completion", ""]) == ["zsh", "bash", "fish"])
        #expect(try complete(["fil", "help", "cl"]) == ["clean"])
        #expect(try complete(["fil", "clean", "xcode-d"]) == ["xcode-derived", "xcode-device-support"])
        #expect(try complete(["fil", "clean", "--y"]) == ["--yes"])
        let reg = try Self.run(bash, ["-c", "source '\(script)'; complete -p fil"])
        #expect(reg.stdout.contains("-F _fil fil"))
    }

    @Test func zshRegistersTheCompletion() throws {
        guard let zsh = Self.tool("zsh") else { return }
        let (dir, script) = try writeScript("zsh", name: "_fil")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Found through fpath, as an installed `_fil` file.
        let viaFpath = try Self.run(
            zsh,
            [
                "-f", "-c",
                "fpath=('\(dir)' $fpath); autoload -Uz compinit; compinit -u -d '\(dir)/dump1'; print -r -- $_comps[fil]",
            ])
        #expect(viaFpath.stdout == "_fil\n", "\(viaFpath.stderr)")
        // Sourced, as `source <(fil completion zsh)`.
        let sourced = try Self.run(
            zsh,
            [
                "-f", "-c",
                "autoload -Uz compinit; compinit -u -d '\(dir)/dump2'; source '\(script)'; print -r -- $_comps[fil]",
            ])
        #expect(sourced.stdout == "_fil\n", "\(sourced.stderr)")
    }
}
