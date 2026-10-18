import Darwin
import Foundation

/// A throwaway directory tree under the temporary directory. Never touches the home folder or the real Trash.
public final class Fixture: @unchecked Sendable {
    /// Resolved through symlinks (/var -> /private/var), the way FSEvents reports paths.
    public let root: String

    public init(label: String = "fixture") throws {
        var template = Array((NSTemporaryDirectory() + "fil-test-\(label)-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let made = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard let real = realpath(made, nil) else { throw POSIXError(.ENOENT) }
        defer { free(real) }
        root = String(decoding: UnsafeBufferPointer(start: real, count: strlen(real)).map { UInt8(bitPattern: $0) },
                      as: UTF8.self)
    }

    /// Runs `body` with a fixture and removes it afterwards, also when `body` throws.
    public static func with<T>(_ label: String = "fixture", _ body: (Fixture) throws -> T) throws -> T {
        let f = try Fixture(label: label)
        defer { f.remove() }
        return try body(f)
    }

    public static func withAsync<T>(_ label: String = "fixture", _ body: (Fixture) async throws -> T) async throws -> T {
        let f = try Fixture(label: label)
        defer { f.remove() }
        return try await body(f)
    }

    public func path(_ relative: String) -> String { relative.isEmpty ? root : root + "/" + relative }

    /// A file of `bytes` zero bytes; parent directories are created.
    public func mk(_ relative: String, bytes: Int) throws {
        let url = URL(fileURLWithPath: path(relative))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    public func mkdir(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    public func append(_ relative: String, bytes: Int) throws {
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path(relative)))
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(count: bytes))
    }

    public func remove(_ relative: String) throws { try FileManager.default.removeItem(atPath: path(relative)) }

    public func move(_ from: String, to: String) throws {
        try FileManager.default.moveItem(atPath: path(from), toPath: path(to))
    }

    /// `rename(2)` itself: also for a name that differs only in case, which `FileManager.moveItem` refuses on a
    /// case-insensitive volume.
    public func rename(_ from: String, to: String) throws {
        guard Darwin.rename(path(from), path(to)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    public func link(_ from: String, to: String) throws {
        try mkdir((to as NSString).deletingLastPathComponent)
        guard Darwin.link(path(from), path(to)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    public func symlink(_ target: String, at relative: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path(relative), withDestinationPath: target)
    }

    public func chmod(_ relative: String, _ mode: mode_t) throws {
        guard Darwin.chmod(path(relative), mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    public func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: path(relative)) }

    /// Relative path, size and modification time of everything in the fixture, to prove nothing changed.
    public func listing() -> [String] {
        guard let e = FileManager.default.enumerator(atPath: root) else { return [] }
        return e.compactMap { $0 as? String }.sorted().map { rel in
            let a = (try? FileManager.default.attributesOfItem(atPath: path(rel))) ?? [:]
            return "\(rel) \(a[.size] ?? 0) \(a[.modificationDate] ?? "")"
        }
    }

    /// Makes everything readable again (tests that chmod 000) and deletes the tree.
    public func remove() {
        _ = Process.run("/bin/chmod", ["-R", "u+rwx", root])
        try? FileManager.default.removeItem(atPath: root)
    }

    /// `du -skx` x 1024: the reference for on-disk sizes. Directories that cannot be read still print a total.
    public func duBytes(_ relative: String = "") -> Int64 {
        let out = Process.output("/usr/bin/du", ["-skx", path(relative)])
        guard let first = out.split(whereSeparator: { $0 == " " || $0 == "\t" }).first, let kb = Int64(first) else { return -1 }
        return kb * 1024
    }
}

extension Process {
    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func output(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
