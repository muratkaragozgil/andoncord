import AndonKit
import AppKit
import Observation
import SwiftUI

/// Owns the panel and decides how much of the board to show.
///
/// The presentation rule is the product in miniature: stay out of the way
/// until something needs a person, then be unmissable.
///
/// The window itself never moves or resizes while the board is up — see
/// `NotchPanel` for why that matters. This type's job is therefore to decide
/// *what* is drawn and to keep the panel's interactive region in sync with it,
/// not to push windows around.
@Observable
@MainActor
final class NotchController {
    enum Presentation: Equatable {
        /// Nothing running; the notch looks stock.
        case hidden
        /// Collapsed strip hugging the notch.
        case pill
        /// Full board.
        case expanded
    }

    private(set) var presentation: Presentation = .hidden

    /// Pointer is over the drawn content.
    ///
    /// Set from the content's own hover region rather than the window's
    /// bounds, which is what keeps it stable while the panel animates.
    var isHovering = false {
        didSet {
            guard isHovering != oldValue else { return }
            if isHovering {
                pendingCollapse?.cancel()
                pendingCollapse = nil
                updatePresentation()
            } else {
                scheduleCollapse()
            }
        }
    }

    /// Clicked open, which keeps it open after the pointer leaves.
    private(set) var isPinnedOpen = false

    /// Reported by the SwiftUI layout. Drives the interactive region only —
    /// deliberately *not* the window frame, since resizing on measurement is
    /// how the layout/resize feedback loop got started in the first place.
    var measuredContentHeight: CGFloat = 0 {
        didSet {
            guard abs(measuredContentHeight - oldValue) > 0.5 else { return }
            syncInteractiveRegion()
        }
    }

    @ObservationIgnored private weak var app: AppState?
    @ObservationIgnored private var panel: NotchPanel?
    @ObservationIgnored private var hostingView: NotchHostingView<NotchRootView>?
    @ObservationIgnored private var geometry: NotchGeometry?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingCollapse: Task<Void, Never>?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    /// A fullscreen app covers the board's display.
    @ObservationIgnored private var isOverFullscreen = false
    /// A shortcut asked for the board while a fullscreen app was hiding it.
    /// Holds until the board is put away again.
    @ObservationIgnored private var revealedOverFullscreen = false
    /// Opened by a shortcut press rather than a click, so it closes again
    /// once the shortcut has done what it came for.
    @ObservationIgnored private var openedByShortcut = false
    /// Leaving fullscreen does not always announce itself, so while the
    /// board is hidden for it, it looks again every second and a half.
    @ObservationIgnored private var fullscreenPoller: Timer?

    /// Grace period before collapsing after the pointer leaves.
    ///
    /// Crossing between the pill and the panel, or over a subview boundary,
    /// can momentarily report "not hovering". Without this the panel snaps
    /// shut and immediately reopens.
    private static let collapseGrace = Duration.milliseconds(220)

    func attach(to app: AppState) {
        self.app = app
        rebuildGeometry()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Docking, undocking, or a resolution change moves the notch.
            MainActor.assumeIsolated { self?.rebuildGeometry() }
        }

        // A Space change is how entering or leaving fullscreen shows up; an
        // app activation can also change whose session is in front.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(workspace.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshFullscreen()
                    self?.updatePresentation()
                }
            })
        }

        observeBoard()
        refreshFullscreen()
        updatePresentation()
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    /// Re-run whenever the observable board changes.
    ///
    /// `withObservationTracking` fires once per change, so it re-arms itself
    /// after every callback.
    private func observeBoard() {
        guard let app else { return }
        withObservationTracking {
            _ = app.board.orderedSessions.map(\.state)
            _ = app.settings.hideWhenIdle
            _ = app.settings.autoExpandOnCord
            _ = app.settings.preferredDisplayName
        } onChange: { [weak self] in
            Task { @MainActor in
                // Cheap even when only board state changed: positionWindow
                // no-ops unless the target frame actually differs.
                self?.rebuildGeometry()
                self?.updatePresentation()
                self?.observeBoard()
            }
        }
    }

    // MARK: - Presentation

    /// `revealing`: a shortcut asked, so a fullscreen app does not keep the
    /// board hidden.
    func toggleExpanded(revealing: Bool = false) {
        if revealing, isOverFullscreen, !revealedOverFullscreen {
            reveal()
            return
        }
        isPinnedOpen.toggle()
        if !isPinnedOpen {
            revealedOverFullscreen = false
            openedByShortcut = false
        }
        pendingCollapse?.cancel()
        pendingCollapse = nil
        updatePresentation()
    }

    func collapse() {
        isPinnedOpen = false
        revealedOverFullscreen = false
        openedByShortcut = false
        updatePresentation()
    }

    /// Bring the board up for a shortcut, over a fullscreen app if need be.
    func reveal() {
        revealedOverFullscreen = isOverFullscreen
        if !isPinnedOpen { openedByShortcut = true }
        isPinnedOpen = true
        pendingCollapse?.cancel()
        pendingCollapse = nil
        updatePresentation()
    }

    /// A shortcut settled the card. If a shortcut is also what opened the
    /// board, it goes away again — the person never reached for the mouse,
    /// and should not have to now.
    func shortcutActed() {
        guard openedByShortcut else { return }
        collapse()
    }

    /// Whether the request card is on screen to be acted on.
    var isShowingCard: Bool {
        presentation == .expanded && app?.board.sessionsNeedingHuman.first?.pending != nil
    }

    // MARK: - Fullscreen

    private func refreshFullscreen() {
        let covered = (app?.settings.hideInFullscreen ?? false) && frontAppFillsBoardScreen()
        if covered != isOverFullscreen {
            isOverFullscreen = covered
            if !covered { revealedOverFullscreen = false }
        }
        if covered, fullscreenPoller == nil {
            fullscreenPoller = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshFullscreen()
                    self?.updatePresentation()
                }
            }
        } else if !covered {
            fullscreenPoller?.invalidate()
            fullscreenPoller = nil
        }
    }

    /// Window bounds and owners need no Screen Recording permission; only
    /// titles do, and they are not read.
    private func frontAppFillsBoardScreen() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let screen = (geometry ?? currentGeometry())?.screen,
              let primaryMaxY = NSScreen.screens.first?.frame.maxY,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let bounds = windows.compactMap { window -> CGRect? in
            guard window[kCGWindowOwnerPID as String] as? pid_t == front.processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary
            else { return nil }
            return CGRect(dictionaryRepresentation: dictionary)
        }
        return ScreenCover.isCovered(
            screen: screen.frame, byWindows: bounds, primaryScreenMaxY: primaryMaxY)
    }

    private func scheduleCollapse() {
        pendingCollapse?.cancel()
        pendingCollapse = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.collapseGrace)
            guard !Task.isCancelled, let self else { return }
            self.pendingCollapse = nil
            self.updatePresentation()
        }
    }

    private func updatePresentation() {
        guard let app else { return }
        let board = app.board
        let waiting = board.sessionsNeedingHuman
        let needsHuman = !waiting.isEmpty
        // Every waiting session's own app is in front, so the same prompt is
        // already on screen there; popping open on top of it is noise. The
        // pill still blinks.
        let promptAlreadyInView = app.settings.quietWhenSessionInFront && needsHuman
            && waiting.allSatisfy { app.isAppInFront(for: $0) }

        let next: Presentation
        if isOverFullscreen && !revealedOverFullscreen {
            next = .hidden
        } else if board.sessions.isEmpty && app.settings.hideWhenIdle && !isPinnedOpen {
            next = .hidden
        } else if isPinnedOpen || isHovering
                    || (needsHuman && app.settings.autoExpandOnCord && !promptAlreadyInView) {
            next = .expanded
        } else {
            next = .pill
        }

        guard next != presentation else {
            // Content can change height without changing presentation.
            syncInteractiveRegion()
            return
        }
        presentation = next
        Log.debugFile("presentation -> \(next) (hover=\(isHovering) pinned=\(isPinnedOpen))")
        applyPresentation()
    }

    private func applyPresentation() {
        switch presentation {
        case .hidden:
            panel?.acceptsKey = false
            panel?.orderOut(nil)
        case .pill:
            panel?.acceptsKey = false
            showPanel()
        case .expanded:
            // Able to take keystrokes while open — the card's answer box and
            // a reply both need them. A non-activating panel only becomes key
            // when clicked into, so this never takes a keypress meant for the
            // app in front; the system-wide shortcuts are what work without
            // a click.
            panel?.acceptsKey = true
            showPanel()
        }
        syncInteractiveRegion()
    }

    // MARK: - Window

    private func rebuildGeometry() {
        geometry = currentGeometry()
        positionWindow()
    }

    /// Geometry resolution always goes through the user's display preference.
    private func currentGeometry() -> NotchGeometry? {
        NotchGeometry.current(preferredDisplayName: app?.settings.preferredDisplayName)
    }

    private func showPanel() {
        let panel = ensurePanel()
        guard !panel.isVisible else { return }
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> NotchPanel {
        if let panel { return panel }

        let panel = NotchPanel(contentRect: NSRect(origin: .zero, size: NotchPanel.fixedSize))
        let host = NotchHostingView(rootView: NotchRootView(controller: self, app: appOrEmpty))
        host.autoresizingMask = [.width, .height]
        // Hover comes from the hosting view's tracking area rather than
        // SwiftUI, so it works while another app is frontmost.
        host.onHoverChange = { [weak self] hovering in
            MainActor.assumeIsolated { self?.isHovering = hovering }
        }
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        panel.contentView = host

        self.panel = panel
        self.hostingView = host
        positionWindow()
        return panel
    }

    /// Non-optional accessor for view construction; the panel is only ever
    /// built after `attach`.
    private var appOrEmpty: AppState {
        guard let app else {
            assertionFailure("NotchController used before attach(to:)")
            return AppState()
        }
        return app
    }

    /// Place the fixed-size window at the top centre of the active screen.
    /// Called on creation and on display changes only — never on hover.
    private func positionWindow() {
        guard let panel, let geo = geometry ?? currentGeometry() else { return }
        let size = NotchPanel.fixedSize
        let frame = geo.frame(width: size.width, height: size.height)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        syncInteractiveRegion()
    }

    /// Tell the hosting view which part of itself is real, so clicks outside
    /// the drawn content pass through to whatever is behind.
    private func syncInteractiveRegion() {
        guard let hostingView, let geo = geometry ?? currentGeometry() else { return }
        let bounds = hostingView.bounds

        let contentSize: CGSize
        switch presentation {
        case .hidden:
            contentSize = .zero
        case .pill:
            contentSize = CGSize(
                width: geo.pillWidth(shoulder: AndonTheme.Metrics.pillShoulder),
                height: AndonTheme.Metrics.pillHeight)
        case .expanded:
            let height = min(
                max(measuredContentHeight, AndonTheme.Metrics.panelMinHeight),
                AndonTheme.Metrics.panelMaxHeight)
            contentSize = CGSize(width: AndonTheme.Metrics.panelWidth, height: height)
        }

        guard contentSize != .zero else {
            hostingView.interactiveRect = .zero
            return
        }

        // Content is drawn top-anchored and horizontally centred. `NSHostingView`
        // is flipped (SwiftUI's top-left origin), so "top" is y == 0 there —
        // but read the flag rather than hardcoding it, because getting this
        // backwards silently puts the clickable region off the bottom of the
        // panel and hover stops working entirely.
        let originY = hostingView.isFlipped ? 0 : bounds.height - contentSize.height
        hostingView.interactiveRect = CGRect(
            x: (bounds.width - contentSize.width) / 2,
            y: originY,
            width: contentSize.width,
            height: contentSize.height)
    }

    // MARK: - Geometry exposed to views

    var notchWidth: CGFloat { geometry?.notchWidth ?? 0 }
    var hasNotch: Bool { geometry?.hasNotch ?? false }

    /// Width of the collapsed pill.
    ///
    /// The pill must be given an explicit width now that the window is fixed
    /// and much wider than it — otherwise it would stretch to fill the window
    /// and its hover region would cover the whole top of the screen.
    var pillWidth: CGFloat {
        (geometry ?? currentGeometry())?
            .pillWidth(shoulder: AndonTheme.Metrics.pillShoulder)
            ?? AndonTheme.Metrics.pillShoulder * 2
    }
}
