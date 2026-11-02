import Foundation

/// One of the "don't ask again" options Claude Code offers with a permission
/// request, worded for a button.
///
/// These arrive in the `PermissionRequest` payload as `permission_suggestions`
/// and are exactly what the terminal dialog's own "Yes, and don't ask again…"
/// option applies. Handing one back verbatim in `updatedPermissions` makes the
/// notch's "always" mean precisely what the terminal's would — including the
/// argument-aware rules for shell commands (`Bash(npm test:*)`) that a rule
/// guessed from the tool name alone could never express.
public struct PermissionSuggestion: Sendable, Equatable, Identifiable {
    /// The entry as Claude Code sent it. This, not anything rebuilt from the
    /// fields below, is what goes back.
    public let raw: JSONValue
    public let label: String
    /// Longer wording for a tooltip: what will be written, and where.
    public let detail: String

    public var id: String { label }

    /// Nil for entries that are not a way of saying yes — rule removals, deny
    /// or ask rules — which have no business on an allow button.
    public init?(_ raw: JSONValue) {
        guard let object = raw.objectValue, let type = object["type"]?.stringValue else { return nil }
        let destination = Self.describe(destination: object["destination"]?.stringValue)
        self.raw = raw

        switch type {
        case "addRules":
            guard (object["behavior"]?.stringValue ?? "allow") == "allow" else { return nil }
            let rules = (object["rules"]?.arrayValue ?? []).compactMap { rule -> String? in
                guard let fields = rule.objectValue,
                      let tool = fields["toolName"]?.stringValue else { return nil }
                guard let content = fields["ruleContent"]?.stringValue, !content.isEmpty else {
                    return tool
                }
                return "\(tool)(\(content))"
            }
            guard !rules.isEmpty else { return nil }
            let shown = rules.count == 1 ? rules[0] : "\(rules[0]) +\(rules.count - 1)"
            label = "Always allow \(Self.clip(shown))"
            detail = "Adds \(rules.joined(separator: ", ")) to the allow rules \(destination)"

        case "setMode":
            guard let mode = object["mode"]?.stringValue else { return nil }
            switch mode {
            case "acceptEdits":
                label = "Allow all edits"
                detail = "Accepts file edits without asking \(destination)"
            case "plan", "default", "manual":
                return nil
            default:
                label = "Switch to \(mode)"
                detail = "Changes the permission mode to \(mode) \(destination)"
            }

        case "addDirectories":
            let directories = (object["directories"]?.arrayValue ?? []).compactMap(\.stringValue)
            guard let first = directories.first else { return nil }
            let name = URL(fileURLWithPath: first).lastPathComponent
            label = "Always allow \(Self.clip(name.isEmpty ? first : name))/"
            detail = "Adds \(directories.joined(separator: ", ")) to the working directories \(destination)"

        default:
            return nil
        }
    }

    /// Every usable suggestion, in the order Claude Code listed them.
    public static func from(_ entries: [JSONValue]) -> [PermissionSuggestion] {
        var seen = Set<String>()
        return entries.compactMap(PermissionSuggestion.init).filter { seen.insert($0.label).inserted }
    }

    private static func describe(destination: String?) -> String {
        switch destination {
        case "session": return "for this session"
        case "localSettings": return "in this project (.claude/settings.local.json)"
        case "projectSettings": return "in this project (.claude/settings.json)"
        case "userSettings": return "everywhere (~/.claude/settings.json)"
        case let other?: return "in \(other)"
        case nil: return ""
        }
    }

    private static func clip(_ text: String, to limit: Int = 34) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
