import Foundation

/// A station on the board.
///
/// The naming follows the andon metaphor deliberately: the interesting state
/// is not "is it busy" but "does it need a human", and the cord is the thing
/// that says so.
public enum StationState: Sendable, Equatable {
    /// Session is open but Claude is not working — waiting on the user to type.
    case idle
    /// Claude is thinking or streaming a response.
    case running
    /// A tool is executing.
    case working(tool: String)
    /// Someone pulled the cord. The line is stopped until a human answers.
    case cordPulled(CordReason)
    /// Turn finished cleanly.
    case done
    /// Turn ended in an API-level failure.
    case failed(reason: String)
    /// Session is gone.
    case ended

    public enum CordReason: String, Sendable, Equatable {
        case permission
        case question
        case plan
        /// `Notification` fired without a matching request — Claude wants
        /// attention but we do not know precisely why.
        case attention
    }

    public var needsHuman: Bool {
        if case .cordPulled = self { return true }
        return false
    }

    public var isActive: Bool {
        switch self {
        case .running, .working: return true
        case .idle, .cordPulled, .done, .failed, .ended: return false
        }
    }

    /// Short board label, uppercase in the UI.
    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .working(let tool): return tool
        case .cordPulled(.permission): return "Cord pulled"
        case .cordPulled(.question): return "Asking"
        case .cordPulled(.plan): return "Plan review"
        case .cordPulled(.attention): return "Needs you"
        case .done: return "Done"
        case .failed: return "Stopped"
        case .ended: return "Ended"
        }
    }

    /// Sort weight so the board surfaces what matters. Lower sorts first.
    public var priority: Int {
        switch self {
        case .cordPulled: return 0
        case .failed: return 1
        case .working, .running: return 2
        case .done: return 3
        case .idle: return 4
        case .ended: return 5
        }
    }
}

/// A request that is holding a hook open, waiting on the user.
public struct PendingRequest: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case permission
        case question
        case plan
    }

    public let id: UUID
    public let sessionId: String
    public let kind: Kind
    public let toolName: String
    public let toolInput: JSONValue?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        sessionId: String,
        kind: Kind,
        toolName: String,
        toolInput: JSONValue?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.toolName = toolName
        self.toolInput = toolInput
        self.createdAt = createdAt
    }

    public var cordReason: StationState.CordReason {
        switch kind {
        case .permission: return .permission
        case .question: return .question
        case .plan: return .plan
        }
    }
}

/// One tracked Claude Code session.
public struct Session: Identifiable, Sendable {
    public let id: String
    public var title: String
    public var cwd: String?
    public var transcriptPath: String?
    public var state: StationState
    public var terminal: TerminalContext?
    public var modelName: String?
    public var permissionMode: String?

    public var startedAt: Date
    public var lastActivityAt: Date
    /// When the current turn began, for the elapsed-time readout.
    public var turnStartedAt: Date?

    /// Most recent user prompt, used as the session title when Claude has not
    /// supplied one.
    public var lastPrompt: String?
    /// Claude's closing message for the turn, shown on the done card.
    public var lastAssistantMessage: String?
    /// Rolling tail of recent tool calls for the expanded row.
    public var recentActivity: [ActivityEntry]

    public var pending: PendingRequest?
    /// Subagent ids currently running under this session.
    public var activeSubagents: Set<String>

    public struct ActivityEntry: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let toolName: String
        public let summary: String
        public let at: Date
        public var failed: Bool

        public init(
            id: UUID = UUID(), toolName: String, summary: String,
            at: Date = Date(), failed: Bool = false
        ) {
            self.id = id
            self.toolName = toolName
            self.summary = summary
            self.at = at
            self.failed = failed
        }
    }

    public init(
        id: String,
        title: String = "Session",
        cwd: String? = nil,
        transcriptPath: String? = nil,
        state: StationState = .idle,
        terminal: TerminalContext? = nil,
        modelName: String? = nil,
        permissionMode: String? = nil,
        startedAt: Date = Date(),
        lastActivityAt: Date = Date(),
        turnStartedAt: Date? = nil,
        lastPrompt: String? = nil,
        lastAssistantMessage: String? = nil,
        recentActivity: [ActivityEntry] = [],
        pending: PendingRequest? = nil,
        activeSubagents: Set<String> = []
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.state = state
        self.terminal = terminal
        self.modelName = modelName
        self.permissionMode = permissionMode
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.turnStartedAt = turnStartedAt
        self.lastPrompt = lastPrompt
        self.lastAssistantMessage = lastAssistantMessage
        self.recentActivity = recentActivity
        self.pending = pending
        self.activeSubagents = activeSubagents
    }

    /// Folder name of `cwd`, which is what people actually recognise a
    /// session by.
    public var projectName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    public var elapsed: TimeInterval {
        Date().timeIntervalSince(turnStartedAt ?? startedAt)
    }
}
