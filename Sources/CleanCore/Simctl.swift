import Foundation

/// An installed simulator runtime as `xcrun simctl runtime list -j` reports it.
public struct SimRuntime: Sendable, Equatable {
    /// The UUID `simctl runtime delete` takes.
    public let identifier: String
    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-0`: what devices refer to.
    public let runtimeIdentifier: String
    public let version: String
    public let build: String
    public let sizeBytes: Int64
    public let path: String

    /// `iOS`, `tvOS`, `watchOS`, `xrOS`: from the runtime identifier.
    public var platform: String {
        let last = runtimeIdentifier.split(separator: ".").last.map(String.init) ?? runtimeIdentifier
        return last.split(separator: "-").first.map(String.init) ?? last
    }

    /// `tvOS 27.0 (24J360)`.
    public var displayName: String {
        "\(platform == "xrOS" ? "visionOS" : platform) \(version) (\(build))"
    }

    /// Stable candidate id suffix: `tvOS-27.0-24J360`.
    public var slug: String { "\(platform)-\(version)-\(build)" }
}

public struct SimulatorReport: Sendable, Equatable {
    /// The `xcrun` that answered; removal commands use it.
    public var xcrun = Simctl.xcrun
    /// Simulators whose runtime is gone (`isAvailable == false`).
    public var unavailableUDIDs: [String] = []
    /// Runtimes no simulator uses.
    public var unusedRuntimes: [SimRuntime] = []
}

enum Simctl {
    static let xcrun = "/usr/bin/xcrun"

    /// `simctl list devices -j`: UDIDs of unavailable devices and every runtime identifier a device uses.
    static func parseDevices(_ json: String) -> (unavailable: [String], usedRuntimes: Set<String>)? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let devices = obj["devices"] as? [String: [[String: Any]]]
        else { return nil }
        var unavailable: [String] = []
        var used: Set<String> = []
        for (runtime, list) in devices {
            if !list.isEmpty { used.insert(runtime) }
            for d in list where (d["isAvailable"] as? Bool) == false {
                if let udid = d["udid"] as? String { unavailable.append(udid) }
            }
        }
        return (unavailable.sorted(), used)
    }

    /// `simctl runtime list -j`: an object keyed by identifier. Runtimes marked not deletable or without a
    /// size are left out.
    static func parseRuntimes(_ json: String) -> [SimRuntime]? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        return obj.compactMap { key, value -> SimRuntime? in
            guard let r = value as? [String: Any], (r["deletable"] as? Bool) != false,
                let rid = r["runtimeIdentifier"] as? String,
                let size = (r["sizeBytes"] as? NSNumber)?.int64Value, size > 0
            else { return nil }
            return SimRuntime(
                identifier: r["identifier"] as? String ?? key, runtimeIdentifier: rid,
                version: r["version"] as? String ?? "?", build: r["build"] as? String ?? "?",
                sizeBytes: size, path: r["path"] as? String ?? "")
        }.sorted {
            $0.runtimeIdentifier == $1.runtimeIdentifier
                ? $0.build < $1.build
                : $0.runtimeIdentifier < $1.runtimeIdentifier
        }
    }

    static func unused(_ runtimes: [SimRuntime], used: Set<String>) -> [SimRuntime] {
        runtimes.filter { !used.contains($0.runtimeIdentifier) }
    }

    /// Both queries run concurrently. A failing runtime query still leaves the unavailable devices.
    static func query(_ env: ToolEnvironment) async -> ToolAnswer<SimulatorReport> {
        guard let xcrun = env.locate("xcrun") else { return ToolAnswer(value: SimulatorReport(), notes: []) }
        let devicesArgv = [xcrun, "simctl", "list", "devices", "-j"]
        let runtimesArgv = [xcrun, "simctl", "runtime", "list", "-j"]
        async let devicesResult = env.runner.run(devicesArgv, timeout: env.timeout)
        async let runtimesResult = env.runner.run(runtimesArgv, timeout: env.timeout)
        let (d, r) = await (devicesResult, runtimesResult)
        var report = SimulatorReport(xcrun: xcrun)
        var notes: [String] = []
        guard case .success(let dj) = d, let devices = parseDevices(dj) else {
            // Without the device list no runtime can be called unused.
            return ToolAnswer(value: report, notes: ["\(env.describe(devicesArgv)): \(env.reason(d))"])
        }
        report.unavailableUDIDs = devices.unavailable
        if case .success(let rj) = r, let runtimes = parseRuntimes(rj) {
            report.unusedRuntimes = unused(runtimes, used: devices.usedRuntimes)
        } else {
            notes.append("\(env.describe(runtimesArgv)): \(env.reason(r))")
        }
        return ToolAnswer(value: report, notes: notes)
    }
}
