import AndonKit
import SwiftUI

/// A rectangle flush with the top screen edge, rounded only at the bottom.
///
/// The top corners are deliberately square: the panel starts at the physical
/// edge of the display, so rounding there would leave a visible sliver of
/// desktop above it and break the illusion that this is part of the hardware.
struct NotchShape: Shape {
    var cornerRadius: CGFloat

    /// Lets the radius interpolate during the expand animation, so the pill's
    /// tight corners open out into the panel's softer ones rather than
    /// snapping at the first frame.
    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - cornerRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Reports the laid-out content height back to the controller so the window
/// can size itself to whatever the board currently contains.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct NotchRootView: View {
    let controller: NotchController
    let app: AppState

    private var isExpanded: Bool { controller.presentation == .expanded }
    private var isHidden: Bool { controller.presentation == .hidden }
    private var isPill: Bool { controller.presentation == .pill }

    /// Height the panel wants, clamped so a long session list scrolls instead
    /// of running off the bottom of the screen.
    private var expandedHeight: CGFloat {
        min(max(controller.measuredContentHeight, AndonTheme.Metrics.panelMinHeight),
            AndonTheme.Metrics.panelMaxHeight)
    }

    private var targetSize: CGSize {
        if isHidden { return .zero }
        return isExpanded
            ? CGSize(width: AndonTheme.Metrics.panelWidth, height: expandedHeight)
            : CGSize(width: controller.pillWidth, height: AndonTheme.Metrics.pillHeight)
    }

    private var cornerRadius: CGFloat {
        isExpanded ? AndonTheme.Metrics.panelCornerRadius
                   : AndonTheme.Metrics.notchCornerRadius
    }

    var body: some View {
        VStack(spacing: 0) {
            // One container that grows, rather than two views swapping places.
            //
            // The window itself is fixed (see `NotchPanel`), so the sense of
            // the panel physically dropping out of the notch has to come from
            // here: a single shape whose size and corner radius interpolate
            // while the two layers cross-fade inside it.
            ZStack(alignment: .top) {
                // Always laid out, even while collapsed, so its natural height
                // is known before the expansion starts. Measuring only on the
                // way in would mean animating to a height we do not have yet,
                // which is what produces a snap on the first open.
                ExpandedPanelView(controller: controller, app: app)
                    .frame(width: AndonTheme.Metrics.panelWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ContentHeightKey.self, value: proxy.size.height)
                        }
                    }
                    .opacity(isExpanded ? 1 : 0)
                    .allowsHitTesting(isExpanded)
                    // Laid out continuously by design (above), so it has to be
                    // told when it is merely measured rather than seen.
                    .environment(\.andonIsVisible, isExpanded)

                CollapsedPillView(controller: controller, app: app)
                    .frame(width: controller.pillWidth,
                           height: AndonTheme.Metrics.pillHeight)
                    .opacity(isExpanded ? 0 : 1)
                    .allowsHitTesting(!isExpanded)
                    .environment(\.andonIsVisible, isPill)
            }
            .frame(width: targetSize.width, height: targetSize.height, alignment: .top)
            .background {
                NotchShape(cornerRadius: cornerRadius).fill(AndonTheme.void)
            }
            // Clipping is what turns the frame change into a reveal: the panel
            // is already drawn at full size underneath and is uncovered as the
            // container grows.
            .clipShape(NotchShape(cornerRadius: cornerRadius))
            .overlay {
                NotchShape(cornerRadius: cornerRadius)
                    .stroke(AndonTheme.hairline, lineWidth: isExpanded ? 1 : 0)
            }
            .shadow(color: .black.opacity(isExpanded ? 0.5 : 0), radius: 24, y: 10)
            .opacity(isHidden ? 0 : 1)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(ContentHeightKey.self) { height in
            Task { @MainActor in controller.measuredContentHeight = height }
        }
        .animation(AndonTheme.Motion.expand, value: controller.presentation)
        // Content growing while already open (a new session row, a permission
        // card arriving) should ease too, not jump.
        .animation(AndonTheme.Motion.expand, value: expandedHeight)
    }
}

/// The collapsed strip that hugs the notch.
struct CollapsedPillView: View {
    let controller: NotchController
    let app: AppState

    /// A live clock. Without it the elapsed readout is computed once at render
    /// and then frozen — which is what made a running session show a motionless
    /// "0s" and look dead. Ticking numbers are the plainest proof of life on
    /// the whole pill, so this drives a re-render every second.
    @State private var now = Date()
    private static let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The pill is cross-faded out while the panel is open, and the whole
    /// window is ordered out while hidden; neither is a moment to keep a clock
    /// running.
    @Environment(\.andonIsVisible) private var isVisible

    private var focus: Session? { app.board.focusSession }
    private var waitingCount: Int { app.board.sessionsNeedingHuman.count }

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)

            // Leave the physical cutout empty so nothing renders under the
            // camera housing.
            if controller.hasNotch {
                Spacer(minLength: controller.notchWidth)
                    .frame(width: controller.notchWidth)
            }

            trailing
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, AndonTheme.Metrics.horizontalPadding)
        .frame(maxWidth: .infinity)
        .frame(height: AndonTheme.Metrics.pillHeight)
        .contentShape(Rectangle())
        .onTapGesture { controller.toggleExpanded() }
        // Tick only while the pill is on screen and something is actively
        // running, so an idle or cross-faded-out pill is not waking the machine
        // once a second for no reason.
        .onReceive(Self.ticker) { if isVisible, focus?.state.isActive == true { now = $0 } }
    }

    @ViewBuilder
    private var leading: some View {
        if let focus {
            HStack(spacing: 7) {
                AndonLamp(state: focus.state)
                Text(focus.title)
                    .font(AndonTheme.body(11, weight: .medium))
                    .foregroundStyle(AndonTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            // Empty board. The pill stays up and says so, in andon colours:
            // a red lamp means the line is stopped — which is exactly the
            // state "no sessions at all" is. A pill that vanished here left
            // no way to tell "idle" from "broken".
            HStack(spacing: 7) {
                DotLamp(color: AndonTheme.red, size: 8)
                Text("Idle")
                    .font(AndonTheme.body(11, weight: .medium))
                    .foregroundStyle(AndonTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 8) {
            if waitingCount > 0 {
                AndonChip(text: waitingCount == 1 ? "cord" : "\(waitingCount) cords",
                          color: AndonTheme.amber, filled: true)
            } else if let focus, focus.state.isActive {
                // Recomputed against `now` (not Date()) so the ticker is what
                // drives it — the number visibly counts up.
                let elapsed = now.timeIntervalSince(focus.turnStartedAt ?? focus.startedAt)
                Text(formatElapsed(elapsed))
                    .font(AndonTheme.numeric(10))
                    .foregroundStyle(AndonTheme.green)
                    .monospacedDigit()
            }

            // Whichever window is closest to stopping you, on the one surface
            // that is always visible. An expired reading is not frozen on
            // screen, and a figure this app estimated is dimmed so it cannot
            // pass for one Claude Code stated.
            //
            // The number is spelled out next to the bar rather than left to
            // the bar alone: five segments can separate "fine" from "nearly
            // out", but not 40% from 55% — and that is the range where you
            // actually decide whether to start the next thing.
            if app.settings.showUsage, let binding = app.bindingQuota(now: now) {
                HStack(spacing: 5) {
                    Text(binding.kind.shortLabel)
                        .font(AndonTheme.label(8.5))
                        .tracking(0.5)
                        .foregroundStyle(AndonTheme.textTertiary)
                    AndonMeter(
                        fraction: binding.fraction,
                        segments: 5,
                        color: pillMeterColor(binding),
                        segmentWidth: 4, height: 6)
                    Text("\(binding.isEstimate ? "~" : "")\(Int((binding.usedPercentage ?? 0).rounded()))%")
                        .font(AndonTheme.numeric(10, weight: .semibold))
                        .foregroundStyle(pillMeterColor(binding))
                        .monospacedDigit()
                }
                .opacity(binding.isMeasured ? 1 : 0.6)
                .help(pillQuotaHelp(binding))
            }
        }
    }

    private func pillQuotaHelp(_ binding: QuotaReadout) -> String {
        var parts = ["\(binding.kind.longLabel) window · \(binding.provenance)"]
        if let countdown = binding.resetCountdown { parts.append("resets in \(countdown)") }
        if let summary = binding.forecast.summary(windowLabel: binding.kind.longLabel) {
            parts.append(summary)
        }
        return parts.joined(separator: " · ")
    }

    /// The projection outranks the bar. A window at 25% that is on pace to
    /// blow past the cap should not read as green on the one strip that is
    /// always on screen.
    private func pillMeterColor(_ binding: QuotaReadout) -> Color {
        switch binding.forecast.verdict {
        case .exhausts: return AndonTheme.red
        case .tight: return AndonTheme.amber
        case .holds, .unknown: return meterColor(binding.severity)
        }
    }

    private func meterColor(_ severity: RateLimitWindow.Severity) -> Color {
        switch severity {
        case .nominal: return AndonTheme.green
        case .caution: return AndonTheme.amber
        case .critical: return AndonTheme.red
        }
    }
}
