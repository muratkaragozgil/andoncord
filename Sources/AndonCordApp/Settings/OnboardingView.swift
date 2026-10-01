import AndonKit
import SwiftUI

/// First-run setup.
///
/// This screen asks permission to modify `~/.claude/settings.json`, so it says
/// plainly what will change and what the escape hatch is. A "zero config, just
/// works" flow that quietly edits a config file the user shares with other
/// tools is how you end up with an unexplainable broken setup later.
struct OnboardingView: View {
    let app: AppState
    let onFinish: () -> Void

    @State private var report: ClaudeSettingsInstaller.Report?
    @State private var failure: String?
    @State private var isWorking = false

    private var isInstalled: Bool {
        if case .installed = app.installStatus { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(AndonTheme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isInstalled {
                        successBody
                    } else {
                        explainer
                    }
                }
                .padding(20)
            }

            Divider().overlay(AndonTheme.hairline)
            footer
        }
        .background(AndonTheme.void)
        .frame(minWidth: 520, minHeight: 560)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(AndonTheme.amber)
                    .frame(width: 5, height: 22)
                RoundedRectangle(cornerRadius: 2).fill(AndonTheme.green)
                    .frame(width: 5, height: 15)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("AndonCord")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AndonTheme.textPrimary)
                Text("Claude Code, on your notch")
                    .font(AndonTheme.body(11))
                    .foregroundStyle(AndonTheme.textSecondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("When Claude Code needs you, pull the cord.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AndonTheme.textPrimary)

            VStack(alignment: .leading, spacing: 10) {
                bullet("Watch every session", "Running, waiting, done — one glance at the notch.")
                bullet("Answer without switching", "Approve tool calls, answer questions, review plans.")
                bullet("Jump to the right tab", "Click a session to land in its exact terminal pane.")
                bullet("See your limits", "5-hour and weekly quota, straight from Claude Code.")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What setup changes")
                    .font(AndonTheme.label(11))
                    .tracking(0.6)
                    .foregroundStyle(AndonTheme.textSecondary)

                changeRow(
                    "~/.claude/settings.json",
                    "Adds hook entries that notify this app, and points statusLine at a "
                        + "wrapper so quota can be read. Existing hooks are left alone, and "
                        + "any statusline you already have keeps running.")
                changeRow(
                    "~/.andoncord/",
                    "Holds the local socket, the hook launcher, and a timestamped backup "
                        + "of settings.json taken before every change.")

                Label(
                    "Nothing leaves your Mac. There is no account, no server, and no telemetry.",
                    systemImage: "lock.fill")
                    .font(AndonTheme.body(11))
                    .foregroundStyle(AndonTheme.textSecondary)
                    .padding(.top, 2)

                Label(
                    "You can undo all of this from Settings at any time.",
                    systemImage: "arrow.uturn.backward")
                    .font(AndonTheme.body(11))
                    .foregroundStyle(AndonTheme.textSecondary)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AndonTheme.surface)
            }

            if let failure {
                Text(failure)
                    .font(AndonTheme.body(11))
                    .foregroundStyle(AndonTheme.red)
            }
        }
    }

    private var successBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Claude Code is wired up", systemImage: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AndonTheme.green)

            Text("Open a new Claude Code session and it will appear on the board. "
                 + "Sessions already running need to be restarted before hooks apply.")
                .font(AndonTheme.body(12))
                .foregroundStyle(AndonTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let report {
                VStack(alignment: .leading, spacing: 7) {
                    if let backup = report.backupURL {
                        detailRow("Backup saved", backup.lastPathComponent)
                    }
                    if let displaced = report.displacedStatusline {
                        detailRow("Chained statusline", displaced)
                    }
                    if report.commentsWillBeLost {
                        Label(
                            "Your settings.json contained comments, which JSON rewriting "
                                + "removes. The backup above still has them.",
                            systemImage: "exclamationmark.triangle.fill")
                            .font(AndonTheme.body(11))
                            .foregroundStyle(AndonTheme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AndonTheme.surface)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !isInstalled {
                Button("Not now") { finish() }
                    .buttonStyle(AndonButtonStyle(tint: AndonTheme.textSecondary))
            }
            Spacer()
            if isInstalled {
                Button("Done") { finish() }
                    .buttonStyle(AndonButtonStyle(tint: AndonTheme.green, prominent: true))
            } else {
                Button(isWorking ? "Setting up…" : "Set up Claude Code") { install() }
                    .buttonStyle(AndonButtonStyle(tint: AndonTheme.accent, prominent: true))
                    .disabled(isWorking)
            }
        }
        .padding(16)
    }

    private func bullet(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(AndonTheme.accent)
                .frame(width: 3, height: 3)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AndonTheme.body(12, weight: .medium))
                    .foregroundStyle(AndonTheme.textPrimary)
                Text(detail)
                    .font(AndonTheme.body(11))
                    .foregroundStyle(AndonTheme.textSecondary)
            }
        }
    }

    private func changeRow(_ path: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(path)
                .font(AndonTheme.code(11))
                .foregroundStyle(AndonTheme.accent)
            Text(detail)
                .font(AndonTheme.body(11))
                .foregroundStyle(AndonTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(AndonTheme.label(10))
                .foregroundStyle(AndonTheme.textTertiary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(AndonTheme.code(10))
                .foregroundStyle(AndonTheme.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func install() {
        isWorking = true
        failure = nil
        switch app.installIntegration() {
        case .success(let result):
            report = result
        case .failure(let error):
            failure = error.localizedDescription
        }
        isWorking = false
    }

    private func finish() {
        app.settings.hasCompletedOnboarding = true
        onFinish()
    }
}
