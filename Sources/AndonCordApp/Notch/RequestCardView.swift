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
                QuestionBody(detail: detail) { answers in
                    app.board.answerQuestion(request, answers: answers)
                }
                // Each request gets a fresh form; state from the last one
                // must not leak into the next in line.
                .id(request.id)
            case .plan(let markdown):
                PlanBody(markdown: markdown,
                         shortcutHint: app.settings.globalShortcuts
                            ? "\(CardShortcut.allow.label) approve · \(CardShortcut.deny.label) keep planning"
                            : "⌘Y / ⇧⌘Y / ⌘R",
                         onApprove: { app.board.approvePlan(request, acceptEdits: $0) },
                         onReject: { app.board.rejectPlan(request, feedback: $0) })
                    .id(request.id)
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

            if request.agentId != nil {
                AndonChip(text: "subagent")
                    .help("Asked by a subagent working for this session")
            }
            if !session.queued.isEmpty {
                AndonChip(text: "+\(session.queued.count) waiting", color: AndonTheme.amber)
                    .help("More requests from this session are lined up behind this one")
            }

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

                // Claude Code's own "don't ask again" options, worded and
                // scoped exactly as its terminal dialog would offer them.
                if let first = suggestions.first {
                    Button(first.label) {
                        app.board.approve(request, always: first)
                    }
                    .buttonStyle(AndonButtonStyle(tint: AndonTheme.textSecondary))
                    .keyboardShortcut("a", modifiers: .command)
                    .help(first.detail)
                    .lineLimit(1)

                    if suggestions.count > 1 {
                        Menu {
                            ForEach(suggestions.dropFirst()) { suggestion in
                                Button(suggestion.label) {
                                    app.board.approve(request, always: suggestion)
                                }
                                .help(suggestion.detail)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .foregroundStyle(AndonTheme.textSecondary)
                        .help("Other ways to stop asking")
                    }
                }

                Spacer(minLength: 0)

                Text(shortcutHint)
                    .font(AndonTheme.numeric(9))
                    .foregroundStyle(AndonTheme.textTertiary)
            }
        }
    }

    private var suggestions: [PermissionSuggestion] {
        PermissionSuggestion.from(request.suggestions)
    }

    /// The shortcuts that reach this card from wherever the person is. The
    /// ⌘ ones only work once the panel has been clicked.
    private var shortcutHint: String {
        let global = app.settings.globalShortcuts
        let keys = suggestions.isEmpty
            ? [CardShortcut.allow, .deny] : [CardShortcut.allow, .alwaysAllow, .deny]
        return keys.map { global ? $0.label : "⌘\($0.key)" }.joined(separator: " / ")
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

/// Every question of an `AskUserQuestion` call, answered as one set.
///
/// A single plain question keeps the old one-click flow — picking an option
/// is the answer, as in the terminal. Several questions, or a multi-select,
/// collect choices first and send them together, because the tool runs once
/// with all of its answers.
private struct QuestionBody: View {
    let detail: ToolPresentation.QuestionDetail
    let onAnswer: ([String: [String]]) -> Void

    /// Labels picked per question, by question text.
    @State private var picked: [String: Set<String>] = [:]
    /// Typed answers per question, by question text.
    @State private var typed: [String: String] = [:]

    private var answersOnClick: Bool {
        detail.questions.count == 1
            && !detail.questions[0].multiSelect
            && !detail.questions[0].options.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let title = detail.title, !title.isEmpty {
                Text(title)
                    .font(AndonTheme.body(12, weight: .semibold))
                    .foregroundStyle(AndonTheme.textPrimary)
            }

            ForEach(Array(detail.questions.enumerated()), id: \.element.id) { index, question in
                questionView(question, isFirst: index == 0)
            }

            if !answersOnClick {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Text("\(answeredCount) of \(detail.questions.count) answered")
                        .font(AndonTheme.numeric(9))
                        .foregroundStyle(AndonTheme.textTertiary)
                    Button("Send answers", action: submitAll)
                        .buttonStyle(AndonButtonStyle(tint: AndonTheme.accent, prominent: true))
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(answeredCount == 0)
                }
            }
        }
    }

    private func questionView(_ question: ToolPresentation.Question, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if question.header?.isEmpty == false || question.multiSelect {
                HStack(spacing: 5) {
                    if let header = question.header, !header.isEmpty { AndonChip(text: header) }
                    if question.multiSelect { AndonChip(text: "pick any", color: AndonTheme.accent) }
                }
            }

            Text(question.question)
                .font(AndonTheme.body(12, weight: .medium))
                .foregroundStyle(AndonTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if !question.options.isEmpty {
                VStack(spacing: 5) {
                    ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                        optionRow(option, index: index, in: question, numbered: isFirst)
                    }
                }
            }

            // Claude sometimes asks something the options do not cover; the
            // terminal always allows a typed answer, so this must too.
            HStack(spacing: 6) {
                TextField(
                    question.expectsTypedAnswer
                        ? (question.placeholder ?? "Type an answer…") : "Or type an answer…",
                    text: typedBinding(for: question))
                    .textFieldStyle(.plain)
                    .font(AndonTheme.body(11))
                    .foregroundStyle(AndonTheme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AndonTheme.surface)
                    }
                    .onSubmit { if answersOnClick { submitTyped(question) } }

                if answersOnClick {
                    Button("Send") { submitTyped(question) }
                        .buttonStyle(AndonButtonStyle(tint: AndonTheme.accent, prominent: true))
                        .disabled(typedText(for: question).isEmpty)
                }
            }
        }
    }

    private func optionRow(
        _ option: ToolPresentation.Question.Option, index: Int,
        in question: ToolPresentation.Question, numbered: Bool
    ) -> some View {
        let isPicked = picked[question.question]?.contains(option.label) == true
        return Button {
            choose(option, in: question)
        } label: {
            HStack(spacing: 8) {
                if answersOnClick {
                    Text("\(index + 1)")
                        .font(AndonTheme.numeric(9, weight: .bold))
                        .foregroundStyle(AndonTheme.textTertiary)
                        .frame(width: 12)
                } else {
                    Image(systemName: question.multiSelect
                          ? (isPicked ? "checkmark.square.fill" : "square")
                          : (isPicked ? "largecircle.fill.circle" : "circle"))
                        .font(.system(size: 11))
                        .foregroundStyle(isPicked ? AndonTheme.accent : AndonTheme.textTertiary)
                        .frame(width: 12)
                }

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
                    .fill(isPicked ? AndonTheme.accent.opacity(0.16) : AndonTheme.surfaceRaised)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Number keys mirror how the same prompt is answered in the
        // terminal, so the muscle memory carries over. Only the first
        // question gets them; ⌘1 cannot mean two things.
        .numberShortcut(index, enabled: numbered)
    }

    // MARK: Answers

    private func choose(_ option: ToolPresentation.Question.Option, in question: ToolPresentation.Question) {
        if answersOnClick {
            onAnswer([question.question: [option.label]])
            return
        }
        var labels = picked[question.question] ?? []
        if question.multiSelect {
            if labels.contains(option.label) { labels.remove(option.label) } else { labels.insert(option.label) }
        } else {
            labels = labels.contains(option.label) ? [] : [option.label]
            // A pick replaces whatever was typed, as choosing does in the
            // terminal.
            typed[question.question] = nil
        }
        picked[question.question] = labels
    }

    private func typedBinding(for question: ToolPresentation.Question) -> Binding<String> {
        Binding(
            get: { typed[question.question] ?? "" },
            set: { text in
                typed[question.question] = text
                // Typing is the "Other" answer: for a single choice it stands
                // in for a picked option.
                if !question.multiSelect, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    picked[question.question] = nil
                }
            })
    }

    private func typedText(for question: ToolPresentation.Question) -> String {
        (typed[question.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Labels in the order the question listed them, then anything typed.
    private func answer(for question: ToolPresentation.Question) -> [String] {
        let chosen = question.options.map(\.label).filter { picked[question.question]?.contains($0) == true }
        let text = typedText(for: question)
        if text.isEmpty { return chosen }
        return question.multiSelect ? chosen + [text] : [text]
    }

    private var answeredCount: Int {
        detail.questions.filter { !answer(for: $0).isEmpty }.count
    }

    private func submitTyped(_ question: ToolPresentation.Question) {
        let text = typedText(for: question)
        guard !text.isEmpty else { return }
        onAnswer([question.question: [text]])
    }

    private func submitAll() {
        var answers: [String: [String]] = [:]
        for question in detail.questions {
            let labels = answer(for: question)
            if !labels.isEmpty { answers[question.question] = labels }
        }
        guard !answers.isEmpty else { return }
        onAnswer(answers)
    }
}

private extension View {
    /// ⌘1–⌘9 on the first nine options, and nothing on the rest.
    @ViewBuilder
    func numberShortcut(_ index: Int, enabled: Bool) -> some View {
        if enabled, index < 9 {
            keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        } else {
            self
        }
    }
}

// MARK: - Plan review

private struct PlanBody: View {
    let markdown: String
    let shortcutHint: String
    /// `true` to also start accepting edits without asking.
    let onApprove: (Bool) -> Void
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
                    Button("Keep planning…") {
                        isWritingFeedback = true
                    }
                    .buttonStyle(AndonButtonStyle(tint: AndonTheme.amber))
                    .keyboardShortcut("r", modifiers: .command)

                    Button("Approve") { onApprove(false) }
                        .buttonStyle(AndonButtonStyle(tint: AndonTheme.green, prominent: true))
                        .keyboardShortcut("y", modifiers: .command)
                        .help("Leave plan mode; edits still ask, as before planning")

                    // The terminal's "auto-accept edits" option.
                    Button("Approve + accept edits") { onApprove(true) }
                        .buttonStyle(AndonButtonStyle(tint: AndonTheme.green))
                        .keyboardShortcut("y", modifiers: [.command, .shift])
                        .help("Leave plan mode and accept file edits without asking for the rest of the session")

                    Spacer(minLength: 0)
                    Text(shortcutHint)
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
