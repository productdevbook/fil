import CleanCore
import Testing

private func candidate(
    _ id: String, rule: String = "r", _ safety: Safety, bytes: Int64 = 1 << 20,
    removal: Removal = .trash
) -> Candidate {
    Candidate(id: id, ruleId: rule, path: "/h/" + id, bytes: bytes, safety: safety, removal: removal)
}

private let safeA = candidate("safeA", .safe, bytes: 5_000_000)
private let safeB = candidate("safeB", .safe, bytes: 3_000_000)
private let review = candidate("review", .review, bytes: 4_000_000)
private let careful = candidate("careful", .careful, bytes: 2_000_000)
private let infoOnly = candidate("trash", .review, bytes: 1_000_000, removal: .none)
private let all = [safeA, safeB, review, careful, infoOnly]

private func fresh(_ cs: [Candidate] = all) -> CleanupSelection {
    var s = CleanupSelection()
    s.update(candidates: cs)
    return s
}

@Suite("Cleanup selection rules")
struct SelectionTests {
    @Test("safe starts checked; review, careful and info-only do not")
    func initialState() {
        let s = fresh()
        #expect(s.ids == ["safeA", "safeB"])
    }

    @Test("a refresh keeps the user's choices and does not re-check what they unchecked")
    func refreshKeepsChoices() {
        var s = fresh()
        s.set(safeA, to: false)
        s.set(review, to: true)
        s.update(candidates: all)
        #expect(s.ids == ["safeB", "review"])
    }

    @Test("ids that disappeared are dropped; new safe candidates are checked")
    func refreshDropsAndAdds() {
        var s = fresh()
        s.set(review, to: true)
        let newSafe = candidate("safeC", .safe)
        s.update(candidates: [safeB, review, newSafe])
        #expect(s.ids == ["safeB", "review", "safeC"])
    }

    @Test("a candidate that vanished and came back is treated as a choice already made")
    func reappearingSafeCandidateStaysUnchecked() {
        var s = fresh()
        s.set(safeA, to: false)
        s.update(candidates: [safeA, safeB, review, careful, infoOnly])
        #expect(!s.isSelected("safeA"))
    }

    @Test("toggling a row off and on changes the total")
    func toggleChangesTotal() {
        var s = fresh()
        #expect(s.totalBytes(in: all) == 8_000_000)
        s.set(safeB, to: false)
        #expect(s.totalBytes(in: all) == 5_000_000)
        s.set(safeB, to: true)
        #expect(s.totalBytes(in: all) == 8_000_000)
        #expect(s.selected(in: all).map(\.id) == ["safeA", "safeB"])
    }

    @Test("checking a careful item needs confirmation; only the confirmed call selects it")
    func carefulNeedsConfirmation() {
        var s = fresh()
        #expect(s.set(careful, to: true) == .needsConfirmation)
        #expect(!s.isSelected("careful"))
        #expect(s.set(careful, to: true, confirmed: true) == .applied)
        #expect(s.isSelected("careful"))
        #expect(s.totalBytes(in: all) == 10_000_000)
    }

    @Test("unchecking a careful item never asks")
    func uncheckingCarefulIsFree() {
        var s = fresh()
        s.set(careful, to: true, confirmed: true)
        #expect(s.set(careful, to: false) == .applied)
        #expect(!s.isSelected("careful"))
    }

    @Test("info-only items cannot be selected")
    func infoOnlyIgnored() {
        var s = fresh()
        #expect(s.set(infoOnly, to: true) == .ignored)
        #expect(!s.isSelected("trash"))
    }

    @Test("group checkbox: tri-state")
    func groupState() {
        var s = fresh()
        let group = [safeA, safeB, careful]
        #expect(s.state(of: group) == .mixed)  // two of three
        s.set(careful, to: true, confirmed: true)
        #expect(s.state(of: group) == .on)
        s.set(safeA, to: false); s.set(safeB, to: false); s.set(careful, to: false)
        #expect(s.state(of: group) == .off)
        #expect(s.state(of: [infoOnly]) == .unavailable)
        #expect(s.state(of: []) == .unavailable)
    }

    @Test("group checkbox selects the bulk items but never the careful one")
    func groupNeverSelectsCareful() {
        var s = CleanupSelection()
        s.update(candidates: [review, careful])  // nothing starts checked
        s.toggleGroup([review, careful])
        #expect(s.ids == ["review"])
        #expect(s.state(of: [review, careful]) == .mixed)
    }

    @Test("group checkbox: all bulk items checked clears the whole group, careful included")
    func groupClearsEverything() {
        var s = fresh()
        s.toggleGroup([safeA, safeB])  // both on -> off
        #expect(s.ids.isEmpty)
        s.toggleGroup([safeA, safeB])  // off -> on
        #expect(s.ids == ["safeA", "safeB"])
        s.set(careful, to: true, confirmed: true)
        s.toggleGroup([safeA, safeB, careful])  // bulk all on -> clears the careful one too
        #expect(s.ids.isEmpty)
    }

    @Test("group checkbox on a partly checked group checks the rest")
    func groupCompletesMixed() {
        var s = fresh()
        s.set(safeB, to: false)
        s.toggleGroup([safeA, safeB])
        #expect(s.ids == ["safeA", "safeB"])
    }

    @Test("group of only a careful item: the checkbox does nothing")
    func groupOfOnlyCareful() {
        var s = fresh()
        s.toggleGroup([careful])
        #expect(!s.isSelected("careful"))
    }

    @Test("totals only count candidates of the given list")
    func totalsUseCurrentCandidates() {
        let s = fresh()
        #expect(s.totalBytes(in: [safeA]) == 5_000_000)
        #expect(s.totalBytes(in: []) == 0)
    }
}
