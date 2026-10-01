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

    /// Fired for sound playback. Set by the app.
    @ObservationIgnored
    public var onSound: ((BoardSound) -> Void)?

    /// Fired when Claude Code publishes a quota reading that differs from the
    /// last one. The app uses it to re-calibrate spend against percentages;
    /// the store itself has no opinion on what that means.
    @ObservationIgnored
    public var onQuotaSample: ((StatusSnapshot) -> Void)?

    /// Parked hooks, keyed by the `PendingRequest.id` shown in the UI.
    @ObservationIgnored
    private var decisions: [UUID: PendingDecision] = [:]

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
        sessions.values.first { $0.pending?.id == id }?.pending
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

        switch payload.event {
        case .sessionStart:
            session.state = .idle
            session.startedAt = envelope.receivedAt
            if let title = payload.sessionTitle, !title.isEmpty { session.title = title }
            emit(.sessionStart)

        case .userPromptSubmit:
            if let prompt = payload.submittedPrompt, !prompt.isEmpty {
                session.lastPrompt = prompt
                session.title = Self.titleFromPrompt(prompt)
            }
            session.state = .running
            session.turnStartedAt = envelope.receivedAt
            session.lastAssistantMessage = nil
            session.recentActivity.removeAll()

        case .preToolUse:
            let tool = payload.toolName ?? "tool"
            if envelope.blocking, let decision {
                // One of the tools we intercept: park it and light the cord.
                let kind: PendingRequest.Kind =
                    tool == InterceptedTool.exitPlanMode.rawValue ? .plan : .question
                let request = PendingRequest(
                    sessionId: sessionId, kind: kind,
                    toolName: tool, toolInput: payload.toolInput)
                park(decision, as: request, on: &session)
                emit(kind == .plan ? .planReview : .question)
            } else if session.pending == nil {
                // Guarded on the *parked request*, not on needsHuman: a
                // session in the attention state has nothing parked here, so
                // it should flip back to working the moment tools start
                // flowing again (the user answered in the terminal), while a
                // session with a parked card keeps it until the card is
                // answered.
                session.state = .working(tool: tool)
            }

        case .postToolUse, .postToolUseFailure:
            let tool = payload.toolName ?? "tool"
            let presentation = ToolPresentation.make(toolName: tool, input: payload.toolInput)
            session.recentActivity.append(.init(
                toolName: tool, summary: presentation.activityLine,
                at: envelope.receivedAt,
                failed: payload.event == .postToolUseFailure))
            // Keep the tail short; the panel shows a handful of lines.
            if session.recentActivity.count > 12 {
                session.recentActivity.removeFirst(session.recentActivity.count - 12)
            }
            if session.pending == nil { session.state = .running }

        case .permissionRequest:
            guard envelope.blocking, let decision else {
                decision?.abandon()
                break
            }
            let request = PendingRequest(
                sessionId: sessionId, kind: .permission,
                toolName: payload.toolName ?? "tool", toolInput: payload.toolInput)
            park(decision, as: request, on: &session)
            emit(.cordPulled)

        case .notification:
            // A notification without a matching parked request means Claude
            // wants attention but the reason is not something we can answer
            // from here — most often the idle prompt after a turn ends.
            switch payload.notificationType {
            case "permission_prompt":
                if session.pending == nil {
                    session.state = .cordPulled(.attention)
                    emit(.cordPulled)
                }
            case "idle_prompt":
                if !session.state.needsHuman { session.state = .idle }
            default:
                break
            }

        case .stop:
            // Same principle: only a parked request outranks the turn ending.
            // The attention state has nothing parked — the human answered in
            // the terminal and the turn ran to completion, so it is done.
            if session.pending == nil {
                session.state = .done
                session.lastAssistantMessage = payload.message
                emit(.done)
            }

        case .stopFailure:
            session.state = .failed(reason: payload.message ?? "API error")
            emit(.failed)

        case .subagentStart:
            if let agent = payload.agentId { session.activeSubagents.insert(agent) }

        case .subagentStop:
            if let agent = payload.agentId { session.activeSubagents.remove(agent) }

        case .sessionEnd:
            session.state = .ended
            sessions[sessionId] = session
            // Release anything still parked for this session before it goes.
            releaseAll(forSession: sessionId)
            scheduleRemoval(of: sessionId)
            return

        case .preCompact, .postCompact, .none:
            break
        }

        sessions[sessionId] = session
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

    private func park(
        _ decision: PendingDecision, as request: PendingRequest, on session: inout Session
    ) {
        // A session can only have one cord pulled at a time in the UI. If one
        // is somehow already parked, release it rather than orphan the hook.
        if let existing = session.pending, let stale = decisions[existing.id] {
            stale.abandon()
            decisions[existing.id] = nil
        }
        decisions[request.id] = decision
        session.pending = request
        session.state = .cordPulled(request.cordReason)
    }

    private func emit(_ sound: BoardSound) { onSound?(sound) }

    // MARK: - Decisions

    /// Approve a permission request. `rule` persists an allow rule so this
    /// shape of call stops asking.
    public func approve(_ request: PendingRequest, alwaysRule rule: String? = nil) {
        settle(request, with: rule.map { HookResponse.allowPermission(rule: $0) }
            ?? .allowPermission())
        emit(.cleared)
    }

    public func deny(_ request: PendingRequest, reason: String = "Denied from AndonCord") {
        settle(request, with: .denyPermission(reason: reason))
        emit(.denied)
    }

    /// Answer an `AskUserQuestion`.
    ///
    /// Expressed as a `deny` carrying the human's choice as the reason.
    /// Claude Code feeds that reason back to the model, so the answer lands as
    /// ordinary tool feedback and the turn continues — no keystrokes injected
    /// into someone's terminal, and no dependence on the TUI's internal state.
    public func answerQuestion(_ request: PendingRequest, answer: String) {
        settle(request, with: .preToolUse(
            decision: "deny", reason: "The user answered: \(answer)"))
        emit(.cleared)
    }

    public func approvePlan(_ request: PendingRequest) {
        settle(request, with: .preToolUse(decision: "allow"))
        emit(.cleared)
    }

    public func rejectPlan(_ request: PendingRequest, feedback: String) {
        let reason = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        settle(request, with: .preToolUse(
            decision: "deny",
            reason: reason.isEmpty
                ? "The user rejected the plan and wants to revise it."
                : "The user rejected the plan with this feedback: \(reason)"))
        emit(.denied)
    }

    private func settle(_ request: PendingRequest, with response: HookResponse) {
        decisions[request.id]?.resolve(response)
        decisions[request.id] = nil
        guard var session = sessions[request.sessionId] else { return }
        session.pending = nil
        // The turn resumes the moment the hook is released.
        session.state = .running
        session.lastActivityAt = Date()
        sessions[request.sessionId] = session
    }

    private func releaseAll(forSession sessionId: String) {
        guard let session = sessions[sessionId], let pending = session.pending else { return }
        decisions[pending.id]?.abandon()
        decisions[pending.id] = nil
    }

    /// Give an ended session a moment on the board before it disappears, so a
    /// session that finishes as you glance up does not vanish under your eyes.
    private func scheduleRemoval(of sessionId: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, case .ended = self.sessions[sessionId]?.state else { return }
            self.sessions.removeValue(forKey: sessionId)
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
            // A session with a cord pulled is blocking a real process that is
            // waiting on us; never reap that out from under the user.
            guard !session.state.needsHuman else { continue }
            guard now.timeIntervalSince(session.lastActivityAt)
                    > Self.minimumAgeBeforeReaping else { continue }

            if let pid = session.terminal?.shimParentPid {
                // The hook launcher `exec`s, so the shim's parent is Claude
                // Code itself — which makes this an exact liveness check
                // rather than a heuristic.
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
    }
}
