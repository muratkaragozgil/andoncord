import Foundation

/// What a system-wide board shortcut does to the request on the card.
///
/// Kept apart from the hot-key plumbing so the one rule that must hold is
/// testable: a press never decides something the person cannot see. When
/// the card is out of sight — the board collapsed, or hidden over a
/// fullscreen app — a press brings it up, and only the next one acts.
public enum CardShortcut: String, CaseIterable, Sendable {
    case allow
    case deny
    case alwaysAllow
    case toggleBoard

    /// ⌃⌥ plus a letter: a combination apps almost never claim for
    /// themselves, and a global hot key takes it from all of them.
    public var key: Character {
        switch self {
        case .allow: return "Y"
        case .deny: return "N"
        case .alwaysAllow: return "A"
        case .toggleBoard: return "B"
        }
    }

    public var label: String { "⌃⌥\(key)" }

    public enum Effect: Equatable, Sendable {
        /// Nothing on screen to act on: show the card instead.
        case reveal
        case approve
        case approveAlways(PermissionSuggestion)
        case deny
        case approvePlan
        case keepPlanning
        /// Means nothing for this card. A question wants an answer, not a
        /// yes, and there is no "always" a request did not offer.
        case ignore
    }

    public func effect(on request: PendingRequest?, cardOnScreen: Bool) -> Effect {
        guard self != .toggleBoard, let request else { return .ignore }
        guard cardOnScreen else { return .reveal }
        switch (self, request.kind) {
        case (.allow, .permission): return .approve
        case (.deny, .permission): return .deny
        case (.alwaysAllow, .permission):
            return PermissionSuggestion.from(request.suggestions).first.map(Effect.approveAlways)
                ?? .ignore
        case (.allow, .plan): return .approvePlan
        case (.deny, .plan): return .keepPlanning
        default: return .ignore
        }
    }
}
