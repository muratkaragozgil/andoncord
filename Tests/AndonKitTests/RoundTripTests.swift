import Darwin
import XCTest
@testable import AndonKit

/// Full-loop test across a real process boundary.
///
/// Everything else in the suite tests one side of the socket. This runs the
/// actual `andon-hook` binary as a subprocess, lets it connect over a real
/// Unix socket to a real `HookServer`, drives a decision through the real
/// `BoardStore`, and asserts on what the shim prints to stdout — which is the
/// only thing Claude Code ever reads.
///
/// Requires the shim to be built. Skips if it is not, so the suite stays green
/// on a clean checkout: `swift build --product andon-hook`.
final class RoundTripTests: XCTestCase {
    private var sandbox: URL!
    private var hookBinary: URL!
    private var server: HookServer!
    /// Tracked so a failing assertion cannot leave a blocked shim behind.
    private var spawned: [Process] = []

    override func setUpWithError() throws {
        hookBinary = try Self.locateHookBinary()

        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("andon-rt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        Paths.homeOverride = sandbox

        // Long socket paths silently break bind(); fail loudly instead.
        try XCTSkipUnless(Paths.socketPathFitsInSunPath, "sandbox path too long for a socket")
    }

    override func tearDownWithError() throws {
        for process in spawned where process.isRunning { process.terminate() }
        spawned.removeAll()
        server?.stop()
        server = nil
        Paths.homeOverride = nil
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    private static func locateHookBinary() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["ANDON_HOOK_BIN"] {
            return URL(fileURLWithPath: override)
        }
        // The test bundle sits next to the built products.
        var directory = Bundle(for: RoundTripTests.self).bundleURL
        for _ in 0..<4 {
            let candidate = directory.appendingPathComponent("andon-hook")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        throw XCTSkip("andon-hook not built — run: swift build --product andon-hook")
    }

    /// Launch the shim with HOME pointed at the sandbox so it resolves the
    /// same socket the server is listening on.
    private func launchHook(
        payload: String, blocking: Bool, source: String? = nil
    ) throws -> (process: Process, stdout: Pipe) {
        let process = Process()
        process.executableURL = hookBinary
        var args = blocking ? ["--blocking"] : []
        if let source { args += ["--source", source] }
        process.arguments = args

        var environment = ProcessInfo.processInfo.environment
        // NSHomeDirectory ignores $HOME, so the shim needs the explicit override.
        environment["ANDON_HOME"] = sandbox.path
        environment["TERM_PROGRAM"] = "iTerm.app"
        environment["TMUX_PANE"] = "%7"
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()
        spawned.append(process)
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        return (process, stdout)
    }

    // MARK: - Tests

    @MainActor
    func testPermissionApprovalTravelsBackToTheShim() async throws {
        let board = BoardStore()
        server = HookServer()
        server.onEvent = { envelope, decision in
            MainActor.assumeIsolated { board.apply(envelope, decision: decision) }
        }
        try server.start()

        let payload = """
        {"session_id":"rt-1","cwd":"/tmp/proj","hook_event_name":"PermissionRequest",\
        "tool_name":"Bash","tool_input":{"command":"npm test"}}
        """
        let (process, stdout) = try launchHook(payload: payload, blocking: true)

        // Wait for the request to land on the board.
        try await waitUntil("request parked") { board.session(id: "rt-1")?.pending != nil }

        let session = try XCTUnwrap(board.session(id: "rt-1"))
        XCTAssertEqual(session.state, .cordPulled(.permission))
        // Terminal identity is only observable from the shim's own process.
        XCTAssertEqual(session.terminal?.kind, .iTerm2)
        XCTAssertEqual(session.terminal?.tmuxPane, "%7")

        XCTAssertTrue(process.isRunning, "the hook must still be blocking Claude Code")

        board.approve(try XCTUnwrap(session.pending))

        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let decoded = try XCTUnwrap(
            try? JSONDecoder().decode(HookResponse.self, from: Data(output.utf8)),
            "shim stdout was not a decision: \(output)")
        XCTAssertEqual(decoded.hookSpecificOutput?.decision?.behavior, "allow")
    }

    @MainActor
    func testAbandonedRequestLetsClaudeFallBackToItsOwnPrompt() async throws {
        let board = BoardStore()
        server = HookServer()
        server.onEvent = { envelope, decision in
            MainActor.assumeIsolated { board.apply(envelope, decision: decision) }
        }
        try server.start()

        let payload = """
        {"session_id":"rt-2","hook_event_name":"PermissionRequest","tool_name":"Edit"}
        """
        let (process, stdout) = try launchHook(payload: payload, blocking: true)
        try await waitUntil("request parked") { board.session(id: "rt-2")?.pending != nil }

        // The session goes away while the user is still deciding.
        var ended = HookPayload()
        ended.sessionId = "rt-2"
        ended.hookEventName = HookEventName.sessionEnd.rawValue
        board.apply(
            HookEnvelope(blocking: false, payload: ended, raw: .object([:]),
                         terminal: nil, shimPid: 0),
            decision: nil)

        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "must exit cleanly, never hang")

        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "no decision means Claude Code asks in the terminal instead")
    }

    func testHooksLeftInOtherAgentsNeverReachTheApp() throws {
        // 0.1.x wrote these into ~/.codex, ~/.gemini and ~/.cursor, and only
        // the user can take them out again. Nothing answers on this socket, so
        // a shim that connected anyway — blocking ones especially — would sit
        // here until the deadline instead of exiting.
        let listener = try listenWithoutAnswering()
        defer { close(listener) }

        let payload = """
        {"session_id":"stale-1","hook_event_name":"PreToolUse","tool_name":"Bash"}
        """
        for (source, blocking) in [("codex", false), ("gemini", false), ("cursor", true)] {
            let (process, stdout) = try launchHook(payload: payload, blocking: blocking, source: source)
            guard waitForExit(process, within: 5) else {
                XCTFail("--source \(source) must not wait on anything")
                continue
            }
            XCTAssertEqual(process.terminationStatus, 0, "--source \(source) must exit cleanly")
            XCTAssertTrue(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty,
                          "--source \(source) must print nothing — output is a decision")
        }
        XCTAssertFalse(pendingConnection(on: listener), "a stale hook reached the app")

        // The control: Claude's own hook, untagged, on the same socket.
        let (claude, _) = try launchHook(payload: payload, blocking: false)
        _ = waitForExit(claude, within: 5)
        XCTAssertTrue(pendingConnection(on: listener), "Claude Code's hook must still connect")
    }

    func testCursorRunningClaudesHooksNeverReachesTheApp() throws {
        // Cursor imports ~/.claude/settings.json, so it runs the very entries
        // written for Claude — untagged — with its own payload. The session_id
        // is there because that alone would be enough to put it on the board.
        let listener = try listenWithoutAnswering()
        defer { close(listener) }

        let payload = """
        {"conversation_id":"conv-1","cursor_version":"2.4","hook_event_name":"preToolUse",\
        "tool_name":"Shell","session_id":"conv-1"}
        """
        let (process, stdout) = try launchHook(payload: payload, blocking: true)
        guard waitForExit(process, within: 5) else {
            return XCTFail("Cursor must never be held by our hook")
        }
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty)
        XCTAssertFalse(pendingConnection(on: listener), "a Cursor session reached the app")
    }

    func testShimFailsOpenWhenNothingIsListening() throws {
        // No server started at all — the everyday case of hooks installed
        // while the app is closed.
        let payload = """
        {"session_id":"rt-3","hook_event_name":"PermissionRequest","tool_name":"Bash"}
        """
        let (process, stdout) = try launchHook(payload: payload, blocking: true)

        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(output.isEmpty, "a closed app must be invisible to Claude Code")
    }

    @MainActor
    func testNonBlockingHookReturnsImmediately() async throws {
        let board = BoardStore()
        server = HookServer()
        server.onEvent = { envelope, decision in
            MainActor.assumeIsolated { board.apply(envelope, decision: decision) }
        }
        try server.start()

        let started = Date()
        let payload = """
        {"session_id":"rt-4","hook_event_name":"UserPromptSubmit","user_message":"hello there"}
        """
        let (process, _) = try launchHook(payload: payload, blocking: false)
        process.waitUntilExit()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(process.terminationStatus, 0)
        // This runs on every tool call, so latency here is latency the user
        // feels on every single Claude Code action.
        XCTAssertLessThan(elapsed, 1.0, "the hot path must not stall a tool call")

        try await waitUntil("session created") { board.session(id: "rt-4") != nil }
        XCTAssertEqual(board.session(id: "rt-4")?.title, "hello there")
    }

    /// A bare listening socket at the app's address, with nothing behind it
    /// that answers. Reading its accept queue directly is what tells "never
    /// connected" apart from "connected, and the app ignored it".
    private func listenWithoutAnswering() throws -> Int32 {
        try Paths.ensureDirectories()
        let fd = try SocketTransport.listen(at: Paths.socket.path)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    private func pendingConnection(on listener: Int32) -> Bool {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// `waitUntilExit` with a ceiling, so a shim that wrongly blocks fails the
    /// test rather than hanging the suite.
    private func waitForExit(_ process: Process, within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        return !process.isRunning
    }

    /// Poll until a condition holds, so tests do not depend on fixed sleeps.
    private func waitUntil(
        _ what: String, timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for: \(what)")
    }
}
