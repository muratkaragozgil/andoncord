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
    /// Auto mode's classifier turned a tool call down. Nobody is asked, so
    /// without this the board never learns it happened.
    case permissionDenied = "PermissionDenied"
    /// An MCP server asking the person for input — a form, or a sign-in
    /// link. Registered passive: Claude Code waits for these hooks *before*
    /// it shows its own form, so holding one would hide that form until the
    /// notch was answered.
    case elicitation = "Elicitation"
    /// The same request, settled — however it was settled.
    case elicitationResult = "ElicitationResult"

    /// Events where the hook is expected to hold the line open while a human
    /// decides. These get a long timeout and a synchronous response.
    public var isBlockingByDefault: Bool {
        self == .permissionRequest
    }
}

/// Tools the notch answers itself rather than merely approving.
///
/// Both arrive as an ordinary `PermissionRequest`. Claude Code shows its own
/// dialog for them at the same moment, so the person can answer in either
/// place and the first answer wins.
public enum InterceptedTool: String, Sendable, CaseIterable {
    case exitPlanMode = "ExitPlanMode"
    case askUserQuestion = "AskUserQuestion"
}

/// The common envelope Claude Code writes to a hook's stdin.
///
/// Field names mirror the documented payload exactly. Everything is optional
/// because the set of populated fields varies per event, and because the
/// payload is versioned by Claude Code rather than by us — an unknown or
/// missing field must never fail the decode and stall a hook. Nor may a known
/// one that changes type: each field is decoded on its own, so one of them
/// growing into an object costs that field, not the event.
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
    /// On every tool event except `PermissionRequest`, which is why a request
    /// is matched to its call through the `PreToolUse` before it.
    public var toolUseId: String?
    /// `PermissionRequest`: the "don't ask again" options Claude Code's own
    /// dialog offers for this call, in the shape a decision hands back.
    public var permissionSuggestions: [JSONValue]?
    /// `PostToolUseFailure`: the user interrupted the call.
    public var isInterrupt: Bool?

    // Notification
    public var notificationType: String?
    public var message: String?
    public var title: String?

    // Lifecycle
    public var source: String?
    public var reason: String?
    public var model: JSONValue?
    public var sessionTitle: String?
    /// `Stop`, `SubagentStop`, `StopFailure`: the text the turn ended on.
    public var lastAssistantMessage: String?
    /// `StopFailure`: the failure's type (`rate_limit`, `overloaded`, …).
    /// `PostToolUseFailure`: the tool's error.
    public var error: String?
    public var errorDetails: String?
    /// `Stop`: work still in flight when the turn ended — background agents,
    /// shells, monitors. Empty when nothing is.
    public var backgroundTasks: [JSONValue]?
    /// `{"level": "xhigh"}` on models with an effort setting.
    public var effort: JSONValue?

    // Elicitation
    public var mcpServerName: String?
    /// `form` or `url`.
    public var mode: String?
    public var url: String?
    public var elicitationId: String?
    /// `ElicitationResult`: `accept`, `decline` or `cancel`.
    public var action: String?

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
        case toolUseId = "tool_use_id"
        case permissionSuggestions = "permission_suggestions"
        case isInterrupt = "is_interrupt"
        case notificationType = "notification_type"
        case message
        case title
        case source
        case reason
        case model
        case sessionTitle = "session_title"
        case lastAssistantMessage = "last_assistant_message"
        case error
        case errorDetails = "error_details"
        case backgroundTasks = "background_tasks"
        case effort
        case mcpServerName = "mcp_server_name"
        case mode
        case url
        case elicitationId = "elicitation_id"
        case action
        case userMessage = "user_message"
        case prompt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil
        }
        sessionId = field(.sessionId)
        promptId = field(.promptId)
        transcriptPath = field(.transcriptPath)
        cwd = field(.cwd)
        permissionMode = field(.permissionMode)
        hookEventName = field(.hookEventName)
        agentId = field(.agentId)
        agentType = field(.agentType)
        toolName = field(.toolName)
        toolInput = field(.toolInput)
        toolResponse = field(.toolResponse)
        toolUseId = field(.toolUseId)
        permissionSuggestions = field(.permissionSuggestions)
        isInterrupt = field(.isInterrupt)
        notificationType = field(.notificationType)
        message = field(.message)
        title = field(.title)
        source = field(.source)
        reason = field(.reason)
        model = field(.model)
        sessionTitle = field(.sessionTitle)
        lastAssistantMessage = field(.lastAssistantMessage)
        error = field(.error)
        errorDetails = field(.errorDetails)
        backgroundTasks = field(.backgroundTasks)
        effort = field(.effort)
        mcpServerName = field(.mcpServerName)
        mode = field(.mode)
        url = field(.url)
        elicitationId = field(.elicitationId)
        action = field(.action)
        userMessage = field(.userMessage)
        prompt = field(.prompt)
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

    /// `effort.level`, when the model has one.
    public var effortLevel: String? {
        effort?["level"]?.stringValue ?? effort?.stringValue
    }

    /// Whether a `UserPromptSubmit` is something a person typed.
    ///
    /// The same event carries `/loop` wakeups, scheduled tasks, background
    /// agents reporting in and messages from other sessions. `source` says
    /// which, when the build sends it; when it does not, the prompt's own
    /// machine-written markers are the fallback.
    public var isTypedPrompt: Bool {
        if let source { return source == "user" || source == "sdk" }
        guard let text = submittedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return !["<task-notification>", "<agent-message", "<system-reminder>",
                 "<command-name>", "<local-command-stdout>"]
            .contains { text.hasPrefix($0) }
    }

    /// A `StopFailure` as a person would put it.
    public var failureDescription: String {
        let kind: String
        switch error {
        case "rate_limit": kind = "Usage limit reached"
        case "overloaded": kind = "API overloaded"
        case "authentication_failed", "oauth_org_not_allowed": kind = "Signed out"
        case "billing_error": kind = "Billing problem"
        case "account_on_hold", "verification_required": kind = "Account needs attention"
        case "max_output_tokens": kind = "Response too long"
        case "model_not_found": kind = "Model unavailable"
        case "server_error": kind = "API error"
        case "invalid_request": kind = "Request rejected"
        case let other?: kind = other.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: kind = message ?? "API error"
        }
        guard let details = errorDetails?.trimmingCharacters(in: .whitespacesAndNewlines),
              !details.isEmpty else { return kind }
        return "\(kind): \(details)"
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
        /// Allow only. Replaces the tool's whole input — which is how a
        /// question gets its answers: the tools that exist to ask a person
        /// ignore an allow that carries no input of its own.
        public var updatedInput: JSONValue?
        /// Allow only. Permission updates for Claude Code to apply, in the
        /// shape of the `permission_suggestions` it sent: echoing one back is
        /// exactly what its own "don't ask again" option does.
        public var updatedPermissions: [JSONValue]?
        /// Deny only: what Claude is told.
        public var message: String?
        /// Deny only: stop the turn as well.
        public var interrupt: Bool?

        public init(
            behavior: String, updatedInput: JSONValue? = nil,
            updatedPermissions: [JSONValue]? = nil,
            message: String? = nil, interrupt: Bool? = nil
        ) {
            self.behavior = behavior
            self.updatedInput = updatedInput
            self.updatedPermissions = updatedPermissions
            self.message = message
            self.interrupt = interrupt
        }
    }

    /// Allow the call, optionally with a replacement input and permission
    /// updates (an "always allow", a mode change).
    public static func allowPermission(
        updatedInput: JSONValue? = nil, updatedPermissions: [JSONValue] = []
    ) -> HookResponse {
        HookResponse(hookSpecificOutput: .init(
            hookEventName: HookEventName.permissionRequest.rawValue,
            decision: .init(
                behavior: "allow", updatedInput: updatedInput,
                updatedPermissions: updatedPermissions.isEmpty ? nil : updatedPermissions)))
    }

    public static func denyPermission(reason: String, interrupt: Bool = false) -> HookResponse {
        HookResponse(hookSpecificOutput: .init(
            hookEventName: HookEventName.permissionRequest.rawValue,
            decision: .init(behavior: "deny", message: reason, interrupt: interrupt ? true : nil)))
    }

    public static let empty = HookResponse()
}
