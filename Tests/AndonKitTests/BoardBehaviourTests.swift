import Darwin
import XCTest
@testable import AndonKit

/// Behaviour the open-source notch apps taught: what happens around a request
/// rather than to it — interrupts, exits, MCP forms, shortcuts, fullscreen.
@MainActor
final class BoardBehaviourTests: XCTestCase {
    var store: BoardStore!
    var sandbox: URL!

    override func setUp() async throws {
        store = BoardStore()
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("andon-behaviour-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        store.reset()
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func send(
        _ event: HookEventName, session: String = "s1", hostPid: Int32? = nil,
        blocking: Bool = false, extra: (inout HookPayload) -> Void = { _ in }
    ) -> PendingDecision? {
        var p = HookPayload()
        p.sessionId = session
        p.hookEventName = event.rawValue
        extra(&p)
        let env = HookEnvelope(
            blocking: blocking, payload: p, raw: .object([:]),
            terminal: hostPid.map { TerminalContext(kind: .iTerm2, hostPid: $0) }, shimPid: 0)
        let decision = blocking ? PendingDecision(envelope: env) { _ in } : nil
        store.apply(env, decision: decision)
        return decision
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ check: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !check() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: - MCP elicitation

    /// Claude Code waits for elicitation hooks before showing its own form,
    /// so the board only describes the request — and lets it go when it is
    /// settled, however it was settled.
    func testMCPRequestIsShownAndClearedWithoutBeingHeld() {
        _ = send(.userPromptSubmit) { $0.prompt = "sign me in" }
        _ = send(.elicitation) {
            $0.mcpServerName = "linear"
            $0.message = "Sign in to Linear"
            $0.mode = "url"
            $0.url = "https://linear.app/oauth"
            $0.elicitationId = "e1"
        }
        let session = store.session(id: "s1")
        XCTAssertEqual(session?.state, .cordPulled(.attention))
        XCTAssertEqual(session?.elicitation?.server, "linear")
        XCTAssertEqual(session?.elicitation?.url, "https://linear.app/oauth")
        XCTAssertNil(session?.pending, "nothing is parked: the native form must not wait on us")

        _ = send(.elicitationResult) {
            $0.mcpServerName = "linear"
            $0.elicitationId = "e1"
            $0.action = "accept"
        }
        XCTAssertNil(store.session(id: "s1")?.elicitation)
        XCTAssertEqual(store.session(id: "s1")?.state, .running)
    }

    func testFormRequestsCarryNoLink() {
        _ = send(.elicitation) {
            $0.mcpServerName = "jira"
            $0.message = "Which project?"
            $0.mode = "form"
            $0.url = "https://ignored.example"
        }
        XCTAssertNil(store.session(id: "s1")?.elicitation?.url)
    }

    // MARK: - Interrupts

    func testInterruptMarkersAreMatchedWholeAndOnlyOnUserLines() {
        let interrupt = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        let forTool = #"{"type":"user","message":{"content":"[Request interrupted by user for tool use]"}}"#
        let quoted = #"{"type":"user","message":{"content":"why does it say [Request interrupted by user] here?"}}"#
        let assistant = #"{"type":"assistant","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        XCTAssertTrue(TranscriptTail.isInterrupt(Data(interrupt.utf8)))
        XCTAssertTrue(TranscriptTail.isInterrupt(Data(forTool.utf8)))
        XCTAssertFalse(TranscriptTail.isInterrupt(Data(quoted.utf8)))
        XCTAssertFalse(TranscriptTail.isInterrupt(Data(assistant.utf8)))
    }

    /// Esc sends no hook. The transcript is where it shows, and a working
    /// session's lamp must go out when it does.
    func testEscInTheTranscriptStopsTheWorkingLamp() async throws {
        let transcript = sandbox.appendingPathComponent("live.jsonl")
        try #"{"type":"user","message":{"content":"go"}}"#.appending("\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        _ = send(.userPromptSubmit) {
            $0.prompt = "go"
            $0.transcriptPath = transcript.path
        }
        _ = send(.preToolUse) { $0.toolName = "Bash"; $0.toolUseId = "tu_1" }
        XCTAssertEqual(store.session(id: "s1")?.state, .working(tool: "Bash"))

        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            (#"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"# + "\n").utf8))
        try handle.close()

        try await waitUntil("the interrupt to land") { store.session(id: "s1")?.state == .idle }
    }

    func testInterruptLeavesABackgroundSubagentsRequestStanding() {
        let background = send(.permissionRequest, blocking: true) {
            $0.toolName = "Edit"
            $0.agentId = "agent-7"
        }!
        store.markInterrupted(sessionId: "s1")
        XCTAssertFalse(background.isResolved)
        XCTAssertEqual(store.session(id: "s1")?.state, .cordPulled(.permission))
    }

    // MARK: - Exits

    /// A session leaves the board when its Claude Code process exits — at
    /// once, not at the next sweep a minute later.
    func testSessionLeavesTheBoardWhenItsProcessExits() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }

        _ = send(.userPromptSubmit, hostPid: child.processIdentifier) { $0.prompt = "work" }
        XCTAssertNotNil(store.session(id: "s1"))

        child.terminate()
        try await waitUntil("the session to go") { store.session(id: "s1") == nil }
    }

    // MARK: - Shortcuts

    private func request(_ kind: PendingRequest.Kind, suggestions: [JSONValue] = []) -> PendingRequest {
        PendingRequest(sessionId: "s1", kind: kind, toolName: "Bash", toolInput: nil,
                       suggestions: suggestions)
    }

    /// A press never decides what the person cannot see.
    func testShortcutOnAHiddenCardOnlyShowsIt() {
        for shortcut in [CardShortcut.allow, .deny, .alwaysAllow] {
            XCTAssertEqual(shortcut.effect(on: request(.permission), cardOnScreen: false), .reveal)
        }
    }

    func testShortcutsActOnTheCardOnScreen() throws {
        XCTAssertEqual(CardShortcut.allow.effect(on: request(.permission), cardOnScreen: true), .approve)
        XCTAssertEqual(CardShortcut.deny.effect(on: request(.permission), cardOnScreen: true), .deny)
        XCTAssertEqual(CardShortcut.allow.effect(on: request(.plan), cardOnScreen: true), .approvePlan)
        XCTAssertEqual(CardShortcut.deny.effect(on: request(.plan), cardOnScreen: true), .keepPlanning)
        // A question wants an answer, not a yes.
        XCTAssertEqual(CardShortcut.allow.effect(on: request(.question), cardOnScreen: true), .ignore)
        // No "always" a request did not offer.
        XCTAssertEqual(CardShortcut.alwaysAllow.effect(on: request(.permission), cardOnScreen: true), .ignore)

        let rule = JSONValue.object([
            "type": .string("addRules"), "behavior": .string("allow"),
            "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string("make:*")])]),
            "destination": .string("session"),
        ])
        let offered = try XCTUnwrap(PermissionSuggestion(rule))
        XCTAssertEqual(
            CardShortcut.alwaysAllow.effect(on: request(.permission, suggestions: [rule]), cardOnScreen: true),
            .approveAlways(offered))
        XCTAssertEqual(CardShortcut.allow.effect(on: nil, cardOnScreen: true), .ignore)
    }

    // MARK: - Fullscreen

    func testOnlyAWindowFillingTheWholeScreenCountsAsFullscreen() {
        // A 1512×982 built-in screen as primary, AppKit coordinates.
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let fullscreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // Zoomed: below the 37-point menu bar, above a 70-point Dock.
        let zoomed = CGRect(x: 0, y: 37, width: 1512, height: 875)
        XCTAssertTrue(ScreenCover.isCovered(screen: screen, byWindows: [fullscreen], primaryScreenMaxY: 982))
        XCTAssertFalse(ScreenCover.isCovered(screen: screen, byWindows: [zoomed], primaryScreenMaxY: 982))
        XCTAssertFalse(ScreenCover.isCovered(screen: screen, byWindows: [], primaryScreenMaxY: 982))

        // An external display above the primary: window bounds count down
        // from the primary's top, so its fullscreen window has negative y.
        let external = CGRect(x: 0, y: 982, width: 2560, height: 1440)
        let externalFullscreen = CGRect(x: 0, y: -1440, width: 2560, height: 1440)
        XCTAssertTrue(ScreenCover.isCovered(
            screen: external, byWindows: [externalFullscreen], primaryScreenMaxY: 982))
        XCTAssertFalse(ScreenCover.isCovered(
            screen: screen, byWindows: [externalFullscreen], primaryScreenMaxY: 982))
    }

    // MARK: - Statusline

    func testTheStatuslineNeverChainsToItself() {
        XCTAssertEqual(StatuslineChain(command: "~/bin/my-status.sh").forwardCommand, "~/bin/my-status.sh")
        XCTAssertNil(StatuslineChain(command: "/Users/x/.andoncord/bin/andon-statusline").forwardCommand)
        XCTAssertNil(StatuslineChain(
            command: #"/bin/sh -c '"$HOME/.andoncord/bin/andon-hook" --statusline'"#).forwardCommand)
        XCTAssertNil(StatuslineChain(command: "   ").forwardCommand)
        XCTAssertNil(StatuslineChain(command: nil).forwardCommand)
    }
}
