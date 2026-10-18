import Foundation

/// A small APFS disk image made from a folder and attached with `hdiutil` at a chosen mount point: a second volume
/// inside a fixture. `detach` is safe to call more than once; call it in a `defer` so no image stays mounted.
public final class DiskImage: @unchecked Sendable {
    private static let hdiutil = "/usr/bin/hdiutil"
    public let path: String
    public private(set) var mountPoint: String?

    /// False where `hdiutil` does not exist; tests that need an image are skipped there.
    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: hdiutil) }

    /// Creates the image at `path` with the contents of `sourceFolder`; nil when `hdiutil create` fails.
    public init?(from sourceFolder: String, at path: String, volumeName: String = "FilTest") {
        self.path = path
        let status = Process.run(
            Self.hdiutil,
            [
                "create", "-quiet", "-ov", "-fs", "APFS", "-format", "UDRW",
                "-volname", volumeName, "-srcfolder", sourceFolder, path,
            ])
        guard status == 0 else { return nil }
    }

    /// An empty image of `megabytes` with file system `fs` (an `hdiutil create -fs` name such as "MS-DOS"), without a
    /// partition map so that its file system starts at byte 0. Nil when `hdiutil create` fails.
    public init?(emptyMegabytes megabytes: Int, fs: String, at path: String, volumeName: String = "FILTEST") {
        self.path = path
        let status = Process.run(
            Self.hdiutil,
            [
                "create", "-quiet", "-ov", "-size", "\(megabytes)m", "-fs", fs,
                "-layout", "NONE", "-volname", volumeName, path,
            ])
        guard status == 0 else { return nil }
    }

    /// Mounts the image on the existing directory `mountPoint` (not shown in the Finder). False when it fails.
    public func attach(at mountPoint: String) -> Bool {
        let status = Process.run(
            Self.hdiutil,
            [
                "attach", "-quiet", "-nobrowse", "-noautoopen", "-noverify",
                "-mountpoint", mountPoint, path,
            ])
        guard status == 0 else { return false }
        self.mountPoint = mountPoint
        return true
    }

    /// Unmounts the image if it is mounted; forced when a plain detach fails.
    public func detach() {
        guard let mountPoint else { return }
        if Process.run(Self.hdiutil, ["detach", "-quiet", mountPoint]) != 0 {
            Process.run(Self.hdiutil, ["detach", "-quiet", "-force", mountPoint])
        }
        self.mountPoint = nil
    }

    deinit { detach() }
}
