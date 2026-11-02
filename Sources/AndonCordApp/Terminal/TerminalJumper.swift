import AndonKit
import AppKit
import CoreServices
import Foundation
import os

/// Brings the terminal tab/pane that owns a session back to the front.
///
/// ## Threading
///
/// Every strategy here ends in either an Apple event or a subprocess, and both
/// can wedge for an unbounded time — a modal sheet in the target app, a stopped
/// `tmux` server, a `kitty` socket nobody is listening on. The notch UI calls
/// this from a click handler, so a blocking variant would be a freeze waiting
/// to happen.
///
/// Consequently there is **no synchronous `jump`**. The primary entry point is
/// ``jump(to:)``, which is `async` and hops to a private utility queue; AppKit
/// action methods that cannot `await` use ``jumpInBackground(to:completion:)``,
/// which is fire-and-forget and delivers its result back on the main queue.
///
/// Every external call is additionally bounded by a hard ``commandTimeout``, so
/// even the async path cannot hang a task forever.
///
/// ## Why `osascript` instead of `NSAppleScript`
///
/// `NSAppleScript` offers no way to cancel an in-flight event; if the target
/// app stops answering, the calling thread is gone until it recovers. A
/// subprocess can be killed, so the timeout is actually enforceable.
public enum TerminalJumper {

    /// What a jump actually accomplished. Deliberately does not conflate
    /// "raised the app" with "landed on the tab" — the UI tells the user which
    /// one happened rather than implying a precision we did not achieve.
    public enum JumpResult: Sendable, Equatable {
        /// Landed on the exact tab/pane.
        case precise
        /// Raised the application, but could not address the specific tab.
        case appActivated
        /// Nothing happened. The payload is a short human-readable reason.
        case failed(String)
    }

    /// Whether AppleScript automation permission has been granted for a target
    /// app.
    ///
    /// The UI consults this after a ``JumpResult/appActivated`` from a terminal
    /// whose `supportsPreciseJump` is `true`: that combination almost always
    /// means the Apple event was refused, and the user needs to visit System
    /// Settings → Privacy & Security → Automation.
    public enum PermissionState: Sendable {
        case granted
        /// Explicitly refused. Only the user can undo this, in System Settings.
        case denied
        /// Never asked. The next AppleScript call raises the system prompt.
        case notDetermined
        /// This terminal is not driven via Apple events at all.
        case notApplicable
    }

    /// Hard ceiling on any single Apple event or subprocess.
    ///
    /// Applied per call, not per jump: the tmux path issues two `tmux`
    /// invocations plus an activation and can therefore take longer in the
    /// pathological case. Three seconds is far beyond a healthy round trip
    /// (single-digit milliseconds) while staying under the threshold where a
    /// user assumes the click was dropped.
    private static let commandTimeout: TimeInterval = 3

    /// Serial so two rapid clicks cannot interleave Apple events into the same
    /// app, which produces "select the wrong tab, then the right one" flicker.
    private static let queue = DispatchQueue(
        label: "app.andoncord.jump", qos: .userInitiated
    )

    // MARK: - Public API

    /// Focus the exact tab/pane for this session.
    ///
    /// Runs entirely off the main thread; the caller's task suspends rather
    /// than blocks.
    /// - Parameter workingDirectory: the session's directory. Ghostty
    ///   terminals have no tty, so it is how one is found.
    @discardableResult
    public static func jump(
        to context: TerminalContext, workingDirectory: String? = nil
    ) async -> JumpResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: performJump(context, workingDirectory: workingDirectory))
            }
        }
    }

    // MARK: - Replying

    /// Whether `send(_:to:workingDirectory:)` can reach this session: a tmux
    /// pane, an iTerm2 session, or a Ghostty terminal.
    public static func canSendText(to context: TerminalContext) -> Bool {
        if context.isInsideTmux, context.tmuxPane.map(isPlausibleIdentifier) == true { return true }
        switch context.kind {
        case .iTerm2: return context.ttyPath?.isEmpty == false
        case .ghostty: return true
        default: return false
        }
    }

    /// Type a reply into the session's terminal and press Return — what the
    /// person would have done had they gone there.
    ///
    /// The text goes in literally and Return separately: a newline carried
    /// inside the text arrives as a line feed, which Claude Code's prompt
    /// takes for "new line", not "send".
    public static func send(
        _ text: String, to context: TerminalContext, workingDirectory: String?
    ) async -> JumpResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: performSend(
                    text, to: context, workingDirectory: workingDirectory))
            }
        }
    }

    private static func performSend(
        _ text: String, to context: TerminalContext, workingDirectory: String?
    ) -> JumpResult {
        let line = text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failed("nothing to send")
        }

        if context.isInsideTmux, let pane = context.tmuxPane, isPlausibleIdentifier(pane) {
            guard let socket = tmuxSocketPath(from: context.tmuxSocket),
                  let tmux = locateExecutable(named: "tmux", candidates: tmuxCandidates)
            else { return .failed("tmux is not reachable") }
            let typed = runCommand(
                executable: tmux, arguments: ["-S", socket, "send-keys", "-t", pane, "-l", "--", line])
            guard typed.succeeded else { return .failed("tmux send-keys failed: \(typed.failureSummary)") }
            let entered = runCommand(
                executable: tmux, arguments: ["-S", socket, "send-keys", "-t", pane, "Enter"])
            return entered.succeeded ? .precise : .failed("tmux send-keys failed: \(entered.failureSummary)")
        }

        switch context.kind {
        case .iTerm2:
            guard let tty = context.ttyPath, !tty.isEmpty else { return .failed("no tty recorded") }
            guard isRunning(.iTerm2) else { return .failed("iTerm2 is not running") }
            let script = """
            tell application id \(quoted(TerminalKind.iTerm2.bundleIdentifier ?? ""))
                repeat with theWindow in windows
                    repeat with theTab in tabs of theWindow
                        repeat with theSession in sessions of theTab
                            if tty of theSession is \(quoted(tty)) then
                                tell theSession
                                    write text \(quoted(line)) newline NO
                                    write text (ASCII character 13) newline NO
                                end tell
                                return "matched"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "unmatched"
            """
            return replyOutcome(runAppleScript(script), kind: .iTerm2)

        case .ghostty:
            guard let workingDirectory, !workingDirectory.isEmpty else {
                return .failed("no working directory to find the Ghostty terminal by")
            }
            guard isRunning(.ghostty) else { return .failed("Ghostty is not running") }
            let script = ghosttyScript(
                matching: workingDirectory,
                then: """
                input text \(quoted(line)) to theTerminal
                send key "enter" to theTerminal
                """)
            return replyOutcome(runAppleScript(script), kind: .ghostty)

        default:
            return .failed("\(context.kind.displayName) cannot be typed into from here")
        }
    }

    private static func replyOutcome(_ outcome: AppleScriptOutcome, kind: TerminalKind) -> JumpResult {
        switch outcome {
        case .matched: return .precise
        case .unmatched: return .failed("the session's \(kind.displayName) tab is gone")
        case .permissionDenied:
            return .failed("allow AndonCord to control \(kind.displayName) in System Settings → Privacy & Security → Automation")
        case .failure(let reason): return .failed(reason)
        }
    }

    // MARK: - Ghostty

    /// Ghostty 1.3 and later script their windows, tabs and terminals. A
    /// terminal exposes no tty, so the working directory is the handle; the
    /// first terminal in it wins. `body` runs with `theWindow`, `theTab` and
    /// `theTerminal` bound.
    private static func ghosttyScript(matching directory: String, then body: String) -> String {
        let candidates = [directory, directory.hasSuffix("/") ? String(directory.dropLast()) : directory + "/"]
        let test = candidates.map { "(working directory of theTerminal as text) is \(quoted($0))" }
            .joined(separator: " or ")
        return """
        tell application id \(quoted(TerminalKind.ghostty.bundleIdentifier ?? ""))
            repeat with theWindow in windows
                repeat with theTab in tabs of theWindow
                    repeat with theTerminal in terminals of theTab
                        if \(test) then
                            \(body)
                            return "matched"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "unmatched"
        """
    }

    /// Window, then tab, then the split itself — Ghostty applies each
    /// asynchronously, hence the short pauses. `activate` comes last on
    /// purpose: activating Ghostty with no window focused opens its quick
    /// terminal instead.
    private static func jumpToGhostty(_ context: TerminalContext, workingDirectory: String?) -> JumpResult {
        guard isRunning(.ghostty) else { return .failed("Ghostty is not running") }
        guard let workingDirectory, !workingDirectory.isEmpty else {
            return .failed("no working directory to find the Ghostty terminal by")
        }
        let script = ghosttyScript(
            matching: workingDirectory,
            then: """
            activate window theWindow
            delay 0.05
            select tab theTab
            delay 0.05
            focus theTerminal
            activate
            """)
        switch runAppleScript(script) {
        case .matched:
            return .precise
        case .unmatched:
            return .failed("no Ghostty terminal is in \(workingDirectory)")
        case .permissionDenied:
            return .failed("allow AndonCord to control Ghostty in System Settings → Privacy & Security → Automation")
        case .failure(let reason):
            return .failed(reason)
        }
    }

    /// Fire-and-forget variant for call sites that cannot `await` — AppKit
    /// target/action methods, menu handlers, notification callbacks.
    ///
    /// - Parameter completion: invoked on the main queue, so it is safe to
    ///   touch UI from it.
    public static func jumpInBackground(
        to context: TerminalContext,
        completion: (@Sendable (JumpResult) -> Void)? = nil
    ) {
        queue.async {
            let result = performJump(context, workingDirectory: nil)
            guard let completion else { return }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Current automation permission for a terminal, without triggering the
    /// consent prompt.
    ///
    /// Uses `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded:
    /// false`, which is the only way to distinguish "denied" from "never
    /// asked" — an actual Apple event would either succeed, fail with -1743,
    /// or pop a dialog we did not want to pop.
    public static func automationPermissionState(
        for kind: TerminalKind
    ) -> PermissionState {
        guard usesAppleEvents(kind), let bundleID = kind.bundleIdentifier else {
            return .notApplicable
        }

        let identifier = Array(bundleID.utf8)
        var target = AEAddressDesc()
        let created = identifier.withUnsafeBufferPointer { buffer in
            AECreateDesc(
                typeApplicationBundleID, buffer.baseAddress, buffer.count, &target
            )
        }
        guard created == noErr else { return .notDetermined }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target, wildcardEventClass, wildcardEventID, false
        )
        switch status {
        case noErr:
            return .granted
        case errAEEventNotPermitted:
            return .denied
        case errAEEventWouldRequireUserConsent:
            return .notDetermined
        case procNotFound:
            // The app is not running, so the system cannot answer yet. Not a
            // denial — treat it as undetermined rather than alarming the user.
            return .notDetermined
        default:
            Log.jump.debug(
                "permission probe for \(bundleID, privacy: .public) returned \(status)"
            )
            return .notDetermined
        }
    }

    // MARK: - Dispatch

    private static func performJump(
        _ context: TerminalContext, workingDirectory: String?
    ) -> JumpResult {
        let result = route(context, workingDirectory: workingDirectory)
        switch result {
        case .precise:
            Log.jump.info(
                "precise jump into \(context.kind.rawValue, privacy: .public)"
            )
        case .appActivated:
            Log.jump.info(
                "activated \(context.kind.rawValue, privacy: .public) without tab targeting"
            )
        case .failed(let reason):
            Log.jump.error(
                """
                jump to \(context.kind.rawValue, privacy: .public) failed: \
                \(reason, privacy: .public)
                """
            )
        }
        return result
    }

    private static func route(_ context: TerminalContext, workingDirectory: String?) -> JumpResult {
        // tmux wins over the host terminal: when a session lives in a tmux
        // pane, the terminal's own tab addressing points at the tmux client,
        // not at the pane the session is actually in.
        // Validated like the other pane ids: argv arrays make injection
        // impossible today, but hook-derived strings should never rely on
        // the call site staying shell-free.
        if context.isInsideTmux, let pane = context.tmuxPane, isPlausibleIdentifier(pane) {
            return jumpViaTmux(context, pane: pane)
        }

        switch context.kind {
        case .iTerm2:
            return jumpToITerm2(context)
        case .appleTerminal:
            return jumpToAppleTerminal(context)
        case .wezTerm:
            return jumpToWezTerm(context)
        case .kitty:
            return jumpToKitty(context)
        case .ghostty:
            let precise = jumpToGhostty(context, workingDirectory: workingDirectory)
            if case .failed(let reason) = precise {
                Log.jump.notice("Ghostty jump fell back to the app: \(reason, privacy: .public)")
                return activateGhosttyWindow()
            }
            return precise
        case .warp, .alacritty, .hyper, .zed, .vscode, .cursor,
             .windsurf, .claudeDesktop, .unknown:
            // None of these expose a public, stable way to address an
            // individual tab or split from outside the app. Raising the app is
            // the honest maximum.
            return activateApp(
                context.kind, hostBundleIdentifier: context.hostBundleIdentifier)
        }
    }

    // MARK: - tmux

    private static func jumpViaTmux(
        _ context: TerminalContext, pane: String
    ) -> JumpResult {
        guard let socket = tmuxSocketPath(from: context.tmuxSocket) else {
            return .failed("could not parse the tmux socket path")
        }
        guard let tmux = locateExecutable(named: "tmux", candidates: tmuxCandidates) else {
            return .failed("tmux binary not found")
        }

        // Select the window first: selecting a pane in a window that is not
        // current leaves the client showing the old window.
        let window = runCommand(
            executable: tmux, arguments: ["-S", socket, "select-window", "-t", pane]
        )
        guard window.succeeded else {
            return .failed("tmux select-window failed: \(window.failureSummary)")
        }

        let selectPane = runCommand(
            executable: tmux, arguments: ["-S", socket, "select-pane", "-t", pane]
        )
        guard selectPane.succeeded else {
            return .failed("tmux select-pane failed: \(selectPane.failureSummary)")
        }

        // tmux only rearranges its own server-side state. The client rendering
        // that session lives inside a terminal window that may be buried behind
        // other apps or minimised, and tmux has no idea that window exists — so
        // without this step the pane is "selected" somewhere the user cannot
        // see. Activation failure is not fatal: the selection did land, and the
        // user will see it the moment they switch to the terminal themselves.
        if case .failed(let reason) = activateApp(
            context.kind, hostBundleIdentifier: context.hostBundleIdentifier) {
            Log.jump.notice(
                """
                tmux pane selected but host app was not raised: \
                \(reason, privacy: .public)
                """
            )
        }
        return .precise
    }

    /// `TMUX` is `<socket-path>,<server-pid>,<session-id>`; only the first
    /// field is the socket. Passing the whole variable to `-S` silently creates
    /// a brand new server at a nonsense path.
    private static func tmuxSocketPath(from tmuxEnvironment: String?) -> String? {
        guard let tmuxEnvironment, !tmuxEnvironment.isEmpty else { return nil }
        let socket = tmuxEnvironment.split(
            separator: ",", maxSplits: 1, omittingEmptySubsequences: false
        )[0]
        guard !socket.isEmpty else { return nil }
        return String(socket)
    }

    // MARK: - iTerm2

    private static func jumpToITerm2(_ context: TerminalContext) -> JumpResult {
        guard let tty = context.ttyPath, !tty.isEmpty else {
            return activateApp(.iTerm2)
        }
        guard isRunning(.iTerm2) else { return .failed("iTerm2 is not running") }

        // Matching on tty rather than ITERM_SESSION_ID: iTerm2 mints a fresh
        // session UUID whenever it restores a window (relaunch, "Restore
        // Session", or a profile reload), so a captured ITERM_SESSION_ID goes
        // stale while the shell — and therefore its controlling tty — survives
        // untouched. The tty is the handle that actually tracks the process we
        // care about.
        let script = """
        tell application id \(quoted(TerminalKind.iTerm2.bundleIdentifier ?? ""))
            repeat with theWindow in windows
                repeat with theTab in tabs of theWindow
                    repeat with theSession in sessions of theTab
                        if tty of theSession is \(quoted(tty)) then
                            select theSession
                            select theTab
                            set index of theWindow to 1
                            activate
                            return "matched"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "unmatched"
        """

        return resolveAppleScript(runAppleScript(script), kind: .iTerm2)
    }

    // MARK: - Terminal.app

    private static func jumpToAppleTerminal(_ context: TerminalContext) -> JumpResult {
        guard let tty = context.ttyPath, !tty.isEmpty else {
            return activateApp(.appleTerminal)
        }
        guard isRunning(.appleTerminal) else {
            return .failed("Terminal is not running")
        }

        // Terminal.app models tabs as having a tty directly (no session layer),
        // and `TERM_SESSION_ID` is likewise unstable across restores, so the
        // same tty-first reasoning as iTerm2 applies.
        let script = """
        tell application id \(quoted(TerminalKind.appleTerminal.bundleIdentifier ?? ""))
            repeat with theWindow in windows
                repeat with theTab in tabs of theWindow
                    if tty of theTab is \(quoted(tty)) then
                        set selected of theTab to true
                        set frontmost of theWindow to true
                        activate
                        return "matched"
                    end if
                end repeat
            end repeat
        end tell
        return "unmatched"
        """

        return resolveAppleScript(runAppleScript(script), kind: .appleTerminal)
    }

    /// Collapses an AppleScript outcome into a jump result, degrading to plain
    /// activation whenever the script could not do its job.
    private static func resolveAppleScript(
        _ outcome: AppleScriptOutcome, kind: TerminalKind
    ) -> JumpResult {
        switch outcome {
        case .matched:
            return .precise
        case .unmatched:
            // The tty is gone (shell exited, tab closed) but the app is alive.
            Log.jump.notice(
                "no \(kind.rawValue, privacy: .public) tab matched the recorded tty"
            )
            return activateApp(kind)
        case .permissionDenied:
            // Activation does not require automation permission, so the user
            // still gets their app raised; the UI explains the shortfall by
            // calling `automationPermissionState(for:)`.
            Log.jump.error(
                """
                automation permission denied for \(kind.rawValue, privacy: .public); \
                grant it in System Settings → Privacy & Security → Automation
                """
            )
            return activateApp(kind)
        case .failure(let reason):
            Log.jump.error(
                """
                AppleScript against \(kind.rawValue, privacy: .public) failed: \
                \(reason, privacy: .public)
                """
            )
            return activateApp(kind)
        }
    }

    // MARK: - WezTerm

    private static func jumpToWezTerm(_ context: TerminalContext) -> JumpResult {
        guard let pane = context.wezTermPane, isPlausibleIdentifier(pane) else {
            return activateApp(.wezTerm)
        }
        guard let wezterm = locateExecutable(
            named: "wezterm", candidates: wezTermCandidates
        ) else {
            return activateApp(.wezTerm)
        }

        let result = runCommand(
            executable: wezterm,
            arguments: ["cli", "activate-pane", "--pane-id", pane]
        )
        guard result.succeeded else {
            Log.jump.error(
                "wezterm activate-pane failed: \(result.failureSummary, privacy: .public)"
            )
            return activateApp(.wezTerm)
        }

        // `activate-pane` reaches the mux server, which does not necessarily
        // own the frontmost window — same reasoning as tmux.
        if case .failed(let reason) = activateApp(.wezTerm) {
            Log.jump.notice(
                "WezTerm pane activated but app not raised: \(reason, privacy: .public)"
            )
        }
        return .precise
    }

    // MARK: - kitty

    private static func jumpToKitty(_ context: TerminalContext) -> JumpResult {
        // `KITTY_LISTEN_ON` only exists when the user opted into remote control
        // (`allow_remote_control` plus `listen_on` in kitty.conf). Without it
        // there is no channel to kitty at all, so do not pretend.
        // `listen_on` is only ever a unix:/tcp: address in kitty.conf; any
        // other shape is a corrupted or hostile env, not a reachable kitty.
        guard let listenOn = context.kittyListenOn,
              listenOn.hasPrefix("unix:") || listenOn.hasPrefix("tcp:"),
              let windowID = context.kittyWindowId, isPlausibleIdentifier(windowID)
        else {
            return activateApp(.kitty)
        }
        guard let kitty = locateExecutable(named: "kitty", candidates: kittyCandidates) else {
            return activateApp(.kitty)
        }

        let result = runCommand(
            executable: kitty,
            arguments: ["@", "--to", listenOn, "focus-window", "--match", "id:\(windowID)"]
        )
        guard result.succeeded else {
            Log.jump.error(
                "kitty focus-window failed: \(result.failureSummary, privacy: .public)"
            )
            return activateApp(.kitty)
        }

        if case .failed(let reason) = activateApp(.kitty) {
            Log.jump.notice(
                "kitty window focused but app not raised: \(reason, privacy: .public)"
            )
        }
        return .precise
    }

    // MARK: - Activation

    /// Raise an already-running app.
    ///
    /// Deliberately does not launch anything: a jump is "take me back to where
    /// my session is", and if the terminal is gone the session is gone with it.
    /// Spawning a fresh empty window would be worse than doing nothing.
    private static func activateApp(
        _ kind: TerminalKind, hostBundleIdentifier: String? = nil
    ) -> JumpResult {
        // Fall back to whatever app launched the shell. Claude Code is often
        // run somewhere that is not a terminal emulator at all — the Claude
        // desktop app, an IDE task runner — and raising that host is still a
        // useful jump even though no tab can be addressed.
        guard let bundleID = kind.bundleIdentifier ?? hostBundleIdentifier else {
            return .failed("AndonCord can't tell which app this session is running in")
        }
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        )
        guard let app = running.first else {
            return .failed("\(kind.displayName) is not running")
        }

        // `NSRunningApplication` is documented as safe from any thread, so this
        // does not need a main-queue hop — which matters, because hopping would
        // reintroduce a main-thread dependency on the very path meant to avoid
        // one.
        guard app.activate() else {
            return .failed("\(kind.displayName) refused activation")
        }
        return .appActivated
    }

    /// Raise Ghostty's front window. Not `NSRunningApplication.activate()`,
    /// which with no window focused opens Ghostty's quick terminal instead.
    private static func activateGhosttyWindow() -> JumpResult {
        guard isRunning(.ghostty) else { return .failed("Ghostty is not running") }
        let script = """
        tell application id \(quoted(TerminalKind.ghostty.bundleIdentifier ?? ""))
            if (count of windows) is 0 then return "unmatched"
            activate window (item 1 of windows)
            activate
        end tell
        return "matched"
        """
        switch runAppleScript(script) {
        case .matched: return .appActivated
        case .unmatched: return .failed("Ghostty has no window open")
        case .permissionDenied:
            return .failed("allow AndonCord to control Ghostty in System Settings → Privacy & Security → Automation")
        case .failure(let reason): return .failed(reason)
        }
    }

    private static func isRunning(_ kind: TerminalKind) -> Bool {
        guard let bundleID = kind.bundleIdentifier else { return false }
        return !NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        ).isEmpty
    }

    private static func usesAppleEvents(_ kind: TerminalKind) -> Bool {
        switch kind {
        case .iTerm2, .appleTerminal, .ghostty:
            return true
        case .warp, .wezTerm, .kitty, .alacritty, .hyper, .zed,
             .vscode, .cursor, .windsurf, .claudeDesktop, .unknown:
            return false
        }
    }

    // MARK: - AppleScript

    private enum AppleScriptOutcome {
        case matched
        case unmatched
        /// The -1743 case: the user has refused (or not yet granted) Automation
        /// permission for this app.
        case permissionDenied
        case failure(String)
    }

    /// Apple event error for "not authorized to send Apple events to <app>".
    ///
    /// This is the code behind the System Settings → Privacy & Security →
    /// Automation checkbox, and the first Apple event we ever send to a given
    /// app is what raises the consent prompt in the first place.
    private static let notAuthorizedErrorCode = "-1743"

    private static func runAppleScript(_ source: String) -> AppleScriptOutcome {
        let result = runCommand(
            executable: "/usr/bin/osascript", arguments: ["-e", source]
        )

        if result.timedOut {
            return .failure("timed out after \(Int(commandTimeout))s")
        }
        if let launchFailure = result.launchFailure {
            return .failure(launchFailure)
        }
        // osascript reports Apple event errors on stderr with the numeric code
        // in parentheses, e.g. "execution error: … (-1743)".
        if result.standardError.contains(notAuthorizedErrorCode) {
            return .permissionDenied
        }
        guard result.exitStatus == 0 else {
            return .failure(result.failureSummary)
        }
        return result.standardOutput.contains("matched") && !result.standardOutput
            .contains("unmatched") ? .matched : .unmatched
    }

    /// Wrap a value as an AppleScript string literal.
    ///
    /// AppleScript literals understand no escape sequences beyond `\"` and
    /// `\\`, and cannot contain raw control characters at all, so anything else
    /// unprintable is dropped rather than smuggled through. Real inputs here
    /// (tty paths, bundle identifiers) never contain such characters; this
    /// exists so a malformed captured environment cannot produce a script that
    /// means something other than intended.
    private static func quoted(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 2)
        for character in value.unicodeScalars {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            default:
                guard !CharacterSet.controlCharacters.contains(character) else { continue }
                escaped.unicodeScalars.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    /// Guards CLI identifiers (pane ids, window ids) against junk.
    ///
    /// Arguments are passed as an argv array rather than through a shell, so
    /// this is not an injection defence — it just stops a garbled environment
    /// from turning into a confusing CLI error.
    private static func isPlausibleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_%"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: - Binary discovery

    private static let tmuxCandidates = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/opt/local/bin/tmux",
        "/usr/bin/tmux",
    ]

    private static let wezTermCandidates = [
        "/opt/homebrew/bin/wezterm",
        "/usr/local/bin/wezterm",
        "/Applications/WezTerm.app/Contents/MacOS/wezterm",
    ]

    private static let kittyCandidates = [
        "/opt/homebrew/bin/kitty",
        "/usr/local/bin/kitty",
        "/Applications/kitty.app/Contents/MacOS/kitty",
    ]

    /// Probe absolute paths instead of resolving via `PATH`.
    ///
    /// A GUI app launched from Finder inherits a minimal `PATH` that contains
    /// none of the places these tools actually install to, so `which` would
    /// come up empty even when the binary is plainly present.
    private static func locateExecutable(
        named name: String, candidates: [String]
    ) -> String? {
        let fileManager = FileManager.default
        guard let found = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0)
        }) else {
            Log.jump.error("could not locate the \(name, privacy: .public) binary")
            return nil
        }
        return found
    }

    // MARK: - Subprocess

    private struct CommandResult {
        var exitStatus: Int32 = -1
        var standardOutput = ""
        var standardError = ""
        var timedOut = false
        var launchFailure: String?

        var succeeded: Bool {
            launchFailure == nil && !timedOut && exitStatus == 0
        }

        var failureSummary: String {
            if let launchFailure { return launchFailure }
            if timedOut { return "timed out" }
            let trimmed = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "exit status \(exitStatus)" : trimmed
        }
    }

    /// Mutable state shared with the reader and watchdog closures.
    private final class CommandState: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int: Data] = [:]
        private var killed = false

        func append(_ data: Data, slot: Int) {
            lock.lock()
            defer { lock.unlock() }
            storage[slot, default: Data()].append(data)
        }

        func data(slot: Int) -> Data {
            lock.lock()
            defer { lock.unlock() }
            return storage[slot] ?? Data()
        }

        func markKilled() {
            lock.lock()
            defer { lock.unlock() }
            killed = true
        }

        var wasKilled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return killed
        }
    }

    private static func runCommand(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = commandTimeout
    ) -> CommandResult {
        // The whole point of this type is that these calls never touch the main
        // thread; trip loudly rather than ship a latent freeze.
        dispatchPrecondition(condition: .notOnQueue(.main))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Anything reading stdin here would block forever waiting on a terminal
        // that a GUI app does not have.
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return CommandResult(launchFailure: error.localizedDescription)
        }

        // Drain both pipes on separate threads. Waiting on exit while a child
        // fills the 64 KB pipe buffer is a classic mutual deadlock, and a
        // verbose AppleScript error can get close enough to that to matter.
        let state = CommandState()
        let readers = DispatchGroup()
        let ioQueue = DispatchQueue.global(qos: .utility)
        ioQueue.async(group: readers) {
            state.append(outputPipe.fileHandleForReading.readDataToEndOfFile(), slot: 0)
        }
        ioQueue.async(group: readers) {
            state.append(errorPipe.fileHandleForReading.readDataToEndOfFile(), slot: 1)
        }

        let terminate = DispatchWorkItem {
            guard process.isRunning else { return }
            state.markKilled()
            process.terminate()
        }
        // SIGTERM is a request; an app stuck inside an Apple event dispatch can
        // ignore it, so escalate rather than let the timeout be advisory.
        let kill = DispatchWorkItem {
            guard process.isRunning else { return }
            state.markKilled()
            Foundation.kill(process.processIdentifier, SIGKILL)
        }
        ioQueue.asyncAfter(deadline: .now() + timeout, execute: terminate)
        ioQueue.asyncAfter(deadline: .now() + timeout + 0.5, execute: kill)

        process.waitUntilExit()
        terminate.cancel()
        kill.cancel()
        readers.wait()

        return CommandResult(
            exitStatus: process.terminationStatus,
            standardOutput: string(from: state.data(slot: 0)),
            standardError: string(from: state.data(slot: 1)),
            timedOut: state.wasKilled
        )
    }

    private static func string(from data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Apple event constants

    // Spelled out locally so the file does not depend on how these enums happen
    // to be imported into Swift on a given SDK.

    /// `'****'` — matches any event class/ID when probing permission.
    private static let wildcardEventClass = AEEventClass(0x2A2A_2A2A)
    private static let wildcardEventID = AEEventID(0x2A2A_2A2A)

    private static let errAEEventNotPermitted: OSStatus = -1743
    private static let errAEEventWouldRequireUserConsent: OSStatus = -1744
    private static let procNotFound: OSStatus = -600
}
