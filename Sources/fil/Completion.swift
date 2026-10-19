import Foundation

// fil completion <zsh|bash|fish>
// The scripts are generated from `commandTable` and the rule ids, so they cannot drift from the parser's options
// (chapter 05 §8). `-h` and `--help` are accepted by every command and added here.

func runCompletion(_ arguments: [String]) -> Never {
    var args = CommandLineWords(arguments)
    var shell: String?
    while let word = args.next() {
        switch word {
        case .option(let o): unknownOption(o, "completion")
        case .operand(let a):
            if shell != nil { usageError("unexpected argument '\(a)' for 'fil completion'") }
            shell = a
        }
    }
    guard let shell, let script = completionScript(shell: shell) else {
        usageError("completion needs one of: \(completionShells.joined(separator: ", "))")
    }
    print(script, terminator: "")
    exit(0)
}

/// The script for `shell`, or nil for a shell that is not listed in `completionShells`.
func completionScript(shell: String, commands: [CommandSpec] = commandTable, rules: [String] = ruleIDs()) -> String? {
    switch shell {
    case "zsh": return zshScript(commands, rules)
    case "bash": return bashScript(commands, rules)
    case "fish": return fishScript(commands, rules)
    default: return nil
    }
}

private let helpOption = OptionSpec("-h", "--help", "show help")
private let versionOption = OptionSpec("-V", "--version", "print the version")

/// `'text'` for a POSIX-style shell (zsh, bash).
private func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// MARK: zsh

private func zshScript(_ commands: [CommandSpec], _ rules: [String]) -> String {
    /// Brackets and colons would end the description early in an `_arguments` spec.
    func text(_ s: String) -> String {
        s.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }

    func spec(_ o: OptionSpec) -> String {
        let names = o.names.joined(separator: ",")
        let head = o.names.count > 1 ? shQuote("(" + o.names.joined(separator: " ") + ")") + "{\(names)}" : ""
        let description = "[\(text(o.summary))]"
        var tail = description
        switch o.value {
        case .number(let n)?: tail += ":\(n): "
        case .directory(let d)?: tail += ":\(d):_files -/"
        case nil: break
        }
        if o.names.count > 1 { return head + shQuote(tail) }
        return shQuote(o.names[0] + tail)
    }

    func operand(_ c: CommandSpec) -> String? {
        switch c.operands {
        case .none: return nil
        case .directory: return shQuote("1:DIR:_files -/")
        case .ruleIDs: return shQuote("*:rule id:(\(rules.joined(separator: " ")))")
        case .shells: return shQuote("1:shell:(\(completionShells.joined(separator: " ")))")
        case .commands: return shQuote("1:command:(\(commands.map(\.name).joined(separator: " ")))")
        }
    }

    var out = ["#compdef fil", "", "_fil() {"]
    out += [
        "  local curcontext=\"$curcontext\" state line ret=1",
        "  typeset -A opt_args",
        "  local -a commands",
        "  commands=(",
    ]
    for c in commands {
        out.append("    " + shQuote(c.name.replacingOccurrences(of: ":", with: "\\:") + ":" + c.summary))
    }
    out += [
        "  )",
        "  _arguments -C \\",
        "    \(spec(helpOption)) \\",
        "    \(spec(versionOption)) \\",
        "    '1: :->command' \\",
        "    '*:: :->args' && ret=0",
        "  case $state in",
        "    command)",
        "      _describe -t commands 'fil command' commands && ret=0",
        "      ;;",
        "    args)",
        "      case $line[1] in",
    ]
    for c in commands {
        let parts = ([helpOption] + c.options).map(spec) + [operand(c)].compactMap { $0 }
        out.append("        \(c.name))")
        out.append("          _arguments -s \\")
        out.append(parts.map { "            \($0)" }.joined(separator: " \\\n") + " && ret=0")
        out.append("          ;;")
    }
    out += [
        "      esac",
        "      ;;",
        "  esac",
        "  return ret",
        "}",
        "",
        "if [ \"$funcstack[1]\" = \"_fil\" ]; then",
        "  _fil \"$@\"",
        "else",
        "  compdef _fil fil",
        "fi",
    ]
    return out.joined(separator: "\n") + "\n"
}

// MARK: bash

private func bashScript(_ commands: [CommandSpec], _ rules: [String]) -> String {
    func words(_ o: OptionSpec) -> [String] { o.names }
    let top = commands.map(\.name) + helpOption.names + versionOption.names

    var out = [
        "# bash completion for fil",
        "",
        "_fil_dirs() {",
        "  local IFS=$'\\n'",
        "  COMPREPLY=($(compgen -d -- \"$1\"))",
        "  compopt -o filenames 2>/dev/null",
        "}",
        "",
        "_fil() {",
        "  local cur prev cmd",
        "  COMPREPLY=()",
        "  cur=\"${COMP_WORDS[COMP_CWORD]}\"",
        "  prev=\"${COMP_WORDS[COMP_CWORD-1]}\"",
        "  if [[ $COMP_CWORD -eq 1 ]]; then",
        "    COMPREPLY=($(compgen -W \(shQuote(top.joined(separator: " "))) -- \"$cur\"))",
        "    return 0",
        "  fi",
        "  cmd=\"${COMP_WORDS[1]}\"",
        "  case \"$cmd\" in",
    ]
    for c in commands {
        let optionWords = ([helpOption] + c.options).flatMap(words).joined(separator: " ")
        out.append("    \(c.name))")
        let valued = c.options.filter { $0.value != nil }
        if !valued.isEmpty {
            out.append("      case \"$prev\" in")
            for o in valued {
                let pattern = o.names.joined(separator: "|")
                if case .directory? = o.value {
                    out.append("        \(pattern)) _fil_dirs \"$cur\"; return 0 ;;")
                } else {
                    out.append("        \(pattern)) return 0 ;;")
                }
            }
            out.append("      esac")
        }
        out.append("      if [[ \"$cur\" == -* ]]; then")
        out.append("        COMPREPLY=($(compgen -W \(shQuote(optionWords)) -- \"$cur\"))")
        switch c.operands {
        case .none:
            break
        case .directory:
            out.append("      else")
            out.append("        _fil_dirs \"$cur\"")
        case .ruleIDs:
            out.append("      else")
            out.append("        COMPREPLY=($(compgen -W \(shQuote(rules.joined(separator: " "))) -- \"$cur\"))")
        case .shells:
            out.append("      elif [[ $COMP_CWORD -eq 2 ]]; then")
            out.append(
                "        COMPREPLY=($(compgen -W \(shQuote(completionShells.joined(separator: " "))) -- \"$cur\"))")
        case .commands:
            out.append("      elif [[ $COMP_CWORD -eq 2 ]]; then")
            out.append(
                "        COMPREPLY=($(compgen -W \(shQuote(commands.map(\.name).joined(separator: " "))) -- \"$cur\"))")
        }
        out.append("      fi")
        out.append("      ;;")
    }
    out += ["  esac", "  return 0", "}", "", "complete -F _fil fil"]
    return out.joined(separator: "\n") + "\n"
}

// MARK: fish

private func fishScript(_ commands: [CommandSpec], _ rules: [String]) -> String {
    func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// `-s h -l help` for the names of an option.
    func flags(_ o: OptionSpec) -> String {
        o.names.map { $0.hasPrefix("--") ? "-l \($0.dropFirst(2))" : "-s \($0.dropFirst(1))" }.joined(separator: " ")
    }

    func line(_ condition: String, _ rest: String) -> String { "complete -c fil -n \(condition) \(rest)" }

    var out = [
        "# fish completion for fil",
        "",
        "function __fil_no_command",
        "    test (count (commandline -opc)) -eq 1",
        "end",
        "",
        "function __fil_command",
        "    set -l words (commandline -opc)",
        "    test (count $words) -ge 2; and test \"$words[2]\" = \"$argv[1]\"",
        "end",
        "",
        "complete -c fil -f",
    ]
    for c in commands {
        out.append(line("__fil_no_command", "-a \(c.name) -d \(q(c.summary))"))
    }
    for o in [helpOption, versionOption] {
        out.append(line("__fil_no_command", "\(flags(o)) -d \(q(o.summary))"))
    }
    for c in commands {
        let condition = q("__fil_command \(c.name)")
        for o in [helpOption] + c.options {
            var rest = flags(o)
            switch o.value {
            case .number?: rest += " -x"
            case .directory?: rest += " -r -a '(__fish_complete_directories)'"
            case nil: break
            }
            out.append(line(condition, "\(rest) -d \(q(o.summary))"))
        }
        switch c.operands {
        case .none: break
        case .directory: out.append(line(condition, "-a '(__fish_complete_directories)'"))
        case .ruleIDs: out.append(line(condition, "-a \(q(rules.joined(separator: " ")))"))
        case .shells: out.append(line(condition, "-a \(q(completionShells.joined(separator: " ")))"))
        case .commands: out.append(line(condition, "-a \(q(commands.map(\.name).joined(separator: " ")))"))
        }
    }
    return out.joined(separator: "\n") + "\n"
}
