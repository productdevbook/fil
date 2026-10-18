import Foundation

/// What the group checkbox of a rule shows.
public enum GroupSelectionState: Sendable, Equatable {
    case on, off, mixed
    /// The group has nothing the app can act on (info-only items).
    case unavailable
}

/// The Cleanup screen's selection rules, free of any UI:
///
/// - `safe` candidates start checked, `review` and `careful` start unchecked; only the first time a candidate is
///   seen, so a later refresh keeps the user's choice;
/// - info-only candidates (the Trash) can never be selected;
/// - a `careful` candidate is never selected in bulk, and selecting it on its own needs explicit confirmation;
/// - the group checkbox selects the group's actionable, non-careful items, or clears the whole group.
public struct CleanupSelection: Sendable, Equatable {
    public private(set) var ids: Set<String> = []
    private var known: Set<String> = []

    public init() {}

    /// Result of asking to select a candidate.
    public enum Request: Sendable, Equatable {
        /// The change was made.
        case applied
        /// A careful candidate: nothing changed; call again with `confirmed: true` after the user agreed.
        case needsConfirmation
        /// The candidate cannot be acted on; nothing changed.
        case ignored
    }

    public func isSelected(_ id: String) -> Bool { ids.contains(id) }

    /// Brings the selection in line with a new candidate list: choices for candidates that are still present
    /// survive, ids that disappeared are dropped, new `safe` actionable candidates are checked.
    public mutating func update(candidates: [Candidate]) {
        let present = Set(candidates.map(\.id))
        ids.formIntersection(present)
        for c in candidates where !known.contains(c.id) && c.safety == .safe && c.isActionable {
            ids.insert(c.id)
        }
        known = present
    }

    /// Checks or unchecks one candidate. Unchecking always works; checking a careful one needs `confirmed`.
    @discardableResult
    public mutating func set(_ c: Candidate, to on: Bool, confirmed: Bool = false) -> Request {
        guard on else {
            ids.remove(c.id)
            return .applied
        }
        guard c.isActionable else { return .ignored }
        if c.safety == .careful && !confirmed { return .needsConfirmation }
        ids.insert(c.id)
        return .applied
    }

    // MARK: Groups

    /// The items the group checkbox controls: careful ones are only ever checked one by one.
    static func bulk(_ group: [Candidate]) -> [Candidate] {
        group.filter { $0.isActionable && $0.safety != .careful }
    }

    public func state(of group: [Candidate]) -> GroupSelectionState {
        let items = group.filter(\.isActionable)
        guard !items.isEmpty else { return .unavailable }
        let n = items.filter { ids.contains($0.id) }.count
        if n == 0 { return .off }
        return n == items.count ? .on : .mixed
    }

    /// Group checkbox click: when every bulk item is checked, clear the whole group (careful items too);
    /// otherwise check the bulk items. Careful items are never checked this way.
    public mutating func toggleGroup(_ group: [Candidate]) {
        let items = Self.bulk(group)
        if !items.isEmpty && items.allSatisfy({ ids.contains($0.id) }) {
            ids.subtract(group.map(\.id))
        } else {
            ids.formUnion(items.map(\.id))
        }
    }

    // MARK: Totals

    /// The selected candidates of `candidates`, in their order.
    public func selected(in candidates: [Candidate]) -> [Candidate] {
        candidates.filter { ids.contains($0.id) }
    }

    public func totalBytes(in candidates: [Candidate]) -> Int64 {
        selected(in: candidates).reduce(0) { $0 + $1.bytes }
    }
}
