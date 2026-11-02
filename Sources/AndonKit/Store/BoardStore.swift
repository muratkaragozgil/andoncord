import Darwin
import Foundation
import Observation

/// Events worth making a noise about.
public enum BoardSound: String, Sendable, CaseIterable {
    case sessionStart
    case cordPulled
    case question
    case planReview
    case cleared
    case denied
    case done
    case failed
}

/// The board: every tracked session, plus the quota readout.
///
/// Single source of truth for the UI. Hook events arrive here on the main
/// queue via `apply`, and every user decision leaves through one of the
/// `resolve*` methods, which is what guarantees a parked hook is always
/// released.
@Observable
@MainActor
public final class BoardStore {
    public private(set) var sessions: [String: Session] = [:]
    public private(set) var status: StatusSnapshot?

    /// Fired for sound playback, with the session it is about — so the app
    /// can stay quiet when that session's own window is the one in front.
    @ObservationIgnored
    public var onSound: ((BoardSound, Session) -> Void)?

    /// Exit watches on each session's Claude Code process, so a session that
    /// quits leaves the board at once rather than at the next sweep.
    @ObservationIgnored
    private var exitWatches: [String: (pid: Int32, source: DispatchSourceProcess)] = [:]

    /// Transcript tails of the sessions that are working, for the interrupt
    /// no hook reports. One per working session, gone once it stops.
    @ObservationIgnored
    private var tails: [String: (path: String, tail: TranscriptTail)] = [:]

    /// Fired when Claude Code publishes a quota reading that differs from the
    /// last one. The app uses it to re-calibrate spend against percentages;
    /// the store itself has no opinion on what that means.
    @ObservationIgnored
    public var onQuotaSample: ((StatusSnapshot) -> Void)?

    /// Parked hooks, keyed by the `PendingRequest.id` shown in the UI.
    @ObservationIgnored
    private var decisions: [UUID: PendingDecision] = [:]

    /// Tool calls that have announced themselves with `PreToolUse` and not
    /// finished yet, per session. A `PermissionRequest` carries no
    /// `tool_use_id`, so this is how a request is tied to its call — and,
    /// through it, how a request answered in the terminal is recognised when
    /// that call's result arrives.
    @ObservationIgnored
    private var inFlight: [String: [InFlightCall]] = [:]

    private struct InFlightCall {
        let toolUseId: String
        let toolName: String
        let input: JSONValue?
    }

    /// Calls that never report back (an interrupt mid-call) would otherwise
    /// accumulate for the life of the session.
    private static let inFlightLimit = 64

    @ObservationIgnored
    private var rateLimitWatcher: FileWatcher?

    /// Readings of the quota windows over time. Claude Code reports only the
    /// instantaneous percentage, so pace — the thing that decides whether the
    /// quota lasts — has to be measured here.
    @ObservationIgnored
    public let quotaHistory = QuotaHistory()
    /// Bumped whenever a new reading lands, so views that read `quotaHistory`
    /// (which is deliberately outside observation, being append-mostly) still
    /// redraw.
    public private(set) var quotaRevision = 0

    public init() {}

    // MARK: - Derived views

    /// Sessions in board order: anything needing a human first, then active
    /// work, then everything else by recency.
    public var orderedSessions: [Session] {
        sessions.values.sorted { lhs, rhs in
            if lhs.state.priority != rhs.state.priority {
                return lhs.state.priority < rhs.state.priority
            }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
    }

    public var sessionsNeedingHuman: [Session] {
        orderedSessions.filter { $0.state.needsHuman }
    }

    public var activeSessionCount: Int {
        sessions.values.filter { $0.state.isActive }.count
    }

    /// What the collapsed pill should be about: whoever pulled the cord,
    /// otherwise the most recently active session.
    public var focusSession: Session? {
        sessionsNeedingHuman.first ?? orderedSessions.first { $0.state.isActive }
            ?? orderedSessions.first
    }

    public var rateLimits: RateLimits? { status?.rateLimits }

    /// Quota windows that are still describing something real, newest reading
    /// first. Empty either because Claude Code has never reported quota, or
    /// because every window we know about has since rolled over.
    public func liveQuota(asOf now: Date = Date()) -> [(kind: QuotaWindowKind, window: RateLimitWindow)] {
        rateLimits?.live(asOf: now) ?? []
    }

    public func forecast(for kind: QuotaWindowKind, now: Date = Date()) -> QuotaForecast {
        _ = quotaRevision
        return quotaHistory.forecast(for: kind, limits: rateLimits, now: now)
    }

    public func session(id: String) -> Session? { sessions[id] }

    public func pendingRequest(id: UUID) -> PendingRequest? {
        for session in sessions.values {
            if let request = session.waitingRequests.first(where: { $0.id == id }) { return request }
        }
        return nil
    }

    // MARK: - Quota

    /// Watch the file the statusline shim writes.
    ///
    /// Polling would be simpler, but the statusline fires on every assistant
    /// message and the whole point of the readout is that it moves in step
    /// with your usage rather than on a timer.
    public func startWatchingRateLimits() {
        loadRateLimits()
        rateLimitWatcher = FileWatcher(url: Paths.rateLimitsCache) { [weak self] in
            Task { @MainActor in self?.loadRateLimits() }
        }
    }

    private func loadRateLimits() {
        guard let data = try? Data(contentsOf: Paths.rateLimitsCache),
              let snapshot = try? JSONDecoder().decode(StatusSnapshot.self, from: data)
        else { return }
        status = snapshot
        recordQuotaSample(from: snapshot)
    }

    /// Bank the reading so the next one has something to be compared against.
    ///
    /// The sample is stamped with `capturedAt` rather than now: the file may
    /// have been written before the app launched, and dating an old reading to
    /// this moment would flatten the pace calculation into nonsense.
    private func recordQuotaSample(from snapshot: StatusSnapshot) {
        guard let limits = snapshot.rateLimits, !limits.isEmpty else { return }
        let sample = QuotaSample(
            at: snapshot.capturedAt,
            fiveHour: limits.fiveHour.map(\.usedPercentage),
            sevenDay: limits.sevenDay.map(\.usedPercentage))
        guard quotaHistory.record(sample) else { return }
        quotaRevision += 1
        onQuotaSample?(snapshot)
    }

    // MARK: - Event intake

    public func apply(_ envelope: HookEnvelope, decision: PendingDecision?) {
        guard let sessionId = envelope.payload.sessionId, !sessionId.isEmpty else {
            // Without a session id we cannot attribute the event. Release the
            // hook rather than leaving it parked forever.
            decision?.abandon()
            return
        }
        let payload = envelope.payload
        var session = sessions[sessionId] ?? makeSession(id: sessionId, payload: payload)

        session.lastActivityAt = envelope.receivedAt
        if let cwd = payload.cwd { session.cwd = cwd }
        if let path = payload.transcriptPath { session.transcriptPath = path }
        if let mode = payload.permissionMode { session.permissionMode = mode }
        if let model = payload.modelDisplayName { session.modelName = model }
        // Terminal identity only travels on events the shim can observe it
        // from, so keep the first non-nil we see.
        if let terminal = envelope.terminal, terminal.kind != .unknown || session.terminal == nil {
            session.terminal = terminal
        }
        if let level = payload.effortLevel { session.effortLevel = level }

        switch payload.event {
        case .sessionStart:
            if let title = payload.sessionTitle, !title.isEmpty { session.title = title }
            // Compaction restarts a session that is already on the board —
            // and since 2.1.299 Claude Code compacts finished sessions on its
            // own, an hour after their last turn. That is housekeeping, not a
            // session starting: the lamp stays as it was, and nothing chimes.
            guard payload.source != "compact" || sessions[sessionId] == nil else { break }
            session.state = Self.waiting(session) ?? .idle
            session.startedAt = envelope.receivedAt
            emit(.sessionStart, session)

        case .userPromptSubmit:
            // A new turn. Whatever the session's own thread was still asking
            // was settled in the terminal or abandoned with Esc; subagents
            // working in the background keep theirs.
            withdraw(on: &session) { $0.agentId == nil }
            session.elicitation = nil
            if payload.isTypedPrompt, let prompt = payload.submittedPrompt, !prompt.isEmpty {
                session.lastPrompt = prompt
                session.title = Self.titleFromPrompt(prompt)
            }
            // Claude Code's own name for the conversation, once it has one,
            // says more than the first forty-eight characters of a prompt.
            if let title = payload.sessionTitle, !title.isEmpty { session.title = title }
            session.state = Self.waiting(session) ?? .running
            session.turnStartedAt = envelope.receivedAt
            session.lastAssistantMessage = nil
            session.recentActivity.removeAll()

        case .preToolUse:
            let tool = payload.toolName ?? "tool"
            if let id = payload.toolUseId {
                track(InFlightCall(toolUseId: id, toolName: tool, input: payload.toolInput),
                      in: sessionId)
            }
            // Only a hook written by AndonCord 0.2 or earlier still blocks
            // here. Questions and plans now arrive as `PermissionRequest`,
            // next to the terminal's own dialog, so this one is let go and the
            // request that follows it is what gets parked.
            decision?.abandon()
            if session.pending == nil {
                switch tool {
                case InterceptedTool.askUserQuestion.rawValue:
                    // A question waits on a person whatever the permission
                    // mode, and this event is the one every mode is sure to
                    // send. The cord goes up now; the request that may follow
                    // is what makes it answerable from here.
                    session.state = .cordPulled(.question)
                    emit(.question, session)
                case InterceptedTool.exitPlanMode.rawValue:
                    session.state = .cordPulled(.plan)
                    emit(.planReview, session)
                default:
                    // Guarded on the *parked request*, not on needsHuman: a
                    // session in the attention state has nothing parked here,
                    // so it flips back to working the moment tools start
                    // flowing again (the user answered in the terminal), while
                    // a parked card stays until it is settled.
                    session.state = .working(tool: tool)
                }
            }

        case .postToolUse, .postToolUseFailure, .permissionDenied:
            let tool = payload.toolName ?? "tool"
            let presentation = ToolPresentation.make(toolName: tool, input: payload.toolInput)
            let deniedByClassifier = payload.event == .permissionDenied
            session.recentActivity.append(.init(
                toolName: tool,
                summary: deniedByClassifier
                    ? "\(presentation.activityLine) · denied" : presentation.activityLine,
                at: envelope.receivedAt,
                failed: payload.event != .postToolUse))
            // Keep the tail short; the panel shows a handful of lines.
            if session.recentActivity.count > 12 {
                session.recentActivity.removeFirst(session.recentActivity.count - 12)
            }
            if let id = payload.toolUseId {
                finish(id, in: sessionId)
                // The call got past its prompt some other way — answered in
                // the terminal, most often — so a card still asking about it
                // is asking about nothing.
                withdraw(on: &session) { $0.toolUseId == id }
            }
            if session.pending == nil {
                // An interrupted call ends the turn with no Stop to say so.
                session.state = payload.isInterrupt == true ? .idle : .running
            }

        case .permissionRequest:
            guard envelope.blocking, let decision else {
                decision?.abandon()
                break
            }
            let tool = payload.toolName ?? "tool"
            let kind: PendingRequest.Kind
            switch tool {
            case InterceptedTool.exitPlanMode.rawValue: kind = .plan
            case InterceptedTool.askUserQuestion.rawValue: kind = .question
            default: kind = .permission
            }
            let request = PendingRequest(
                sessionId: sessionId, kind: kind,
                toolName: tool, toolInput: payload.toolInput,
                suggestions: payload.permissionSuggestions ?? [],
                toolUseId: claimCall(named: tool, input: payload.toolInput, on: session),
                agentId: payload.agentId)
            // A question or plan already lit the cord at `PreToolUse`; it
            // chimed then, and does not chime twice.
            let announced = session.pending == nil && session.state == .cordPulled(request.cordReason)
            park(decision, as: request, on: &session)
            switch kind {
            case .plan: if !announced { emit(.planReview, session) }
            case .question: if !announced { emit(.question, session) }
            case .permission: emit(.cordPulled, session)
            }

        case .notification:
            // A notification without a matching parked request means Claude
            // wants attention but the reason is not something we can answer
            // from here — a prompt whose hook we released, an MCP server's
            // form, a teammate waiting on input.
            switch payload.notificationType {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog",
                 "agent_needs_input":
                // A cord already up — a question announced at `PreToolUse` —
                // says more than "needs you", and has already chimed.
                if session.pending == nil, !session.state.needsHuman {
                    session.state = .cordPulled(.attention)
                    emit(.cordPulled, session)
                }
            case "elicitation_complete", "elicitation_response":
                if session.pending == nil, session.state == .cordPulled(.attention) {
                    session.state = .running
                }
            case "idle_prompt":
                if !session.state.needsHuman { session.state = .idle }
            default:
                break
            }

        case .stop:
            // The turn is over, so nothing its own thread asked can still be
            // waiting. A background subagent's request can, and it is the one
            // thing that outranks the turn ending. The attention state has
            // nothing parked — the human answered in the terminal and the
            // turn ran to completion, so it is done.
            withdraw(on: &session) { $0.agentId == nil }
            session.elicitation = nil
            if let text = payload.lastAssistantMessage ?? payload.message, !text.isEmpty {
                session.lastAssistantMessage = text
            }
            if session.pending == nil {
                if payload.backgroundTasks?.isEmpty == false {
                    // The turn ended but its background agents and shells are
                    // still going, and will wake the session when they finish.
                    // A red lamp and a "done" chime would both be untrue.
                    session.state = .running
                } else {
                    session.state = .done
                    emit(.done, session)
                }
            }

        case .stopFailure:
            withdraw(on: &session) { $0.agentId == nil }
            if let text = payload.lastAssistantMessage, !text.isEmpty {
                session.lastAssistantMessage = text
            }
            session.state = Self.waiting(session) ?? .failed(reason: payload.failureDescription)
            emit(.failed, session)

        case .subagentStart:
            if let agent = payload.agentId { session.activeSubagents.insert(agent) }

        case .subagentStop:
            if let agent = payload.agentId {
                session.activeSubagents.remove(agent)
                // A finished subagent is asking nothing any more.
                withdraw(on: &session) { $0.agentId == agent }
            }

        case .elicitation:
            session.elicitation = ElicitationNotice(
                server: payload.mcpServerName ?? "An MCP server",
                message: payload.message ?? "",
                url: payload.mode == "url" ? payload.url : nil,
                id: payload.elicitationId)
            if session.pending == nil, !session.state.needsHuman {
                session.state = .cordPulled(.attention)
                emit(.cordPulled, session)
            }

        case .elicitationResult:
            if payload.elicitationId == nil || payload.elicitationId == session.elicitation?.id {
                session.elicitation = nil
            }
            if session.pending == nil, session.state == .cordPulled(.attention) {
                session.state = .running
            }

        case .sessionEnd:
            session.state = .ended
            sessions[sessionId] = session
            // Release anything still parked for this session before it goes.
            releaseAll(forSession: sessionId)
            inFlight[sessionId] = nil
            stopWatchingExit(of: sessionId)
            tails.removeValue(forKey: sessionId)?.tail.cancel()
            scheduleRemoval(of: sessionId)
            return

        case .preCompact, .postCompact, .none:
            break
        }

        sessions[sessionId] = session
        watchExit(of: session)
        followTranscript(of: session)
    }

    /// Tail a session's transcript while it works, and only then.
    private func followTranscript(of session: Session) {
        let working = session.state.isActive || session.state.needsHuman
        guard working, let path = session.transcriptPath, !path.isEmpty else {
            tails.removeValue(forKey: session.id)?.tail.cancel()
            return
        }
        if tails[session.id]?.path == path { return }
        tails.removeValue(forKey: session.id)?.tail.cancel()
        let sessionId = session.id
        guard let tail = TranscriptTail(url: URL(fileURLWithPath: path), onInterrupt: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.markInterrupted(sessionId: sessionId) }
            }
        }) else { return }
        tails[session.id] = (path, tail)
    }

    /// Esc, seen in the transcript. Claude Code sends no hook for an
    /// interrupted turn — `Stop` does not fire, and `is_interrupt` covers only
    /// a tool that was running — so without this a stopped session went on
    /// showing a working lamp until its next prompt.
    public func markInterrupted(sessionId: String) {
        guard var session = sessions[sessionId] else { return }
        // The interrupt ends whatever its own thread was asking; a parked
        // hook's process has been killed already and hangs up on its own.
        withdraw(on: &session) { $0.agentId == nil }
        session.elicitation = nil
        guard session.pending == nil, session.state.isActive || session.state.needsHuman else {
            sessions[sessionId] = session
            return
        }
        session.state = .idle
        sessions[sessionId] = session
        followTranscript(of: session)
    }

    /// The state a session with something parked must show, or nil when
    /// nothing is.
    private static func waiting(_ session: Session) -> StationState? {
        session.pending.map { .cordPulled($0.cordReason) }
    }

    // MARK: - Tool calls in flight

    private func track(_ call: InFlightCall, in sessionId: String) {
        var calls = inFlight[sessionId] ?? []
        calls.append(call)
        if calls.count > Self.inFlightLimit { calls.removeFirst(calls.count - Self.inFlightLimit) }
        inFlight[sessionId] = calls
    }

    private func finish(_ toolUseId: String, in sessionId: String) {
        inFlight[sessionId]?.removeAll { $0.toolUseId == toolUseId }
    }

    /// The call a `PermissionRequest` is about: the oldest one still in
    /// flight with the same tool and input that no other parked request has
    /// already claimed. Identical calls in flight together are
    /// interchangeable, so taking the oldest is never wrong for long.
    private func claimCall(named tool: String, input: JSONValue?, on session: Session) -> String? {
        let claimed = Set(session.waitingRequests.compactMap(\.toolUseId))
        return inFlight[session.id]?.first {
            $0.toolName == tool && $0.input == input && !claimed.contains($0.toolUseId)
        }?.toolUseId
    }

    private func makeSession(id: String, payload: HookPayload) -> Session {
        Session(
            id: id,
            title: payload.sessionTitle
                ?? payload.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "Session",
            cwd: payload.cwd,
            transcriptPath: payload.transcriptPath)
    }

    /// Truncate a prompt into something that fits a row.
    static func titleFromPrompt(_ prompt: String) -> String {
        let collapsed = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 48 else { return collapsed }
        // Prefer a word boundary so titles do not end mid-word.
        let clipped = collapsed.prefix(48)
        if let space = clipped.lastIndex(of: " "), clipped.distance(from: clipped.startIndex, to: space) > 24 {
            return String(clipped[..<space]) + "…"
        }
        return clipped + "…"
    }

    /// Put a request on the board. A session already showing one queues the
    /// newcomer behind it: parallel subagents ask at once, and each request
    /// is a process blocked until someone answers it.
    private func park(
        _ decision: PendingDecision, as request: PendingRequest, on session: inout Session
    ) {
        decisions[request.id] = decision
        if session.pending == nil {
            session.pending = request
        } else {
            session.queued.append(request)
        }
        session.state = Self.waiting(session) ?? .cordPulled(request.cordReason)
    }

    private func emit(_ sound: BoardSound, _ session: Session) { onSound?(sound, session) }

    private func emit(_ sound: BoardSound, about request: PendingRequest) {
        guard let session = sessions[request.sessionId] else { return }
        onSound?(sound, session)
    }

    // MARK: - Exit watches

    /// Watch a session's Claude Code process for exit, so the session leaves
    /// the board the moment its process does. The periodic sweep stays as
    /// the backstop: a kernel exit watch can be missed, and one can only be
    /// set while the process is still there.
    private func watchExit(of session: Session) {
        guard let pid = session.terminal?.hostPid, pid > 1 else { return }
        if exitWatches[session.id]?.pid == pid { return }
        stopWatchingExit(of: session.id)
        guard Self.isProcessAlive(pid) else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        let sessionId = session.id
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.hostExited(sessionId: sessionId, pid: pid) }
        }
        exitWatches[session.id] = (pid, source)
        source.resume()
    }

    private func stopWatchingExit(of sessionId: String) {
        exitWatches.removeValue(forKey: sessionId)?.source.cancel()
    }

    private func hostExited(sessionId: String, pid: Int32) {
        guard exitWatches[sessionId]?.pid == pid else { return }
        stopWatchingExit(of: sessionId)
        // A parked request's shim has died with its process and hangs up on
        // its own; releasing here only makes sure nothing is left holding.
        remove(sessionId)
    }

    // MARK: - Decisions

    /// Approve a permission request — once, or with one of Claude Code's own
    /// "don't ask again" suggestions applied, exactly as picking it in the
    /// terminal would.
    public func approve(_ request: PendingRequest, always suggestion: PermissionSuggestion? = nil) {
        settle(request, with: .allowPermission(
            updatedPermissions: suggestion.map { [$0.raw] } ?? []))
        emit(.cleared, about: request)
    }

    /// Deny a request. Claude is told `reason` and carries on with something
    /// else, unless `interrupt` also stops the turn.
    public func deny(
        _ request: PendingRequest,
        reason: String = "The user denied this from AndonCord.",
        interrupt: Bool = false
    ) {
        settle(request, with: .denyPermission(reason: reason, interrupt: interrupt))
        emit(.denied, about: request)
    }

    /// Answer an `AskUserQuestion`, every question at once: question text to
    /// the labels picked, or to what was typed.
    ///
    /// The tool runs with the answers filled in, just as when they are picked
    /// in the terminal's own dialog, so Claude reads them as the tool's result
    /// rather than as a refusal with a note attached.
    public func answerQuestion(_ request: PendingRequest, answers: [String: [String]]) {
        settle(request, with: .allowPermission(
            updatedInput: ToolPresentation.answeredInput(request.toolInput, answers: answers)))
        emit(.cleared, about: request)
    }

    /// Approve a plan. Plan mode ends and the session goes back to the mode
    /// it was in before; `acceptEdits` switches it to accepting edits instead,
    /// like the terminal's "auto-accept edits" option.
    public func approvePlan(_ request: PendingRequest, acceptEdits: Bool = false) {
        let mode: [JSONValue] = acceptEdits
            ? [.object([
                "type": .string("setMode"),
                "mode": .string("acceptEdits"),
                "destination": .string("session"),
            ])]
            : []
        settle(request, with: .allowPermission(
            updatedInput: Self.planApprovalInput(request.toolInput),
            updatedPermissions: mode))
        emit(.cleared, about: request)
    }

    /// The input an approved `ExitPlanMode` runs with.
    ///
    /// It cannot be absent: the tool exists to ask a person, and Claude Code
    /// ignores an allow that brings no input for it. Nor may it carry the
    /// plan: a plan in the input reads as one the person rewrote, and comes
    /// back to Claude as "Approved Plan (edited by user)". Everything else is
    /// echoed as it arrived.
    static func planApprovalInput(_ input: JSONValue?) -> JSONValue {
        var object = input?.objectValue ?? [:]
        object.removeValue(forKey: "plan")
        object.removeValue(forKey: "planFilePath")
        return .object(object)
    }

    public func rejectPlan(_ request: PendingRequest, feedback: String) {
        let reason = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        settle(request, with: .denyPermission(reason: reason.isEmpty
            ? "The user rejected the plan and wants to keep planning."
            : "The user rejected the plan and wants to keep planning. Their feedback: \(reason)"))
        emit(.denied, about: request)
    }

    private func settle(_ request: PendingRequest, with response: HookResponse) {
        decisions[request.id]?.resolve(response)
        decisions[request.id] = nil
        guard var session = sessions[request.sessionId] else { return }
        session.removeRequest(id: request.id)
        // The turn resumes the moment the hook is released — unless another
        // request is next in line.
        session.state = Self.waiting(session) ?? .running
        session.lastActivityAt = Date()
        sessions[request.sessionId] = session
    }

    // MARK: - Withdrawal

    /// Take requests off the board that no longer need an answer here —
    /// answered in the terminal, or made moot by the turn ending. Each is
    /// released with no opinion, so its shim exits quietly and nothing is
    /// decided twice. The caller sets the state that follows.
    private func withdraw(on session: inout Session, where matches: (PendingRequest) -> Bool) {
        for request in session.waitingRequests where matches(request) {
            decisions[request.id]?.abandon()
            decisions[request.id] = nil
            session.removeRequest(id: request.id)
        }
        if let state = Self.waiting(session) { session.state = state }
    }

    /// The shim behind a parked request hung up without an answer: Claude
    /// Code killed the hook, because the turn was interrupted or the session
    /// went away. Its card goes with it.
    public func withdraw(decisionId: UUID) {
        guard let requestId = decisions.first(where: { $0.value.id == decisionId })?.key
        else { return }
        decisions[requestId]?.abandon()
        decisions[requestId] = nil
        for (id, var session) in sessions
        where session.waitingRequests.contains(where: { $0.id == requestId }) {
            session.removeRequest(id: requestId)
            session.state = Self.waiting(session) ?? .idle
            sessions[id] = session
            followTranscript(of: session)
        }
    }

    private func releaseAll(forSession sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        for request in session.waitingRequests {
            decisions[request.id]?.abandon()
            decisions[request.id] = nil
        }
    }

    /// Give an ended session a moment on the board before it disappears, so a
    /// session that finishes as you glance up does not vanish under your eyes.
    private func scheduleRemoval(of sessionId: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, case .ended = self.sessions[sessionId]?.state else { return }
            self.remove(sessionId)
        }
    }

    // MARK: - Reaping dead sessions

    /// Don't judge a session before it has had a chance to report anything.
    private static let minimumAgeBeforeReaping: TimeInterval = 60
    /// Fallback for sessions with no usable pid.
    private static let idleTimeout: TimeInterval = 4 * 3600
    private static let sweepInterval: Duration = .seconds(30)

    @ObservationIgnored
    private var reaper: Task<Void, Never>?

    /// Periodically drop sessions whose Claude Code process is gone.
    ///
    /// `SessionEnd` covers the orderly cases. It does not fire when the
    /// process is killed, the terminal window is closed out from under it, or
    /// the machine crashes — and a board that shows a session as "running"
    /// forever is worse than one that briefly shows nothing, because it
    /// teaches you to distrust everything else on it.
    public func startReapingDeadSessions() {
        reaper?.cancel()
        reaper = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sweepInterval)
                guard !Task.isCancelled else { return }
                self?.reapDeadSessions()
            }
        }
    }

    public func stopReaping() {
        reaper?.cancel()
        reaper = nil
    }

    func reapDeadSessions(now: Date = Date()) {
        for (id, session) in sessions {
            // A parked request is a real process blocked on us; never reap
            // that out from under the user. A cord pulled with nothing parked
            // — a question we could only announce — is fair game once its
            // process is gone.
            guard session.waitingRequests.isEmpty else { continue }
            guard now.timeIntervalSince(session.lastActivityAt)
                    > Self.minimumAgeBeforeReaping else { continue }

            if let pid = session.terminal?.hostPid {
                // Claude Code's own process, found by the shim walking up past
                // the shells it was started through — which makes this an
                // exact liveness check rather than a heuristic. Not the shim's
                // parent: that is the wrapper shell, gone the moment the hook
                // returns, and trusting it swept every quiet session off the
                // board a minute after its last event.
                guard !Self.isProcessAlive(pid) else { continue }
                remove(id)
            } else if now.timeIntervalSince(session.lastActivityAt) > Self.idleTimeout {
                // No pid to check (an older payload, or a host that did not
                // report one). Fall back to a timeout long enough that a
                // genuinely idle session is not swept away mid-thought.
                remove(id)
            }
        }
    }

    private func remove(_ sessionId: String) {
        releaseAll(forSession: sessionId)
        sessions.removeValue(forKey: sessionId)
        inFlight[sessionId] = nil
        stopWatchingExit(of: sessionId)
        tails.removeValue(forKey: sessionId)?.tail.cancel()
    }

    /// Signal 0 tests for existence without delivering anything. `EPERM` means
    /// the process exists but belongs to someone else, which still counts.
    static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Drop everything. Used when the user disables the integration.
    public func reset() {
        decisions.values.forEach { $0.abandon() }
        decisions.removeAll()
        sessions.removeAll()
        inFlight.removeAll()
        exitWatches.values.forEach { $0.source.cancel() }
        exitWatches.removeAll()
        tails.values.forEach { $0.tail.cancel() }
        tails.removeAll()
    }
}
