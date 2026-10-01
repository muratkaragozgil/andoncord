import Foundation

/// The Claude Code hook events AndonCord subscribes to.
///
/// Claude Code emits considerably more than this; we register only for what
/// drives the board, because every registered hook is a process spawn on the
/// user's critical path.
public enum HookEventName: String, Codable, Sendable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case permissionRequest = "PermissionRequest"
    case notification = "Notification"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case preCompact = "PreCompact"
    case postCompact = "PostCompact"

    /// Events where the hook is expected to hold the line open while a human
    /// decides. These get a long timeout and a synchronous response.
    public var isBlockingByDefault: Bool {
        self == .permissionRequest
    }
}

/// Tools whose `PreToolUse` we intercept synchronously because the notch can
/// answer them better than the terminal can.
public enum InterceptedTool: String, Sendable, CaseIterable {
    case exitPlanMode = "ExitPlanMode"
    case askUserQuestion = "AskUserQuestion"

    public static var matcherPattern: String {
        allCases.map(\.rawValue).joined(separator: "|")
    }
}

/// The common envelope Claude Code writes to a hook's stdin.
///
/// Field names mirror the documented payload exactly. Everything is optional
/// because the set of populated fields varies per event, and because the
/// payload is versioned by Claude Code rather than by us — an unknown or
/// missing field must never fail the decode and stall a hook.
public struct HookPayload: Codable, Sendable {
    public var sessionId: String?
    public var promptId: String?
    public var transcriptPath: String?
    public var cwd: String?
    public var permissionMode: String?
    public var hookEventName: String?
    public var agentId: String?
    public var agentType: String?

    // Tool events
    public var toolName: String?
    public var toolInput: JSONValue?
    public var toolResponse: JSONValue?

    // Notification
    public var notificationType: String?
    public var message: String?

    // Lifecycle
    public var source: String?
    public var reason: String?
    public var model: JSONValue?
    public var sessionTitle: String?

    // UserPromptSubmit
    public var userMessage: String?
    public var prompt: String?

    /// Empty payload, used when a stdin blob decodes as JSON but not as
    /// anything we model. The raw object still travels in the envelope.
    public init() {}

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case promptId = "prompt_id"
        case transcriptPath = "transcript_path"
        case cwd
        case permissionMode = "permission_mode"
        case hookEventName = "hook_event_name"
        case agentId = "agent_id"
        case agentType = "agent_type"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolResponse = "tool_response"
        case notificationType = "notification_type"
        case message
        case source
        case reason
        case model
        case sessionTitle = "session_title"
        case userMessage = "user_message"
        case prompt
    }

    public var event: HookEventName? {
        hookEventName.flatMap(HookEventName.init(rawValue:))
    }

    /// `model` arrives as either a bare string or `{id, display_name}`
    /// depending on event and version.
    public var modelDisplayName: String? {
        if let name = model?["display_name"]?.stringValue { return name }
        if let name = model?["id"]?.stringValue { return name }
        return model?.stringValue
    }

    /// The text of whatever the user last typed, across the field names
    /// different Claude Code versions have used for it.
    public var submittedPrompt: String? {
        userMessage ?? prompt ?? message
    }
}

/// What the shim sends us over the socket: the untouched Claude payload plus
/// the context only the shim can observe, because it runs as a child of the
/// user's terminal.
///
/// The decoder is the synthesized one, and that is load-bearing: it skips keys
/// it does not model. A 0.1.x shim also sends an `agentSource` tag, and
/// skipping it is what lets the app still read an envelope from a shim of an
/// older build.
public struct HookEnvelope: Codable, Sendable {
    public static let currentProtocolVersion = 1

    public var protocolVersion: Int
    /// True when the shim is holding the hook open awaiting our decision.
    public var blocking: Bool
    public var payload: HookPayload
    /// The full original object, so the UI can surface fields we do not model.
    public var raw: JSONValue
    public var terminal: TerminalContext?
    public var shimPid: Int32
    public var receivedAt: Date

    public init(
        protocolVersion: Int = HookEnvelope.currentProtocolVersion,
        blocking: Bool,
        payload: HookPayload,
        raw: JSONValue,
        terminal: TerminalContext?,
        shimPid: Int32,
        receivedAt: Date = Date()
    ) {
        self.protocolVersion = protocolVersion
        self.blocking = blocking
        self.payload = payload
        self.raw = raw
        self.terminal = terminal
        self.shimPid = shimPid
        self.receivedAt = receivedAt
    }
}

/// What we send back, which the shim prints verbatim on stdout for Claude Code
/// to interpret.
///
/// Modelled after the documented hook output contract. We only ever populate
/// the fields relevant to the decision at hand; an empty response means
/// "no opinion, carry on".
public struct HookResponse: Codable, Sendable {
    public var hookSpecificOutput: HookSpecificOutput?
    public var suppressOutput: Bool?
    public var systemMessage: String?

    public init(
        hookSpecificOutput: HookSpecificOutput? = nil,
        suppressOutput: Bool? = nil,
        systemMessage: String? = nil
    ) {
        self.hookSpecificOutput = hookSpecificOutput
        self.suppressOutput = suppressOutput
        self.systemMessage = systemMessage
    }

    public struct HookSpecificOutput: Codable, Sendable {
        public var hookEventName: String
        public var permissionDecision: String?
        public var permissionDecisionReason: String?
        public var decision: Decision?

        public init(
            hookEventName: String,
            permissionDecision: String? = nil,
            permissionDecisionReason: String? = nil,
            decision: Decision? = nil
        ) {
            self.hookEventName = hookEventName
            self.permissionDecision = permissionDecision
            self.permissionDecisionReason = permissionDecisionReason
            self.decision = decision
        }
    }

    /// `PermissionRequest` answers with a nested decision object rather than
    /// the flat `permissionDecision` used by `PreToolUse`.
    public struct Decision: Codable, Sendable {
        public var behavior: String
        public var permissionRule: String?
        public var message: String?

        public init(behavior: String, permissionRule: String? = nil, message: String? = nil) {
            self.behavior = behavior
            self.permissionRule = permissionRule
            self.message = message
        }
    }

    /// Allow a single tool call.
    public static func allowPermission() -> HookResponse {
        HookResponse(hookSpecificOutput: .init(
            hookEventName: HookEventName.permissionRequest.rawValue,
            decision: .init(behavior: "allow")))
    }

    /// Allow, and persist a rule so this shape of call stops asking.
    public static func allowPermission(rule: String) -> HookResponse {
        HookResponse(hookSpecificOutput: .init(
            hookEventName: HookEventName.permissionRequest.rawValue,
            decision: .init(behavior: "allow", permissionRule: rule)))
    }

    public static func denyPermission(reason: String) -> HookResponse {
        HookResponse(hookSpecificOutput: .init(
            hookEventName: HookEventName.permissionRequest.rawValue,
            decision: .init(behavior: "deny", message: reason)))
    }

    /// Used for the two `PreToolUse` tools we intercept.
    ///
    /// Answering a question or rejecting a plan is expressed as `deny` with the
    /// human's words as the reason: Claude Code surfaces that reason back to
    /// the model, so the answer lands as ordinary tool feedback and the turn
    /// continues without a round trip through the terminal.
    public static func preToolUse(
        decision: String, reason: String? = nil
    ) -> HookResponse {
        HookResponse(hookSpecificOutput: .init(
            hookEventName: HookEventName.preToolUse.rawValue,
            permissionDecision: decision,
            permissionDecisionReason: reason))
    }

    public static let empty = HookResponse()
}
