import Foundation

/// Turns a raw `tool_name` + `tool_input` pair into something displayable.
///
/// The notch has room for roughly one line, so the job here is aggressive
/// summarisation: a path relative to the project, a command's first clause, a
/// diff's net line count. Anything we do not recognise still renders — falling
/// back to the tool name beats showing nothing, since new tools appear
/// regularly and MCP servers can define arbitrary ones.
public struct ToolPresentation: Sendable, Equatable {
    /// e.g. `Edit`, `Bash`, `serena · find_symbol`
    public var title: String
    /// e.g. `src/auth/middleware.ts`, `npm test`
    public var subtitle: String?
    public var kind: Kind

    public enum Kind: Sendable, Equatable {
        case edit(EditDetail)
        case write(path: String, lineCount: Int)
        case shell(command: String, description: String?)
        case read(path: String)
        case search(pattern: String, scope: String?)
        case web(url: String)
        case subagent(type: String, prompt: String?)
        case plan(markdown: String)
        case question(QuestionDetail)
        case generic
    }

    public struct EditDetail: Sendable, Equatable {
        public var path: String
        public var oldString: String
        public var newString: String
        public var replaceAll: Bool

        /// Cheap line-count delta for the `+3 −1` badge. This is a summary for
        /// a one-line badge, not a real diff — the card renders the actual
        /// before/after text.
        public var lineDelta: (added: Int, removed: Int) {
            let removed = oldString.isEmpty ? 0 : oldString.components(separatedBy: "\n").count
            let added = newString.isEmpty ? 0 : newString.components(separatedBy: "\n").count
            return (added, removed)
        }
    }

    public struct QuestionDetail: Sendable, Equatable {
        public var header: String?
        public var question: String
        public var options: [Option]
        public var multiSelect: Bool

        public struct Option: Sendable, Equatable, Identifiable {
            public var id: String { label }
            public var label: String
            public var description: String?
        }
    }

    public static func make(toolName: String, input: JSONValue?) -> ToolPresentation {
        let object = input?.objectValue ?? [:]

        func string(_ key: String) -> String? { object[key]?.stringValue }

        switch toolName {
        case "Edit":
            let detail = EditDetail(
                path: string("file_path") ?? "",
                oldString: string("old_string") ?? "",
                newString: string("new_string") ?? "",
                replaceAll: object["replace_all"]?.boolValue ?? false)
            return ToolPresentation(
                title: "Edit", subtitle: shortPath(detail.path), kind: .edit(detail))

        case "Write":
            let path = string("file_path") ?? ""
            let content = string("content") ?? ""
            let lines = content.isEmpty ? 0 : content.components(separatedBy: "\n").count
            return ToolPresentation(
                title: "Write", subtitle: shortPath(path),
                kind: .write(path: path, lineCount: lines))

        case "NotebookEdit":
            let path = string("notebook_path") ?? ""
            return ToolPresentation(
                title: "NotebookEdit", subtitle: shortPath(path), kind: .read(path: path))

        case "Bash", "BashOutput":
            let command = string("command") ?? ""
            return ToolPresentation(
                title: "Bash", subtitle: firstLine(command),
                kind: .shell(command: command, description: string("description")))

        case "Read":
            let path = string("file_path") ?? ""
            return ToolPresentation(
                title: "Read", subtitle: shortPath(path), kind: .read(path: path))

        case "Glob", "Grep":
            let pattern = string("pattern") ?? ""
            return ToolPresentation(
                title: toolName, subtitle: pattern,
                kind: .search(pattern: pattern, scope: string("path")))

        case "WebFetch", "WebSearch":
            let target = string("url") ?? string("query") ?? ""
            return ToolPresentation(
                title: toolName, subtitle: target, kind: .web(url: target))

        case "Task", "Agent":
            let type = string("subagent_type") ?? "agent"
            return ToolPresentation(
                title: "Subagent", subtitle: string("description") ?? type,
                kind: .subagent(type: type, prompt: string("prompt")))

        case InterceptedTool.exitPlanMode.rawValue:
            let plan = string("plan") ?? ""
            return ToolPresentation(
                title: "Plan review", subtitle: nil, kind: .plan(markdown: plan))

        case InterceptedTool.askUserQuestion.rawValue:
            return ToolPresentation(
                title: "Claude asks", subtitle: nil,
                kind: .question(parseQuestion(object)))

        default:
            // MCP tools arrive as `mcp__<server>__<tool>`; showing the server
            // is more useful than the mangled identifier.
            if toolName.hasPrefix("mcp__") {
                let parts = toolName.dropFirst(5).components(separatedBy: "__")
                if parts.count >= 2 {
                    return ToolPresentation(
                        title: "\(parts[0]) · \(parts.dropFirst().joined(separator: "·"))",
                        subtitle: summarise(object), kind: .generic)
                }
            }
            return ToolPresentation(
                title: toolName, subtitle: summarise(object), kind: .generic)
        }
    }

    /// `AskUserQuestion` nests a `questions` array; we present the first one,
    /// since the notch answers them one at a time.
    private static func parseQuestion(_ object: [String: JSONValue]) -> QuestionDetail {
        let first = object["questions"]?.arrayValue?.first?.objectValue ?? object

        let options = (first["options"]?.arrayValue ?? []).compactMap { entry -> QuestionDetail.Option? in
            guard let fields = entry.objectValue,
                  let label = fields["label"]?.stringValue else { return nil }
            return .init(label: label, description: fields["description"]?.stringValue)
        }
        return QuestionDetail(
            header: first["header"]?.stringValue,
            question: first["question"]?.stringValue ?? "Claude needs an answer",
            options: options,
            multiSelect: first["multiSelect"]?.boolValue ?? false)
    }

    // MARK: - Formatting helpers

    /// Last two path components — enough to disambiguate without wrapping.
    public static func shortPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let parts = path.components(separatedBy: "/").filter { !$0.isEmpty }
        return parts.suffix(2).joined(separator: "/")
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.components(separatedBy: "\n").first ?? text
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    /// Last-resort subtitle for a tool we have no special handling for.
    private static func summarise(_ object: [String: JSONValue]) -> String? {
        for key in ["file_path", "path", "command", "query", "url", "name", "pattern"] {
            if let value = object[key]?.stringValue, !value.isEmpty {
                return firstLine(value)
            }
        }
        return nil
    }

    /// One-line activity-feed rendering, e.g. `Edit(middleware.ts)`.
    public var activityLine: String {
        guard let subtitle, !subtitle.isEmpty else { return title }
        return "\(title)(\(subtitle))"
    }
}
