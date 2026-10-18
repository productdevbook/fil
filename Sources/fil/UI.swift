import CleanCore
import Darwin
import Foundation
import ScanCore
import Synchronization

/// Terminal styling and layout helpers. Colour is on only for a TTY without NO_COLOR and without --no-color.
enum UI {
    nonisolated(unsafe) static var color = false

    static func setup(noColor: Bool) {
        let env = ProcessInfo.processInfo.environment
        color = !noColor && isatty(1) != 0 && (env["NO_COLOR"] ?? "").isEmpty && env["TERM"] != "dumb"
    }

    static func paint(_ s: String, _ code: String) -> String { color ? "\u{1b}[\(code)m\(s)\u{1b}[0m" : s }
    static func bold(_ s: String) -> String { paint(s, "1") }
    static func dim(_ s: String) -> String { paint(s, "2") }
    static func green(_ s: String) -> String { paint(s, "32") }
    static func yellow(_ s: String) -> String { paint(s, "33") }
    static func red(_ s: String) -> String { paint(s, "31") }

    /// Colour by share of the total: >= 20% red, >= 5% yellow, else plain.
    static func share(_ s: String, _ fraction: Double) -> String {
        fraction >= 0.20 ? red(s) : fraction >= 0.05 ? yellow(s) : s
    }

    static var width: Int {
        var w = winsize()
        if ioctl(1, TIOCGWINSZ, &w) == 0, w.ws_col > 0 { return Int(w.ws_col) }
        return 80
    }

    static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
    static func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }

    /// Shortens `s` to `n` characters with "…" in the middle.
    static func truncate(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s }
        guard n > 1 else { return String(s.prefix(max(n, 0))) }
        let keep = n - 1
        let head = (keep + 1) / 2, tail = keep / 2
        return String(s.prefix(head)) + "…" + String(s.suffix(tail))
    }

    static func safety(_ s: Safety) -> String {
        let label = pad(s.rawValue, 7)
        switch s {
        case .safe: return green(label)
        case .review: return yellow(label)
        case .careful: return red(label)
        }
    }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~/" + path.dropFirst(home.count + 1) : path
    }

    /// Proportional bar of `width` cells using block eighths.
    static func bar(_ fraction: Double, width: Int = 20) -> String {
        let eighths = Int((min(max(fraction, 0), 1) * Double(width * 8)).rounded())
        let full = eighths / 8, rem = eighths % 8
        var s = String(repeating: "█", count: full)
        if rem > 0, full < width { s += String(["▏", "▎", "▍", "▌", "▋", "▊", "▉"][rem - 1]) }
        return s + String(repeating: " ", count: max(0, width - s.count))
    }
}

/// Decimal units like Finder, independent of the user's locale: "105.3 GB".
func human(_ bytes: Int64) -> String {
    if bytes < 1000 { return "\(bytes) B" }
    var v = Double(bytes) / 1000
    for unit in ["KB", "MB", "GB", "TB"] {
        if v < 999.95 || unit == "TB" { return String(format: "%.1f %@", locale: nil, v, unit) }
        v /= 1000
    }
    return "\(bytes) B"
}

func ms(_ d: Duration) -> String {
    let (s, atto) = d.components
    return String(format: "%.0f ms", locale: nil, Double(s) * 1000 + Double(atto) / 1e15)
}

/// "850 ms", "1.4 s", "2m 05s".
func humanDuration(_ d: Duration) -> String {
    let (s, atto) = d.components
    let secs = Double(s) + Double(atto) / 1e18
    if secs < 1 { return String(format: "%.0f ms", locale: nil, secs * 1000) }
    if secs < 60 { return String(format: "%.1f s", locale: nil, secs) }
    return String(format: "%dm %02ds", locale: nil, Int(secs) / 60, Int(secs) % 60)
}

/// 12345 -> "12,345" (fixed, locale independent).
func count(_ n: Int64) -> String {
    let digits = Array(String(n))
    var out = ""
    for (i, ch) in digits.enumerated() {
        if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
        out.append(ch)
    }
    return out
}

/// One redrawn status line on stderr (TTY only), refreshed ~10x/s by its own thread.
/// It only reads the scanner's relaxed atomic counters; nothing is added to the scan's hot path.
final class Progress: @unchecked Sendable {
    private let progress: ScanProgress
    private let label: String
    private let stop = Atomic<Bool>(false)
    private let done = DispatchSemaphore(value: 0)
    private let enabled: Bool
    private var started = false

    init(label: String, progress: ScanProgress) {
        self.label = label
        self.progress = progress
        enabled = isatty(2) != 0 && (ProcessInfo.processInfo.environment["TERM"] ?? "") != "dumb"
    }

    func start() {
        guard enabled, !started else { return }
        started = true
        let t = Thread { [self] in
            let frames = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
            let begin = ContinuousClock.now
            var i = 0
            while !stop.load(ordering: .relaxed) {
                let dirs = progress.dirs.load(ordering: .relaxed)
                let files = progress.files.load(ordering: .relaxed)
                let bytes = progress.bytes.load(ordering: .relaxed)
                var line = "\(UI.paint(String(frames[i % frames.count]), "36")) \(label)"
                if dirs > 0 {
                    line += UI.dim("  \(count(dirs)) folders · \(count(files)) files · \(human(bytes))")
                }
                line += UI.dim("  \(humanDuration(ContinuousClock.now - begin))")
                FileHandle.standardError.write(Data(("\r\u{1b}[K" + line).utf8))
                i += 1
                Thread.sleep(forTimeInterval: 0.1)
            }
            FileHandle.standardError.write(Data("\r\u{1b}[K".utf8))
            done.signal()
        }
        t.start()
    }

    /// Clears the line; a no-op when the spinner never started (also safe to call twice).
    func finish() {
        guard enabled, started else { return }
        started = false
        stop.store(true, ordering: .relaxed)
        done.wait()
    }
}
