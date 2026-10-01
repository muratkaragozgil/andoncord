import AndonKit
import SwiftUI

/// The card shown when a cord is pulled.
///
/// This is the one screen the whole app exists to present, so it optimises for
/// deciding fast and correctly: what is being asked, on which file, with the
/// actual change visible — then two obvious buttons with keyboard shortcuts.
struct RequestCardView: View {
    let session: Session
    let request: PendingRequest
    let app: AppState

    private var tool: ToolPresentation {
        ToolPresentation.make(toolName: request.toolName, input: request.toolInput)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            switch tool.kind {
            case .question(let detail):
                QuestionBody(detail: detail) { answer in
                    app.board.answerQuestion(request, answer: answer)
                }
            case .plan(let markdown):
                PlanBody(markdown: markdown,
                         onApprove: { app.board.approvePlan(request) },
                         onReject: { app.board.rejectPlan(request, feedback: $0) })
            default:
                PermissionBody(tool: tool, request: request, app: app)
            }
        }
        .padding(.horizontal, AndonTheme.Metrics.horizontalPadding)
        .padding(.vertical, 11)
        .background(AndonTheme.amber.opacity(0.07))
        .overlay(alignment: .leading) {
            // A vertical amber rule, the visual equivalent of the pulled cord.
            Rectangle()
                .fill(AndonTheme.amber)
                .frame(width: 2)
        }
        .overlay(alignment: .top) { Divider().overlay(AndonTheme.hairline) }
        .overlay(alignment: .bottom) { Divider().overlay(AndonTheme.hairline) }
    }

    private var header: some View {
        HStack(spacing: 7) {
            AndonLamp(state: .cordPulled(request.cordReason), size: 7)

            Text(headline)
                .font(AndonTheme.label(10))
                .tracking(0.8)
                .foregroundStyle(AndonTheme.amber)

            Spacer(minLength: 4)

            Text(session.title)
                .font(AndonTheme.body(10))
                .foregroundStyle(AndonTheme.textTertiary)
                .lineLimit(1)
        }
    }

    private var headline: String {
        switch request.kind {
        case .permission: return "CORD PULLED · PERMISSION"
        case .question: return "CLAUDE ASKS"
        case .plan: return "PLAN REVIEW"
        }
    }
}

// MARK: - Permission

private struct PermissionBody: View {
    let tool: ToolPresentation
    let request: PendingRequest
    let app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(tool.title)
                    .font(AndonTheme.body(12, weight: .semibold))
                    .foregroundStyle(AndonTheme.textPrimary)
                if let subtitle = tool.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(AndonTheme.code(11))
                        .foregroundStyle(AndonTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            detail

            HStack(spacing: 7) {
                Button("Deny") {
                    app.board.deny(request)
                }
                .buttonStyle(AndonButtonStyle(tint: AndonTheme.red))
                .keyboardShortcut("n", modifiers: .command)

                Button("Allow") {
                    app.board.approve(request)
                }
                .buttonStyle(AndonButtonStyle(tint: AndonTheme.green, prominent: true))
                .keyboardShortcut("y", modifiers: .command)

                // Persists an allow rule so this shape of call stops asking.
                if let rule = alwaysAllowRule {
                    Button("Always allow") {
                        app.board.approve(request, alwaysRule: rule)
                    }
                    .buttonStyle(AndonButtonStyle(tint: AndonTheme.textSecondary))
                    .help("Adds the permission rule \(rule)")
                }

                Spacer(minLength: 0)

                Text("⌘Y / ⌘N")
                    .font(AndonTheme.numeric(9))
                    .foregroundStyle(AndonTheme.textTertiary)
            }
        }
    }

    /// A permission rule matching the whole tool, which is the only
    /// generalisation safe to offer without guessing at argument shapes.
    private var alwaysAllowRule: String? {
        switch tool.kind {
        case .shell:
            // Bash rules are argument-sensitive; blanket-allowing every shell
            // command from one click is not a choice to make casually, so it
            // is deliberately not offered here.
            return nil
        case .edit, .write, .read, .search:
            return request.toolName
        default:
            return request.toolName
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch tool.kind {
        case .edit(let edit):
            DiffView(detail: edit)
        case .write(_, let lineCount):
            CodeBlock(text: "New file · \(lineCount) line\(lineCount == 1 ? "" : "s")",
                      tint: AndonTheme.green)
        case .shell(let command, let description):
            VStack(alignment: .leading, spacing: 4) {
                if let description, !description.isEmpty {
                    Text(description)
                        .font(AndonTheme.body(11))
                        .foregroundStyle(AndonTheme.textSecondary)
                }
                CodeBlock(text: command, tint: AndonTheme.textPrimary)
            }
        case .web(let url):
            CodeBlock(text: url, tint: AndonTheme.textSecondary)
        case .subagent(let type, let prompt):
            CodeBlock(text: prompt.map { "\(type): \($0)" } ?? type,
                      tint: AndonTheme.textSecondary)
        case .read, .search, .generic, .plan, .question:
            EmptyView()
        }
    }
}

/// Before/after for an `Edit`.
///
/// Not a real diff algorithm — Claude Code hands us the exact old and new
/// strings, so a line-level render of both is both faithful and cheaper than
/// running a diff over text we already know the shape of.
private struct DiffView: View {
    let detail: ToolPresentation.EditDetail

    private var removedLines: [String] {
        detail.oldString.isEmpty ? [] : detail.oldString.components(separatedBy: "\n")
    }
    private var addedLines: [String] {
        detail.newString.isEmpty ? [] : detail.newString.components(separatedBy: "\n")
    }

    /// Long edits are truncated; the point of the card is deciding whether to
    /// allow the change, not reading the whole file.
    private static let maxLines = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(removedLines.prefix(Self.maxLines).enumerated()), id: \.offset) {
                    line($0.element, sign: "−", tint: AndonTheme.red)
                }
                ForEach(Array(addedLines.prefix(Self.maxLines).enumerated()), id: \.offset) {
                    line($0.element, sign: "+", tint: AndonTheme.green)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AndonTheme.surface)
            }

            HStack(spacing: 8) {
                let delta = detail.lineDelta
                Text("+\(delta.added)")
                    .foregroundStyle(AndonTheme.green)
                Text("−\(delta.removed)")
                    .foregroundStyle(AndonTheme.red)
                if removedLines.count > Self.maxLines || addedLines.count > Self.maxLines {
                    Text("truncated")
                        .foregroundStyle(AndonTheme.textTertiary)
                }
                if detail.replaceAll {
                    Text("all occurrences")
                        .foregroundStyle(AndonTheme.amber)
                }
            }
            .font(AndonTheme.numeric(9))
        }
    }

    private func line(_ text: String, sign: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(sign)
                .font(AndonTheme.code(10))
                .foregroundStyle(tint)
            Text(text.isEmpty ? " " : text)
                .font(AndonTheme.code(10))
                .foregroundStyle(AndonTheme.textPrimary.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 0.5)
        .background(tint.opacity(0.08))
    }
}

private struct CodeBlock: View {
    let text: String
    var tint: Color = AndonTheme.textPrimary

    var body: some View {
        Text(text)
            .font(AndonTheme.code(11))
            .foregroundStyle(tint)
            .textSelection(.enabled)
            .lineLimit(4)
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AndonTheme.surface)
            }
    }
}

// MARK: - Question

private struct QuestionBody: View {
    let detail: ToolPresentation.QuestionDetail
    let onAnswer: (String) -> Void

    @State private var freeform = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(detail.question)
                .font(AndonTheme.body(12, weight: .medium))
                .foregroundStyle(AndonTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 5) {
                ForEach(Array(detail.options.enumerated()), id: \.element.id) { index, option in
                    Button {
                        onAnswer(option.label)
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(AndonTheme.numeric(9, weight: .bold))
                                .foregroundStyle(AndonTheme.textTertiary)
                                .frame(width: 12)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.label)
                                    .font(AndonTheme.body(12, weight: .medium))
                                    .foregroundStyle(AndonTheme.textPrimary)
                                if let description = option.description {
                                    Text(description)
                                        .font(AndonTheme.body(10))
                                        .foregroundStyle(AndonTheme.textTertiary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(AndonTheme.surfaceRaised)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Number keys mirror how the same prompt is answered in
                    // the terminal, so the muscle memory carries over.
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(min(index + 1, 9))")), modifiers: .command)
                }
            }

            // Claude sometimes asks something the options do not cover; the
            // terminal always allows a typed answer, so this must too.
            HStack(spacing: 6) {
                TextField("Or type an answer…", text: $freeform)
                    .textFieldStyle(.plain)
                    .font(AndonTheme.body(11))
                    .foregroundStyle(AndonTheme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AndonTheme.surface)
                    }
                    .onSubmit(submitFreeform)

                Button("Send", action: submitFreeform)
                    .buttonStyle(AndonButtonStyle(tint: AndonTheme.accent, prominent: true))
                    .disabled(freeform.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func submitFreeform() {
        let trimmed = freeform.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAnswer(trimmed)
    }
}

// MARK: - Plan review

private struct PlanBody: View {
    let markdown: String
    let onApprove: () -> Void
    let onReject: (String) -> Void

    @State private var isWritingFeedback = false
    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ScrollView {
                MarkdownView(source: markdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .padding(9)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(AndonTheme.surface)
            }

            if isWritingFeedback {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $feedback)
                        .font(AndonTheme.body(11))
                        .scrollContentBackground(.hidden)
                        .frame(height: 58)
                        .padding(6)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(AndonTheme.surface)
                        }
                    HStack(spacing: 7) {
                        Button("Cancel") { isWritingFeedback = false }
                            .buttonStyle(AndonButtonStyle(tint: AndonTheme.textSecondary))
                        Button("Send feedback") { onReject(feedback) }
                            .buttonStyle(AndonButtonStyle(tint: AndonTheme.amber, prominent: true))
                    }
                }
            } else {
                HStack(spacing: 7) {
                    Button("Revise…") {
                        isWritingFeedback = true
                    }
                    .buttonStyle(AndonButtonStyle(tint: AndonTheme.amber))
                    .keyboardShortcut("r", modifiers: .command)

                    Button("Approve plan") { onApprove() }
                        .buttonStyle(AndonButtonStyle(tint: AndonTheme.green, prominent: true))
                        .keyboardShortcut("y", modifiers: .command)

                    Spacer(minLength: 0)
                    Text("⌘Y / ⌘R")
                        .font(AndonTheme.numeric(9))
                        .foregroundStyle(AndonTheme.textTertiary)
                }
            }
        }
    }
}

/// Minimal block-level Markdown renderer.
///
/// `AttributedString(markdown:)` handles inline styling but collapses block
/// structure, and a plan is almost entirely block structure — headings, bullet
/// lists, fenced code. Rendering those four cases covers what plans actually
/// contain; anything else falls through as styled inline text.
struct MarkdownView: View {
    let source: String

    private enum Block: Identifiable {
        case heading(String, level: Int)
        case bullet(String)
        case numbered(String, index: Int)
        case code(String)
        case paragraph(String)

        var id: String {
            switch self {
            case .heading(let t, let l): return "h\(l)-\(t)"
            case .bullet(let t): return "b-\(t)"
            case .numbered(let t, let i): return "n\(i)-\(t)"
            case .code(let t): return "c-\(t.prefix(40))"
            case .paragraph(let t): return "p-\(t.prefix(40))"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(parse()) { block in
                switch block {
                case .heading(let text, let level):
                    Text(inline(text))
                        .font(AndonTheme.body(level <= 1 ? 13 : 12, weight: .bold))
                        .foregroundStyle(AndonTheme.textPrimary)
                        .padding(.top, 2)
                case .bullet(let text):
                    HStack(alignment: .top, spacing: 6) {
                        Text("▪").font(AndonTheme.body(9)).foregroundStyle(AndonTheme.accent)
                        Text(inline(text)).font(AndonTheme.body(11))
                            .foregroundStyle(AndonTheme.textSecondary)
                    }
                case .numbered(let text, let index):
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index).").font(AndonTheme.numeric(10))
                            .foregroundStyle(AndonTheme.accent)
                        Text(inline(text)).font(AndonTheme.body(11))
                            .foregroundStyle(AndonTheme.textSecondary)
                    }
                case .code(let text):
                    Text(text)
                        .font(AndonTheme.code(10))
                        .foregroundStyle(AndonTheme.textPrimary.opacity(0.9))
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: 5).fill(AndonTheme.void.opacity(0.6))
                        }
                case .paragraph(let text):
                    Text(inline(text))
                        .font(AndonTheme.body(11))
                        .foregroundStyle(AndonTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Inline styling (bold, code spans) via the system parser.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// Match `1. text`. Done by hand rather than with a regex because this
    /// runs per line on every plan render, and the grammar is trivial.
    private static func parseNumberedItem(_ line: String) -> (index: Int, text: String)? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, let index = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(".") else { return nil }
        let text = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (index, text)
    }

    private func parse() -> [Block] {
        var blocks: [Block] = []
        var codeBuffer: [String] = []
        var inCode = false
        var numberedIndex = 0

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeBuffer.joined(separator: "\n")))
                    codeBuffer.removeAll()
                }
                inCode.toggle()
                continue
            }
            if inCode { codeBuffer.append(rawLine); continue }

            if line.isEmpty { numberedIndex = 0; continue }

            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                blocks.append(.heading(
                    line.dropFirst(level).trimmingCharacters(in: .whitespaces), level: level))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if let item = Self.parseNumberedItem(line) {
                numberedIndex = item.index
                blocks.append(.numbered(item.text, index: item.index))
            } else {
                blocks.append(.paragraph(line))
            }
        }
        if inCode, !codeBuffer.isEmpty {
            blocks.append(.code(codeBuffer.joined(separator: "\n")))
        }
        return blocks
    }
}
