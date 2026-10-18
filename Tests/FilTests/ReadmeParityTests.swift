import Foundation
import Testing

/// The README must mention every command and option that `fil --help` and `fil <command> --help` show
/// (chapter 05 §10), and its exit status section must list every code the main help lists.
@Suite struct ReadmeParityTests {
    let cli = ErrorHandlingTests()

    static let readme: String = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return (try? String(contentsOf: url.appendingPathComponent("README.md"), encoding: .utf8)) ?? ""
    }()

    /// Every `--long` option and every `-x` short option written in a help text.
    static func options(in help: String) -> Set<String> {
        var found = Set<String>()
        for line in help.split(separator: "\n") {
            for word in line.split(whereSeparator: { " ,[]()".contains($0) }) {
                guard word.hasPrefix("-"), word.count >= 2 else { continue }
                let w = word.trimmingCharacters(in: CharacterSet(charactersIn: ".;:"))
                if w.hasPrefix("--"), w.count > 2, w.dropFirst(2).allSatisfy({ $0.isLetter || $0 == "-" }) {
                    found.insert(w)
                } else if w.count == 2, w.last?.isLetter == true {
                    found.insert(w)
                }
            }
        }
        return found
    }

    @Test func readmeIsFound() {
        #expect(Self.readme.contains("## Usage"), "README.md not found next to Tests/")
    }

    @Test func everyOptionInHelpIsInReadme() throws {
        let snap = try ErrorHandlingTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: snap) }
        for command in ["scan", "doctor", "list", "clean"] {
            let help = try cli.run([command, "--help"], snapshotDir: snap)
            #expect(help.status == 0)
            let found = Self.options(in: help.stdout)
            #expect(found.contains("--no-color"), "no options parsed from 'fil \(command) --help'")
            for option in found.sorted() {
                #expect(Self.readme.contains("`\(option)"), "README.md lacks \(option) of 'fil \(command)'")
            }
        }
        let main = try cli.run(["--help"], snapshotDir: snap)
        for option in Self.options(in: main.stdout).sorted() {
            #expect(Self.readme.contains(option), "README.md lacks \(option) of 'fil --help'")
        }
    }

    @Test func everyCommandAndExitCodeIsInReadme() throws {
        let snap = try ErrorHandlingTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: snap) }
        let main = try cli.run(["--help"], snapshotDir: snap)
        for command in ["scan", "doctor", "list", "clean", "help"] {
            #expect(Self.readme.contains("fil \(command)"), "README.md never shows 'fil \(command)'")
        }
        #expect(Self.readme.contains("### Exit status"))
        for line in main.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if let code = parts.first, code.count == 1, code.first?.isNumber == true, parts.count == 2 {
                #expect(Self.readme.contains("| \(code) |"), "README.md exit status lacks code \(code)")
            }
        }
    }
}
