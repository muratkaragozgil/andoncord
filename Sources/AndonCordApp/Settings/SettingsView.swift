import AndonKit
import AppKit
import SwiftUI

/// The settings window.
///
/// Laid out like macOS System Settings: a fixed header, then grouped cards each
/// under a small uppercase label, rows inside a card separated by inset
/// hairlines. The window uses a full-size content view, so the header owns the
/// title-bar strip (and leaves the top-left clear for the traffic lights)
/// rather than leaving an empty black band the way a plain titled window did.
struct SettingsView: View {
    let app: AppState

    @State private var confirmingRemoval = false
    @State private var lastBackup: URL?
    @State private var actionError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AndonTheme.hairline)
            ScrollView { groups }.scrollContentBackground(.hidden)
        }
        .background(AndonTheme.void)
        .frame(width: 480, height: 640)
        .onAppear { app.refreshInstallStatus() }
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: 22) {
            integrationGroup
            behaviourGroup
            soundGroup
            aboutGroup
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 26)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 11) {
            // The signal-tower wordmark, matching the panel and app icon.
            HStack(alignment: .bottom, spacing: 3.5) {
                RoundedRectangle(cornerRadius: 2).fill(AndonTheme.amber)
                    .frame(width: 5, height: 20)
                RoundedRectangle(cornerRadius: 2).fill(AndonTheme.green)
                    .frame(width: 5, height: 13)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("AndonCord")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AndonTheme.textPrimary)
                Text("Settings")
                    .font(AndonTheme.body(11))
                    .foregroundStyle(AndonTheme.textTertiary)
            }

            Spacer()

            Text("v\(Self.appVersion)")
                .font(AndonTheme.numeric(10))
                .foregroundStyle(AndonTheme.textTertiary)
        }
        .padding(.horizontal, 20)
        // The top inset keeps the wordmark clear of the traffic lights that
        // float over the full-size content view.
        .padding(.top, 26)
        .padding(.bottom, 14)
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }

    // MARK: - Claude Code

    private var integrationGroup: some View {
        SettingsGroup("Claude Code") {
            VStack(alignment: .leading, spacing: 0) {
                // Status row: a lamp, the state, and the primary action.
                HStack(spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: statusColor.opacity(0.7), radius: 3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle)
                            .font(AndonTheme.body(13, weight: .medium))
                            .foregroundStyle(AndonTheme.textPrimary)
                        if let sub = statusSubtitle {
                            Text(sub)
                                .font(AndonTheme.body(11))
                                .foregroundStyle(AndonTheme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 8)

                    if app.isIntegrationHealthy {
                        Button("Remove") { confirmingRemoval = true }
                            .buttonStyle(AndonButtonStyle(tint: AndonTheme.red))
                    } else {
                        Button("Set up") { install() }
                            .buttonStyle(AndonButtonStyle(tint: AndonTheme.accent, prominent: true))
                    }
                }
                .padding(14)

                if app.isIntegrationHealthy {
                    RowDivider()
                    HStack(spacing: 8) {
                        Button("Reinstall hooks") { install() }
                            .buttonStyle(AndonButtonStyle(tint: AndonTheme.textSecondary))
                        Button("Reveal backups") {
                            NSWorkspace.shared.selectFile(
                                lastBackup?.path, inFileViewerRootedAtPath: Paths.backups.path)
                        }
                        .buttonStyle(AndonButtonStyle(tint: AndonTheme.textSecondary))
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }

                if let actionError {
                    RowDivider()
                    Text(actionError)
                        .font(AndonTheme.body(11))
                        .foregroundStyle(AndonTheme.red)
                        .padding(14)
                }
            }
        } footer: {
            "Hooks are added alongside anything already in settings.json. Removing "
                + "restores the file exactly, including any statusline that was there before."
        }
        .alert("Remove AndonCord's hooks?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { remove() }
        } message: {
            Text("Claude Code will stop reporting to the board. Your settings.json is "
                 + "backed up first, and other tools' hooks are left untouched.")
        }
    }

    private var statusColor: Color {
        switch app.installStatus {
        case .installed: return app.serverError == nil ? AndonTheme.green : AndonTheme.amber
        case .notInstalled: return AndonTheme.inactive
        case .drifted: return AndonTheme.amber
        case .settingsUnreadable: return AndonTheme.red
        }
    }

    private var statusTitle: String {
        switch app.installStatus {
        case .installed: return app.serverError == nil ? "Connected" : "Hooks installed"
        case .notInstalled: return "Not set up"
        case .drifted: return "Needs repair"
        case .settingsUnreadable: return "Can't read settings.json"
        }
    }

    private var statusSubtitle: String? {
        if let serverError = app.serverError { return serverError }
        switch app.installStatus {
        case .installed: return "Claude Code is reporting to the board."
        case .notInstalled: return "Wire up hooks so sessions appear in the notch."
        case .drifted(let reason): return reason
        case .settingsUnreadable(let reason): return reason
        }
    }

    // MARK: - Behaviour

    private var behaviourGroup: some View {
        SettingsGroup("Behaviour") {
            VStack(spacing: 0) {
                displayRow
                RowDivider()
                ToggleRow(
                    "Open automatically when a cord is pulled",
                    detail: "Expands the panel the moment a session needs you.",
                    isOn: bind(\.autoExpandOnCord))
                RowDivider()
                ToggleRow(
                    "Hide when nothing is running",
                    detail: "Keeps the notch looking stock while you're not using Claude Code.",
                    isOn: bind(\.hideWhenIdle))
                RowDivider()
                ToggleRow(
                    "Show usage limits",
                    detail: "The 5-hour and weekly windows, read from the Claude desktop app's own record — or Claude Code's statusline — and carried forward by measured spend between readings.",
                    isOn: bind(\.showUsage))
                RowDivider()
                ToggleRow(
                    "Exact usage from Anthropic",
                    detail: exactUsageDetail,
                    isOn: Binding(
                        get: { app.settings.exactUsage },
                        set: {
                            app.settings.exactUsage = $0
                            app.applyExactUsage()
                        }))
                RowDivider()
                usageRow
                RowDivider()
                ToggleRow(
                    "Launch at login",
                    detail: nil,
                    isOn: bind(\.launchAtLogin))
            }
        }
    }

    /// What exact usage does, and — once it is on — whether it is working,
    /// since a source that has quietly stopped looks exactly like one that
    /// is fine.
    private var exactUsageDetail: String {
        let what = "Asks Anthropic every five minutes, signed in as Claude Code (its token is read from the Keychain). The only thing AndonCord sends off this Mac."
        guard app.settings.exactUsage else { return what }
        let usage = app.anthropicUsage
        if let problem = usage.problem {
            return what + " · " + Self.describe(problem)
        }
        guard let fetchedAt = usage.fetchedAt else { return what + " · Checking…" }
        let minutes = Int(Date().timeIntervalSince(fetchedAt) / 60)
        return what + " · Updated " + (minutes < 1 ? "just now" : "\(minutes)m ago")
    }

    private static func describe(_ problem: AnthropicUsageStore.Problem) -> String {
        switch problem {
        case .notSignedIn:
            return "Claude Code isn't signed in on this Mac — run claude once."
        case .missingScope:
            return "Claude Code's token can't read usage. Sign in with `claude` rather than `claude setup-token`."
        case .signInExpired:
            return "Claude Code's sign-in has expired and couldn't be renewed — run claude once."
        case .rateLimited(let until):
            let minutes = max(1, Int(until.timeIntervalSinceNow / 60))
            return "Anthropic asked to slow down; trying again in \(minutes)m."
        case .rejected(let status):
            return "Anthropic refused the request (HTTP \(status))."
        case .unreachable:
            return "Couldn't reach Anthropic."
        case .unreadableResponse:
            return "Anthropic's answer wasn't in a shape this build understands."
        }
    }

    /// The token breakdown, and an honest note about where its numbers come
    /// from — this is the one feature that reads files Claude Code wrote for
    /// its own purposes, so it says so rather than appearing to know things.
    private var usageRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Token usage")
                    .font(AndonTheme.body(13))
                    .foregroundStyle(AndonTheme.textPrimary)
                Text(usageDetail)
                    .font(AndonTheme.body(11))
                    .foregroundStyle(AndonTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Open") { app.openUsageWindow?() }
                .buttonStyle(AndonButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var usageDetail: String {
        if app.ledger.isIndexing { return "Indexing ~/.claude/projects…" }
        let sessions = app.ledger.sessions.count
        guard sessions > 0 else {
            return "Read locally from ~/.claude/projects. Nothing leaves this Mac."
        }
        let week = app.ledger.total(since: Date().addingTimeInterval(-7 * 24 * 3600))
        return "\(sessions) sessions indexed from ~/.claude/projects · "
            + "\(formatTokens(week.total)) this week. Nothing leaves this Mac."
    }

    /// Which display the board lives on.
    ///
    /// Listed live from `NSScreen.screens`, plus an Automatic default. If the
    /// chosen display is unplugged later, geometry falls back to automatic on
    /// its own — the stored name simply stops matching until it returns.
    private var displayRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Display")
                    .font(AndonTheme.body(13))
                    .foregroundStyle(AndonTheme.textPrimary)
                Text("Where the board appears. Automatic prefers the built-in notch.")
                    .font(AndonTheme.body(11))
                    .foregroundStyle(AndonTheme.textTertiary)
            }
            Spacer(minLength: 12)
            Picker("", selection: Binding(
                get: { app.settings.preferredDisplayName },
                set: { app.settings.preferredDisplayName = $0 })
            ) {
                Text("Automatic").tag(String?.none)
                ForEach(NSScreen.screens, id: \.localizedName) { screen in
                    let notch = screen.safeAreaInsets.top > 0 ? " (notch)" : ""
                    Text(screen.localizedName + notch).tag(String?.some(screen.localizedName))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 190)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Sound

    private var soundGroup: some View {
        SettingsGroup("Sound") {
            VStack(spacing: 0) {
                ToggleRow("Play sounds", detail: nil, isOn: bind(\.soundsEnabled))
                RowDivider()

                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(AndonTheme.textTertiary)
                    Slider(value: bind(\.volume), in: 0...1)
                        .controlSize(.small)
                        .tint(AndonTheme.accent)
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(AndonTheme.textTertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .opacity(app.settings.soundsEnabled ? 1 : 0.4)
                .disabled(!app.settings.soundsEnabled)

                RowDivider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview cues")
                        .font(AndonTheme.label(9))
                        .tracking(0.6)
                        .foregroundStyle(AndonTheme.textTertiary)
                    FlowRow(spacing: 6) {
                        ForEach(BoardSound.allCases, id: \.self) { sound in
                            Button(Self.soundLabel(sound)) { app.previewSound(sound) }
                                .buttonStyle(ChipButtonStyle())
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        } footer: {
            "Drop a .wav or .mp3 named after any event into ~/.andoncord/sounds to replace it."
        }
    }

    private static func soundLabel(_ sound: BoardSound) -> String {
        switch sound {
        case .sessionStart: return "Session start"
        case .cordPulled: return "Cord pulled"
        case .question: return "Question"
        case .planReview: return "Plan"
        case .cleared: return "Cleared"
        case .denied: return "Denied"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    // MARK: - About

    private var aboutGroup: some View {
        SettingsGroup("About") {
            VStack(alignment: .leading, spacing: 8) {
                Text("AndonCord watches Claude Code sessions and lets you answer them "
                     + "from the notch. Everything runs locally — no account, no server, "
                     + "no telemetry.")
                    .font(AndonTheme.body(12))
                    .foregroundStyle(AndonTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Named for the cord on a factory line that any worker can pull to "
                     + "stop production and ask for help.")
                    .font(AndonTheme.body(11))
                    .foregroundStyle(AndonTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    // MARK: - Helpers

    /// Two-way binding into `AndonSettings` by key path, so the rows stay terse.
    private func bind(_ keyPath: ReferenceWritableKeyPath<AndonSettings, Bool>) -> Binding<Bool> {
        Binding(get: { app.settings[keyPath: keyPath] },
                set: { app.settings[keyPath: keyPath] = $0 })
    }
    private func bind(_ keyPath: ReferenceWritableKeyPath<AndonSettings, Double>) -> Binding<Double> {
        Binding(get: { app.settings[keyPath: keyPath] },
                set: { app.settings[keyPath: keyPath] = $0 })
    }

    private func install() {
        actionError = nil
        switch app.installIntegration() {
        case .success(let report): lastBackup = report.backupURL
        case .failure(let error): actionError = error.localizedDescription
        }
    }

    private func remove() {
        actionError = nil
        switch app.removeIntegration() {
        case .success(let backup): lastBackup = backup
        case .failure(let error): actionError = error.localizedDescription
        }
    }
}

// MARK: - Building blocks

/// A labelled group: small uppercase caption, then a bordered card, then an
/// optional footnote — the macOS System Settings idiom.
private struct SettingsGroup<Content: View>: View {
    let title: String
    let footer: String?
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content, footer: () -> String) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        self.footer = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(AndonTheme.label(10))
                .tracking(1.1)
                .foregroundStyle(AndonTheme.textTertiary)
                .padding(.leading, 2)

            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(AndonTheme.surfaceRaised)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(AndonTheme.hairline, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            if let footer {
                Text(footer)
                    .font(AndonTheme.body(10))
                    .foregroundStyle(AndonTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
                    .padding(.top, 1)
            }
        }
    }
}

/// A toggle row: title (and optional detail) on the left, switch on the right.
private struct ToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String?, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AndonTheme.body(13))
                    .foregroundStyle(AndonTheme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(AndonTheme.body(11))
                        .foregroundStyle(AndonTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(AndonTheme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

/// A hairline that stops short of the leading edge, so rows read as a stack
/// rather than a table.
private struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(AndonTheme.hairline)
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

/// Small pill button for the sound previews.
private struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AndonTheme.body(11, weight: .medium))
            .foregroundStyle(AndonTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AndonTheme.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(AndonTheme.hairline, lineWidth: 1)
                    }
            }
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Wrapping horizontal stack.
///
/// `LazyVGrid` needs a fixed column count, which looks wrong for chips of
/// varying width; this places them left to right and wraps on overflow.
struct FlowRow<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: Content

    var body: some View {
        Layout(spacing: spacing) { content }
    }

    private struct Layout: SwiftUI.Layout {
        var spacing: CGFloat

        func sizeThatFits(
            proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
        ) -> CGSize {
            let maxWidth = proposal.width ?? .infinity
            var x: CGFloat = 0
            var rowHeight: CGFloat = 0
            var total: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x > 0, x + size.width > maxWidth {
                    total += rowHeight + spacing
                    x = 0
                    rowHeight = 0
                }
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
            return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: total + rowHeight)
        }

        func placeSubviews(
            in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
        ) {
            var x = bounds.minX
            var y = bounds.minY
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x > bounds.minX, x + size.width > bounds.maxX {
                    y += rowHeight + spacing
                    x = bounds.minX
                    rowHeight = 0
                }
                subview.place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
    }
}
