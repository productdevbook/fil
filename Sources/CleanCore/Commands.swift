import Foundation
import Subprocess
import System

enum Commands {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Runs `argv` (argv[0] is an absolute path) without a shell and returns its standard output.
    static func output(_ argv: [String]) async throws -> String {
        let r = try await run(.path(FilePath(argv[0])), arguments: Arguments(Array(argv.dropFirst())),
                              output: .string(limit: 16 << 20), error: .string(limit: 1 << 20))
        guard r.terminationStatus.isSuccess else {
            let err = r.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(description: "\((argv[0] as NSString).lastPathComponent) failed: \(r.terminationStatus) \(err)")
        }
        return r.standardOutput
    }
}
