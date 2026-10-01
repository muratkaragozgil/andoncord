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
    @Environment(\.andonIsVisible) private var isVisible

    private static let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
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
        .padding(.horizontal, AndonTheme.Metrics.horizontalPadding)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering && canJump
                    ? AndonTheme.surfaceRaised.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if canJump { jump() } }
        // The panel is laid out even while collapsed, so without this every row
        // re-renders once a second behind a fully transparent container.
        .onReceive(Self.ticker) { if isVisible { now = $0 } }
        .help(session.cwd ?? "")
    }

    /// The most informative line available, in descending order of usefulness.
    private var statusLine: String {
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
            let result = await TerminalJumper.jump(to: terminal)
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
