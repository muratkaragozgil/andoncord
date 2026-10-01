import XCTest
@testable import AndonKit

/// State-machine tests.
///
/// The invariant that matters most: a blocking hook is Claude Code sitting
/// still. Every path through the store must end in the decision being either
/// resolved or abandoned — a leak here is a hung session, not a cosmetic bug.
@MainActor
final class BoardStoreTests: XCTestCase {
    var store: BoardStore!
    /// Outcomes recorded per decision, so tests can assert what Claude Code saw.
    var outcomes: [UUID: HookResponse?] = [:]

    override func setUp() async throws {
        store = BoardStore()
        outcomes = [:]
    }

    // MARK: - Helpers

    private func payload(
        _ event: HookEventName,
        session: String = "s1",
        tool: String? = nil,
        input: JSONValue? = nil,
        extra: (inout HookPayload) -> Void = { _ in }
    ) -> HookPayload {
        var p = HookPayload()
        p.sessionId = session
        p.hookEventName = event.rawValue
        p.toolName = tool
        p.toolInput = input
        p.cwd = "/Users/dev/myproject"
        extra(&p)
        return p
    }

    private func envelope(_ p: HookPayload, blocking: Bool = false) -> HookEnvelope {
        HookEnvelope(blocking: blocking, payload: p, raw: .object([:]),
                     terminal: nil, shimPid: 1)
    }

    @discardableResult
    private func send(
        _ p: HookPayload, blocking: Bool = false
    ) -> PendingDecision? {
        let env = envelope(p, blocking: blocking)
        guard blocking else {
            store.apply(env, decision: nil)
            return nil
        }
        let id = UUID()
        let decision = PendingDecision(id: id, envelope: env) { [weak self] response in
            self?.outcomes[id] = response
        }
        store.apply(env, decision: decision)
        return decision
    }

    // MARK: - Lifecycle

    func testPromptSetsTitleAndRunningState() {
        send(payload(.sessionStart))
        send(payload(.userPromptSubmit) { $0.userMessage = "fix the auth bug in middleware" })

        let session = store.session(id: "s1")
        XCTAssertEqual(session?.title, "fix the auth bug in middleware")
        XCTAssertEqual(session?.state, .running)
    }

    func testLongPromptsAreTruncatedOnAWordBoundary() {
        let long = "refactor the entire authentication subsystem including all middleware"
        send(payload(.userPromptSubmit) { $0.userMessage = long })
        let title = store.session(id: "s1")!.title
        XCTAssertLessThanOrEqual(title.count, 49)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertFalse(title.dropLast().hasSuffix(" "))
    }

    func testToolActivityIsRecordedAndCapped() {
        send(payload(.userPromptSubmit) { $0.userMessage = "go" })
        for index in 0..<20 {
            send(payload(.postToolUse, tool: "Read",
                         input: .object(["file_path": .string("/a/file\(index).txt")])))
        }
        let activity = store.session(id: "s1")!.recentActivity
        XCTAssertEqual(activity.count, 12, "the tail should stay bounded")
        XCTAssertEqual(activity.last?.summary, "Read(a/file19.txt)")
    }

    func testStopMarksDone() {
        send(payload(.userPromptSubmit) { $0.userMessage = "go" })
        send(payload(.stop) { $0.message = "All set." })
        XCTAssertEqual(store.session(id: "s1")?.state, .done)
        XCTAssertEqual(store.session(id: "s1")?.lastAssistantMessage, "All set.")
    }

    // MARK: - The cord

    func testPermissionRequestPullsTheCord() {
        let decision = send(
            payload(.permissionRequest, tool: "Bash",
                    input: .object(["command": .string("rm -rf build")])),
            blocking: true)
        XCTAssertNotNil(decision)

        let session = store.session(id: "s1")!
        XCTAssertEqual(session.state, .cordPulled(.permission))
        XCTAssertEqual(session.pending?.toolName, "Bash")
        XCTAssertTrue(store.sessionsNeedingHuman.count == 1)
    }

    func testApproveResolvesWithAllowAndResumes() throws {
        let decision = send(payload(.permissionRequest, tool: "Bash"), blocking: true)!
        let request = try XCTUnwrap(store.session(id: "s1")?.pending)

        store.approve(request)

        XCTAssertTrue(decision.isResolved)
        let response = try XCTUnwrap(outcomes[decision.id] ?? nil)
        XCTAssertEqual(response.hookSpecificOutput?.decision?.behavior, "allow")
        XCTAssertEqual(store.session(id: "s1")?.state, .running)
        XCTAssertNil(store.session(id: "s1")?.pending)
    }

    func testApproveWithAlwaysRuleCarriesThePermissionRule() throws {
        let decision = send(payload(.permissionRequest, tool: "Bash"), blocking: true)!
        let request = try XCTUnwrap(store.session(id: "s1")?.pending)

        store.approve(request, alwaysRule: "Bash(npm run test:*)")

        let response = try XCTUnwrap(outcomes[decision.id] ?? nil)
        XCTAssertEqual(response.hookSpecificOutput?.decision?.permissionRule,
                       "Bash(npm run test:*)")
    }

    func testDenyCarriesTheReasonBackToClaude() throws {
        let decision = send(payload(.permissionRequest, tool: "Bash"), blocking: true)!
        let request = try XCTUnwrap(store.session(id: "s1")?.pending)

        store.deny(request, reason: "don't touch the build dir")

        let response = try XCTUnwrap(outcomes[decision.id] ?? nil)
        XCTAssertEqual(response.hookSpecificOutput?.decision?.behavior, "deny")
        XCTAssertEqual(response.hookSpecificOutput?.decision?.message,
                       "don't touch the build dir")
    }

    // MARK: - Intercepted tools

    func testQuestionIsAnsweredAsToolFeedback() throws {
        let input = JSONValue.object([
            "questions": .array([.object([
                "question": .string("Which deployment target?"),
                "header": .string("Target"),
                "options": .array([
                    .object(["label": .string("Production")]),
                    .object(["label": .string("Staging")]),
                ]),
            ])]),
        ])
        let decision = send(
            payload(.preToolUse, tool: InterceptedTool.askUserQuestion.rawValue, input: input),
            blocking: true)!

        XCTAssertEqual(store.session(id: "s1")?.state, .cordPulled(.question))
        let request = try XCTUnwrap(store.session(id: "s1")?.pending)

        store.answerQuestion(request, answer: "Staging")

        let response = try XCTUnwrap(outcomes[decision.id] ?? nil)
        // Answering rides the deny+reason channel, which is what surfaces the
        // choice back to the model as tool feedback.
        XCTAssertEqual(response.hookSpecificOutput?.permissionDecision, "deny")
        XCTAssertEqual(response.hookSpecificOutput?.permissionDecisionReason,
                       "The user answered: Staging")
    }

    func testPlanApprovalAllowsExitPlanMode() throws {
        let decision = send(
            payload(.preToolUse, tool: InterceptedTool.exitPlanMode.rawValue,
                    input: .object(["plan": .string("# Plan\n- step one")])),
            blocking: true)!
        XCTAssertEqual(store.session(id: "s1")?.state, .cordPulled(.plan))

        let request = try XCTUnwrap(store.session(id: "s1")?.pending)
        store.approvePlan(request)

        let response = try XCTUnwrap(outcomes[decision.id] ?? nil)
        XCTAssertEqual(response.hookSpecificOutput?.permissionDecision, "allow")
    }

    func testPlanRejectionForwardsFeedback() throws {
        let decision = send(
            payload(.preToolUse, tool: InterceptedTool.exitPlanMode.rawValue),
            blocking: true)!
        let request = try XCTUnwrap(store.session(id: "s1")?.pending)

        store.rejectPlan(request, feedback: "use Postgres, not SQLite")

        let response = try XCTUnwrap(outcomes[decision.id] ?? nil)
        XCTAssertEqual(response.hookSpecificOutput?.permissionDecision, "deny")
        XCTAssertTrue(response.hookSpecificOutput?.permissionDecisionReason?
            .contains("use Postgres, not SQLite") ?? false)
    }

    // MARK: - Release guarantees

    func testSessionEndReleasesAParkedHook() throws {
        let decision = send(payload(.permissionRequest, tool: "Bash"), blocking: true)!
        XCTAssertFalse(decision.isResolved)

        send(payload(.sessionEnd))

        XCTAssertTrue(decision.isResolved,
                      "a session that ends must not leave Claude Code blocked")
        XCTAssertNil(outcomes[decision.id] ?? nil,
                     "released with no opinion, so Claude falls back to its own prompt")
    }

    func testSecondRequestOnOneSessionReleasesTheFirst() throws {
        let first = send(payload(.permissionRequest, tool: "Bash"), blocking: true)!
        let second = send(payload(.permissionRequest, tool: "Edit"), blocking: true)!

        XCTAssertTrue(first.isResolved, "the displaced request must not be orphaned")
        XCTAssertFalse(second.isResolved)
        XCTAssertEqual(store.session(id: "s1")?.pending?.toolName, "Edit")
    }

    func testEventWithoutSessionIdReleasesRatherThanParks() {
        var p = HookPayload()
        p.hookEventName = HookEventName.permissionRequest.rawValue
        let env = HookEnvelope(blocking: true, payload: p, raw: .object([:]),
                               terminal: nil, shimPid: 1)
        let id = UUID()
        let decision = PendingDecision(id: id, envelope: env) { [weak self] r in
            self?.outcomes[id] = r
        }
        store.apply(env, decision: decision)

        XCTAssertTrue(decision.isResolved,
                      "an unattributable event must still release the hook")
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testResetReleasesEverything() {
        let a = send(payload(.permissionRequest, session: "s1", tool: "Bash"), blocking: true)!
        let b = send(payload(.permissionRequest, session: "s2", tool: "Edit"), blocking: true)!
        store.reset()
        XCTAssertTrue(a.isResolved)
        XCTAssertTrue(b.isResolved)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    // MARK: - Ordering

    func testBoardSurfacesSessionsNeedingAHumanFirst() {
        send(payload(.userPromptSubmit, session: "busy") { $0.userMessage = "working" })
        send(payload(.stop, session: "finished"))
        send(payload(.permissionRequest, session: "waiting", tool: "Bash"), blocking: true)

        XCTAssertEqual(store.orderedSessions.first?.id, "waiting")
        XCTAssertEqual(store.focusSession?.id, "waiting")
    }

    func testNotificationWithoutAParkedRequestStillFlagsAttention() {
        send(payload(.notification) { $0.notificationType = "permission_prompt" })
        XCTAssertEqual(store.session(id: "s1")?.state, .cordPulled(.attention))
    }

    func testAttentionClearsOnceTheTerminalAnswers() {
        // Nothing is parked, so there is no card to answer: the human answers
        // in the terminal, and the board learns it from work resuming.
        send(payload(.notification) { $0.notificationType = "permission_prompt" })
        send(payload(.preToolUse, tool: "Bash"))
        XCTAssertEqual(store.session(id: "s1")?.state, .working(tool: "Bash"))

        send(payload(.notification) { $0.notificationType = "permission_prompt" })
        send(payload(.stop) { $0.message = "Done." })
        XCTAssertEqual(store.session(id: "s1")?.state, .done)
        XCTAssertEqual(store.session(id: "s1")?.lastAssistantMessage, "Done.")
    }
}

/// Reaping sessions whose process is gone.
///
/// `SessionEnd` is the happy path. These cover the cases where it never
/// arrives — a killed process, a closed terminal — because a board that
/// permanently shows a dead session as "running" is worse than an empty one.
@MainActor
final class ReapingTests: XCTestCase {
    var store: BoardStore!

    override func setUp() async throws { store = BoardStore() }

    private func send(session: String, pid: Int32?, at: Date) {
        var p = HookPayload()
        p.sessionId = session
        p.hookEventName = HookEventName.userPromptSubmit.rawValue
        p.userMessage = "work"
        let terminal = pid.map {
            TerminalContext(kind: .iTerm2, shimParentPid: $0)
        }
        store.apply(
            HookEnvelope(blocking: false, payload: p, raw: .object([:]),
                         terminal: terminal, shimPid: 0, receivedAt: at),
            decision: nil)
    }

    func testSessionWithDeadProcessIsRemoved() {
        // PID 999999 is above the default pid_max and cannot be live.
        send(session: "dead", pid: 999_999, at: Date().addingTimeInterval(-300))
        XCTAssertNotNil(store.session(id: "dead"))

        store.reapDeadSessions()

        XCTAssertNil(store.session(id: "dead"),
                     "a session whose Claude Code process is gone must not linger")
    }

    func testSessionWithLiveProcessSurvives() {
        send(session: "alive", pid: getpid(), at: Date().addingTimeInterval(-300))
        store.reapDeadSessions()
        XCTAssertNotNil(store.session(id: "alive"))
    }

    func testYoungSessionIsNeverReaped() {
        // Guards against sweeping a session created moments ago, before it has
        // had any chance to report activity.
        send(session: "fresh", pid: 999_999, at: Date())
        store.reapDeadSessions()
        XCTAssertNotNil(store.session(id: "fresh"))
    }

    func testSessionWaitingOnAHumanIsNeverReaped() {
        var p = HookPayload()
        p.sessionId = "waiting"
        p.hookEventName = HookEventName.permissionRequest.rawValue
        p.toolName = "Bash"
        let env = HookEnvelope(
            blocking: true, payload: p, raw: .object([:]),
            terminal: TerminalContext(kind: .iTerm2, shimParentPid: 999_999),
            shimPid: 0, receivedAt: Date().addingTimeInterval(-3600))
        var settled = false
        let decision = PendingDecision(envelope: env) { _ in settled = true }
        store.apply(env, decision: decision)

        store.reapDeadSessions()

        XCTAssertNotNil(store.session(id: "waiting"),
                        "a parked request is blocking a real process; never sweep it")
        XCTAssertFalse(settled)
    }

    func testSessionWithNoPidSurvivesUntilTheIdleTimeout() {
        send(session: "nopid", pid: nil, at: Date().addingTimeInterval(-600))
        store.reapDeadSessions()
        XCTAssertNotNil(store.session(id: "nopid"), "10 minutes is not idle enough")

        send(session: "nopid2", pid: nil, at: Date().addingTimeInterval(-5 * 3600))
        store.reapDeadSessions()
        XCTAssertNil(store.session(id: "nopid2"))
    }
}
