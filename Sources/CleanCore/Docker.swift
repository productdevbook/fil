import AppKit
import Foundation

/// What Docker could give back without touching volumes or containers.
public struct DockerReport: Sendable, Equatable {
    /// Absolute path of the `docker` binary the removal commands use.
    public var docker: String
    /// What `docker builder prune -f` frees (see `DockerQuery.parseVerboseDF`).
    public var buildCacheBytes: Int64
    /// What `docker image prune -f` frees: unique sizes of dangling images no container uses.
    public var danglingImageBytes: Int64
}

enum DockerQuery {
    /// Engine apps whose socket may start the VM when something connects to it.
    static let engineApps: [(bundleId: String, path: String)] = [
        ("dev.kdrag0n.MacVirt", "/Applications/OrbStack.app"),
        ("com.docker.docker", "/Applications/Docker.app"),
        ("io.rancherdesktop.app", "/Applications/Rancher Desktop.app"),
    ]

    /// True when a known engine app is installed and none of the installed ones is running.
    static func engineAppStopped() -> Bool {
        let installed = engineApps.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !installed.isEmpty else { return false }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return !installed.contains { running.contains($0.bundleId) }
    }

    /// Docker's human-readable sizes (`10.1GB`, `1.396GB (100%)`, `0B`, `512kB`, `1.5GiB`) to bytes.
    static func parseSize(_ text: String) -> Int64? {
        let s = text.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard let split = s.firstIndex(where: { !($0.isNumber || $0 == ".") }),
              let number = Double(s[..<split]) else { return nil }
        let unit = s[split...].trimmingCharacters(in: .whitespaces).lowercased()
        let factors: [String: Double] = [
            "b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12, "pb": 1e15,
            "kib": 1024, "mib": 1_048_576, "gib": 1_073_741_824, "tib": 1_099_511_627_776,
        ]
        guard let f = factors[unit] else { return nil }
        return Int64((number * f).rounded())
    }

    /// A JSON field Docker prints as a string ("false", "0") or, in other versions, as a bool or number.
    private static func flag(_ v: Any?) -> Bool? {
        switch v {
        case let b as Bool: b
        case let s as String: s == "true" ? true : s == "false" ? false : nil
        default: nil
        }
    }

    private static func count(_ v: Any?) -> Int? {
        switch v {
        case let n as NSNumber: n.intValue
        case let s as String: Int(s)
        default: nil
        }
    }

    /// `docker system df -v --format json` (one object with `Images`, `BuildCache`, ...): what the two prune
    /// commands would free. Nil when the output is not that object.
    ///
    /// - Build cache: records `docker builder prune -f` removes: not in use, not shared with an image, and not
    ///   of the `internal` or `frontend` types (those need `--all`). Shared records free nothing.
    /// - Dangling images: `<none>:<none>` images no container uses (`docker image prune -f` keeps those), counted
    ///   by `UniqueSize` (layers shared with other images stay on disk). Unknown counts or sizes count as 0.
    static func parseVerboseDF(_ text: String) -> (buildCache: Int64, danglingImages: Int64)? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              obj["Images"] != nil || obj["BuildCache"] != nil else { return nil }
        var cache: Int64 = 0
        for r in obj["BuildCache"] as? [[String: Any]] ?? [] {
            guard flag(r["InUse"]) == false, flag(r["Shared"]) == false,
                  let type = r["CacheType"] as? String, type != "internal", type != "frontend",
                  let size = (r["Size"] as? String).flatMap(parseSize) else { continue }
            cache += size
        }
        var dangling: Int64 = 0
        for i in obj["Images"] as? [[String: Any]] ?? [] {
            guard i["Repository"] as? String == "<none>", i["Tag"] as? String == "<none>",
                  count(i["Containers"]) == 0,
                  let size = (i["UniqueSize"] as? String).flatMap(parseSize) else { continue }
            dangling += size
        }
        return (cache, dangling)
    }

    /// Nil value: Docker is missing, its engine is not running, or it did not answer.
    static func query(_ env: ToolEnvironment) async -> ToolAnswer<DockerReport?> {
        guard let docker = env.locate("docker"), !env.dockerMayAutostart() else {
            return ToolAnswer(value: nil, notes: [])
        }
        let argv = [docker, "system", "df", "-v", "--format", "json"]
        let r = await env.runner.run(argv, timeout: env.timeout)
        switch r {
        case .failed:
            return ToolAnswer(value: nil, notes: [])    // daemon not running: not an error
        case .timedOut:
            return ToolAnswer(value: nil, notes: ["\(env.describe(argv)): \(env.reason(r))"])
        case .success(let text):
            guard let sizes = parseVerboseDF(text) else {
                return ToolAnswer(value: nil, notes: ["\(env.describe(argv)): unexpected output"])
            }
            return ToolAnswer(value: DockerReport(docker: docker, buildCacheBytes: sizes.buildCache,
                                                  danglingImageBytes: sizes.danglingImages), notes: [])
        }
    }
}
