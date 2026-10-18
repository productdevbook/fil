import Foundation

/// Fine-grained phase timings for the engine, printed to stderr when `FIL_TIMINGS=1`.
enum Timings {
    static let enabled: Bool = ProcessInfo.processInfo.environment["FIL_TIMINGS"] == "1"

    /// Starts a timer; `lap` prints the time since the previous lap under `scope`.
    struct Lap {
        let scope: String
        var mark = ContinuousClock.now

        init(_ scope: String) { self.scope = scope }

        mutating func lap(_ name: String) {
            guard Timings.enabled else { return }
            let now = ContinuousClock.now
            let (s, atto) = (now - mark).components
            let ms = Double(s) * 1000 + Double(atto) / 1e15
            FileHandle.standardError.write(Data(String(format: "[timing] %@.%@ %.1f ms\n", scope, name, ms).utf8))
            mark = now
        }
    }
}
