import AndonKit
import SwiftUI

/// One station on the board.
///
/// Click jumps to the terminal it is running in — that is the row's primary
/// job, so the whole row is the hit target rather than a small button.
struct SessionRowView: View {
    let session: Session
    let app: AppState

    @State private var isHovering = false
    @State private var jumpFailure: String?
    /// Drives the elapsed-time readout without a timer per row.
    @State private var now = Date()
    /// Kept on the row so a half-typed reply survives the pointer leaving.
    @State private var reply = ""
    @Environment(\.andonIsVisible) private var isVisible

    private static let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            station
                .contentShape(Rectangle())
                .onTapGesture { if canJump { jump() } }

            if let url = signInURL {
                Link("Open the sign-in page", destination: url)
                    .font(AndonTheme.body(10, weight: .medium))
                    .foregroundStyle(AndonTheme.accent)
                    .padding(.leading, 17)
            }

            // Outside the tap target: typing a reply must not also jump.
            if canReply, isHovering || !reply.isEmpty {
                ReplyField(session: session, text: $reply)
                    .padding(.leading, 17)
            }
        }
        .padding(.horizontal, AndonTheme.Metrics.horizontalPadding)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering && canJump
                    ? AndonTheme.surfaceRaised.opacity(0.6) : .clear)
        .onHover { isHovering = $0 }
        // The panel is laid out even while collapsed, so without this every row
        // re-renders once a second behind a fully transparent container.
        .onReceive(Self.ticker) { if isVisible { now = $0 } }
        .help(session.cwd ?? "")
    }

    private var station: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 9) {
                AndonLamp(state: session.state)

                Text(session.title)
                    .font(AndonTheme.body(12, weight: .medium))
                    .foregroundStyle(AndonTheme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if let terminal = session.terminal, terminal.kind != .unknown {
                    Text(terminal.displayName)
                        .font(AndonTheme.label(9))
                        .foregroundStyle(AndonTheme.textTertiary)
                }

                Text(formatElapsed(session.elapsed))
                    .font(AndonTheme.numeric(10))
                    .foregroundStyle(AndonTheme.textTertiary)
                    .monospacedDigit()
            }

            HStack(spacing: 6) {
                Text(statusLine)
                    .font(AndonTheme.body(11))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)

                if !session.activeSubagents.isEmpty {
                    AndonChip(
                        text: "\(session.activeSubagents.count) subagent",
                        color: AndonTheme.textTertiary)
                }

                if let effort = session.effortLevel, !effort.isEmpty {
                    AndonChip(text: effort, color: AndonTheme.textTertiary)
                        .help("The model's effort setting for this session")
                }

                Spacer(minLength: 0)

                if isHovering, canJump {
                    Text(session.terminal?.kind.supportsPreciseJump == true
                         ? "Click to jump" : "Click to raise")
                        .font(AndonTheme.label(9))
                        .foregroundStyle(AndonTheme.textTertiary)
                }
            }
            .padding(.leading, 17)

            if let jumpFailure {
                Text(jumpFailure)
                    .font(AndonTheme.body(10))
                    .foregroundStyle(AndonTheme.amber)
                    .padding(.leading, 17)
            }
        }
    }

    /// A reply can be typed into the session when it is waiting for one and
    /// its terminal can be typed into from outside.
    private var canReply: Bool {
        switch session.state {
        case .done, .idle:
            return session.terminal.map(TerminalJumper.canSendText(to:)) ?? false
        default:
            return false
        }
    }

    /// An MCP server's sign-in page, offered as a link — https only.
    private var signInURL: URL? {
        guard let text = session.elicitation?.url, let url = URL(string: text),
              url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    /// The most informative line available, in descending order of usefulness.
    private var statusLine: String {
        if let notice = session.elicitation, session.pending == nil {
            return notice.message.isEmpty
                ? "\(notice.server) needs your input in Claude"
                : "\(notice.server): \(notice.message)"
        }
        if let pending = session.pending {
            let tool = ToolPresentation.make(
                toolName: pending.toolName, input: pending.toolInput)
            switch pending.kind {
            case .permission: return "Waiting on you — \(tool.activityLine)"
            case .question: return "Waiting on your answer"
            case .plan: return "Plan ready for review"
            }
        }
        switch session.state {
        case .working(let tool):
            return session.recentActivity.last?.summary ?? tool
        case .done:
            return session.lastAssistantMessage.map(firstLine) ?? "Done"
        case .failed(let reason):
            return reason
        case .running:
            return session.recentActivity.last?.summary ?? "Thinking…"
        case .idle:
            return session.projectName ?? "Idle"
        case .cordPulled(.attention):
            return "Needs your attention"
        case .cordPulled, .ended:
            return session.state.label
        }
    }

    private var statusColor: Color {
        switch session.state {
        case .cordPulled: return AndonTheme.amber
        case .failed: return AndonTheme.red
        default: return AndonTheme.textSecondary
        }
    }

    private func firstLine(_ text: String) -> String {
        let line = text.components(separatedBy: "\n").first ?? text
        return line.count > 64 ? String(line.prefix(63)) + "…" : line
    }

    /// Whether there is any app to raise.
    ///
    /// A session started somewhere with no identifiable host — a cron job, a
    /// detached process — has nothing to jump to, so the row must not present
    /// itself as clickable and then fail.
    private var canJump: Bool {
        session.terminal?.activationBundleIdentifier != nil
    }

    private func jump() {
        guard let terminal = session.terminal else { return }
        jumpFailure = nil
        Task {
            let result = await TerminalJumper.jump(to: terminal, workingDirectory: session.cwd)
            await MainActor.run {
                switch result {
                case .precise, .appActivated:
                    jumpFailure = nil
                case .failed(let reason):
                    jumpFailure = reason
                }
            }
        }
    }
}

/// Send a session its next prompt without going to its terminal.
///
/// Typed into the session's own tab — tmux pane, iTerm2 session, Ghostty
/// terminal — and sent with Return, exactly as if the person had gone
/// there. Offered only for sessions waiting for a prompt, so it can never
/// type into the middle of a turn.
private struct ReplyField: View {
    let session: Session
    @Binding var text: String

    @State private var sending = false
    @State private var outcome: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                TextField("Reply to Claude…", text: $text)
                    .textFieldStyle(.plain)
                    .font(AndonTheme.body(11))
                    .foregroundStyle(AndonTheme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AndonTheme.surface)
                    }
                    .onSubmit(send)

                Button("Send", action: send)
                    .buttonStyle(AndonButtonStyle(tint: AndonTheme.accent, prominent: true))
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let outcome {
                Text(outcome)
                    .font(AndonTheme.body(10))
                    .foregroundStyle(AndonTheme.textTertiary)
            }
        }
    }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !sending, let terminal = session.terminal else { return }
        sending = true
        outcome = nil
        Task {
            let result = await TerminalJumper.send(
                message, to: terminal, workingDirectory: session.cwd)
            await MainActor.run {
                sending = false
                switch result {
                case .precise, .appActivated:
                    text = ""
                    outcome = "Sent to \(terminal.displayName)"
                case .failed(let reason):
                    outcome = reason
                }
            }
        }
    }
}
