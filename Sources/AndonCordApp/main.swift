import AndonKit
import AppKit

/// Entry point.
///
/// Hand-rolled rather than `@main struct App` because the board lives in a
/// borderless `NSPanel` positioned against the physical screen edge, which the
/// SwiftUI scene system does not model. An `NSApplicationDelegate` gives
/// direct control over window level, activation policy, and lifecycle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private let notch = NotchController()
    private var menuBar: MenuBarController?
    private var shortcuts: BoardShortcuts?

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.start()

        notch.attach(to: state)

        let shortcuts = BoardShortcuts(app: state, notch: notch)
        state.applyShortcuts = { [weak shortcuts] in shortcuts?.apply() }
        shortcuts.apply()
        self.shortcuts = shortcuts

        let menuBar = MenuBarController(app: state, controller: notch)
        menuBar.install()
        self.menuBar = menuBar

        if let pid = state.duplicateInstancePID {
            presentDuplicateInstanceAlert(pid: pid)
            return
        }

        // Show setup on first run, and again if the hooks were removed from
        // under us — an app that silently does nothing is worse than one that
        // asks.
        if !state.settings.hasCompletedOnboarding {
            menuBar.showOnboarding()
        }

        // `open -a AndonCord --args --usage`. There is no Dock icon and no app
        // menu, so without this the breakdown is only reachable by aiming at a
        // menu bar glyph — which is a poor fit for something worth putting on
        // a keyboard shortcut.
        //
        // Deferred a turn: opening a window from inside
        // `applicationDidFinishLaunching` races the activation that is meant
        // to bring it forward, and loses quietly — the window exists but is
        // never ordered onto the screen.
        if CommandLine.arguments.contains("--usage") {
            DispatchQueue.main.async { [weak menuBar] in menuBar?.showUsage() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcuts?.unregisterAll()
        state.stop()
    }

    /// The board keeps running with no windows open, which is the point.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func presentDuplicateInstanceAlert(pid: pid_t) {
        let alert = NSAlert()
        alert.messageText = "AndonCord is already running"
        alert.informativeText =
            "Another copy (pid \(pid)) already owns the local socket. "
            + "Quit that one first, or use the copy already in your menu bar."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit This Copy")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

// Top-level code in main.swift runs on the main thread, but the compiler
// treats it as nonisolated, so the main-actor setup is made explicit here.
let application = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
// Accessory: menu bar and panels only, no Dock icon and no app menu.
application.setActivationPolicy(.accessory)
application.run()
