import Foundation
import Testing
@testable import fil

@Suite struct PermissionsTests {
    let home = "/Users/me"

    @Test func classifiesPrivacyProtectedFolders() {
        for p in ["/Users/me/Library/Mail", "/Users/me/Pictures/Photos Library.photoslibrary", "/Users/me/Desktop",
                  "/private/var/db/foo", "/Library/Application Support/com.apple.TCC"] {
            #expect(Permissions.classify(p, ownerUID: 0, home: home, myUID: 501) == .privacyProtected, "\(p)")
        }
    }

    @Test func classifiesPosixFolders() {
        #expect(Permissions.classify("/Users/other", ownerUID: 502, home: home, myUID: 501) == .otherUser)
        #expect(Permissions.classify("/private/var/root", ownerUID: 0, home: home, myUID: 501) == .otherUser)
        #expect(Permissions.classify("/Users/me/locked", ownerUID: 501, home: home, myUID: 501) == .noPermission)
        #expect(Permissions.classify("/Users/me/LibraryX", ownerUID: 501, home: home, myUID: 501) == .noPermission)
    }

    @Test func warningMentionsFDAOnlyForProtectedFolders() {
        let posix = Permissions.warningLines([("/Users/other", .otherUser)], terminalName: "Ghostty")
        #expect(posix[0] == "1 folder could not be read (permission denied); sizes below it are missing.")
        #expect(posix.contains("  /Users/other  (owned by another user)"))
        #expect(!posix.joined().contains("Full Disk Access: run"))

        let items = (0..<7).map { ("/Users/me/Library/x\($0)", UnreadableKind.privacyProtected) }
        let tcc = Permissions.warningLines(items, terminalName: "Ghostty")
        #expect(tcc[0].hasPrefix("7 folders could not be read"))
        #expect(tcc.count == 1 + 5 + 1 + 1)
        #expect(tcc.last == "Give Ghostty Full Disk Access: run `fil doctor`")
        #expect(Permissions.warningLines([], terminalName: nil).isEmpty)
    }

    @Test func incompleteFoldersChangeTheHeaderAndGetANote() {
        let lines = Permissions.warningLines([("/Users/me/Library/Mail", .privacyProtected), ("/data/x", .incomplete)],
                                             terminalName: "Ghostty")
        #expect(lines[0] == "2 folders could not be read fully; sizes below them are too low.")
        #expect(lines[1] == "  /Users/me/Library/Mail")
        #expect(lines[2] == "  /data/x  (could not be read completely)")
        #expect(lines.last == "Give Ghostty Full Disk Access: run `fil doctor`")
    }

    @Test func findsOutermostAppBundle() {
        #expect(ResponsibleApp.outermostBundle(in: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
            == "/System/Applications/Utilities/Terminal.app")
        #expect(ResponsibleApp.outermostBundle(in: "/Applications/Code.app/Contents/Frameworks/Helper.app/Contents/MacOS/H")
            == "/Applications/Code.app")
        #expect(ResponsibleApp.outermostBundle(in: "/usr/bin/zsh") == nil)
    }

    @Test func realProcessWalkAndProbeDoNotCrash() {
        #expect(ResponsibleApp.parentPID(of: getpid()) != nil)
        _ = FullDiskAccess.probe()
    }
}
