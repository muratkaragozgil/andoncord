import Foundation

/// What one prompt cost.
///
/// A "turn" is everything between one thing the human typed and the next: the
/// assistant messages, the tool calls, the retries. Attributing tokens this
/// way is the only breakdown that answers "which of my prompts was
/// expensive", because a single sentence can trigger forty API calls.
public struct PromptTurn: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var prompt: String
    public var at: Date
    public var usage: TokenUsage
    public var toolCalls: Int
    /// Prompts Claude Code generates on the user's behalf — queued follow-ups,
    /// compaction continuations, SDK-driven turns. Kept, but marked, so the
    /// "your most expensive prompts" list is actually about things you wrote.
    public var isSynthetic: Bool

    public init(
        id: String, prompt: String, at: Date, usage: TokenUsage = TokenUsage(),
        toolCalls: Int = 0, isSynthetic: Bool = false
    ) {
        self.id = id
        self.prompt = prompt
        self.at = at
        self.usage = usage
        self.toolCalls = toolCalls
        self.isSynthetic = isSynthetic
    }
}

/// What one file (or one shell command, or one MCP call) cost.
///
/// `direct` is the size of the tool result itself. `carried` is the part
/// nobody sees: once a result is in the context it is re-sent as a cache read
/// on *every* subsequent request in that session, so a 40k-token file read on
/// turn 3 of a 60-turn session is charged sixty times over. Sorting by
/// `carried` is what turns "I read a big file once" into an explanation for
/// where a session's millions of tokens actually went.
public struct ContextFootprint: Codable, Sendable, Identifiable, Equatable {
    /// Tool *and* target. A `Read` and an `Edit` of the same file are two
    /// different lines with two different costs, and keying on the path alone
    /// would collide them the moment both appear in one merged list.
    public var id: String { "\(tool)\u{1}\(key)" }
    /// File path, or a shortened command, or the tool name for tools that
    /// don't address anything in particular.
    public var key: String
    public var tool: String
    public var occurrences: Int
    public var directTokens: Int
    public var carriedTokens: Int
    /// When this target was last pulled into context.
    ///
    /// Carried cost cannot be sliced by time — it is a property of the session
    /// as a whole — so a windowed view includes or excludes a footprint whole,
    /// on the strength of this. Without it a file read last Tuesday would show
    /// up under "today" for as long as its session stayed alive.
    public var lastAt: Date

    public init(
        key: String, tool: String, occurrences: Int = 0,
        directTokens: Int = 0, carriedTokens: Int = 0, lastAt: Date = .distantPast
    ) {
        self.key = key
        self.tool = tool
        self.occurrences = occurrences
        self.directTokens = directTokens
        self.carriedTokens = carriedTokens
        self.lastAt = lastAt
    }

    public var totalTokens: Int { directTokens + carriedTokens }

    /// A path shown as `project/dir/file.swift` — enough to disambiguate two
    /// files with the same name without spending the whole row on a prefix.
    public var displayKey: String {
        // Tools that address nothing in particular key on their own name; the
        // row already shows that, so repeating it twice is just noise.
        if key == tool { return displayTool }
        // `footprintKey` prefixes mode-addressed tools with their own name so
        // the rows stay distinct in the index; the row header already carries
        // the tool, so strip it back off for display.
        if key.hasPrefix(tool + " ") { return String(key.dropFirst(tool.count + 1)) }
        guard key.hasPrefix("/") else { return key }
        let parts = key.split(separator: "/")
        return parts.suffix(3).joined(separator: "/")
    }

    /// `mcp__Claude_Browser__computer` is a wire name, not something to read
    /// off a board. Server and tool, separated, is.
    public var displayTool: String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return String(tool.dropFirst(5)) }
        let server = parts[0].replacingOccurrences(of: "_", with: " ")
        return "\(server)·\(parts.dropFirst().joined(separator: "·"))"
    }
}

/// Usage stamped to the hour it happened in.
///
/// Session totals alone cannot answer "how fast am I burning right now",
/// because a session that ran from 09:00 to 18:00 says nothing about the last
/// hour of it. Bucketing by hour is the smallest thing that does, and it costs
/// one small record per active hour.
public struct HourBucket: Codable, Sendable, Equatable {
    public var hour: Date
    public var usage: TokenUsage

    public init(hour: Date, usage: TokenUsage) {
        self.hour = hour
        self.usage = usage
    }
}

/// One Claude Code session, as reconstructed from its transcript.
public struct SessionUsage: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    /// The `cwd` the session ran in — the real path, not the mangled directory
    /// name Claude Code stores transcripts under.
    public var projectPath: String
    public var title: String
    public var startedAt: Date
    public var lastActivityAt: Date
    public var usage: TokenUsage
    public var models: [String]
    /// The costliest turns only. A long session has thousands of them and
    /// nothing reads past the top of the list, so the tail is dropped at scan
    /// time rather than carried in memory for every session ever recorded.
    public var turns: [PromptTurn]
    /// How many turns there were before that trim, which is the number worth
    /// showing next to a session.
    public var promptCount: Int
    public var footprints: [ContextFootprint]
    /// Usage split by wall-clock hour, for burn rate and the activity chart.
    public var hourly: [HourBucket]
    /// Where the transcript lives, so a row can open it.
    public var transcriptPath: String

    public init(
        id: String, projectPath: String, title: String, startedAt: Date,
        lastActivityAt: Date, usage: TokenUsage = TokenUsage(), models: [String] = [],
        turns: [PromptTurn] = [], promptCount: Int = 0,
        footprints: [ContextFootprint] = [], hourly: [HourBucket] = [],
        transcriptPath: String = ""
    ) {
        self.id = id
        self.projectPath = projectPath
        self.title = title
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.usage = usage
        self.models = models
        self.turns = turns
        self.promptCount = promptCount
        self.footprints = footprints
        self.hourly = hourly
        self.transcriptPath = transcriptPath
    }

    public var projectName: String {
        URL(fileURLWithPath: projectPath).lastComponent
    }

    public var shortId: String { String(id.prefix(8)) }

    /// Human-typed prompts only, most expensive first.
    public var costliestPrompts: [PromptTurn] {
        turns.filter { !$0.isSynthetic && !$0.usage.isEmpty }
            .sorted { $0.usage.total > $1.usage.total }
    }

    public var costliestFootprints: [ContextFootprint] {
        footprints.sorted { $0.totalTokens > $1.totalTokens }
    }

    /// Fold a subagent's spend into the session that spawned it: its usage,
    /// its hours and its models, but not its turns — the subagent's opening
    /// message is the brief it was handed, not a prompt anyone typed.
    public mutating func absorb(_ subagent: SessionUsage) {
        usage += subagent.usage
        var hours = Dictionary(hourly.map { ($0.hour, $0.usage) }, uniquingKeysWith: +)
        for bucket in subagent.hourly { hours[bucket.hour, default: TokenUsage()] += bucket.usage }
        hourly = hours.map { HourBucket(hour: $0.key, usage: $0.value) }
        startedAt = min(startedAt, subagent.startedAt)
        lastActivityAt = max(lastActivityAt, subagent.lastActivityAt)
        for model in subagent.models where !models.contains(model) { models.append(model) }
    }
}

/// Everything one project burned, across all its sessions.
public struct ProjectUsage: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public var path: String
    public var usage: TokenUsage
    public var sessions: [SessionUsage]
    public var lastActivityAt: Date

    public var name: String { URL(fileURLWithPath: path).lastComponent }

    public init(path: String, usage: TokenUsage, sessions: [SessionUsage], lastActivityAt: Date) {
        self.path = path
        self.usage = usage
        self.sessions = sessions
        self.lastActivityAt = lastActivityAt
    }
}

private extension URL {
    /// `lastPathComponent` on a path that ends in a slash returns the parent,
    /// which would silently mislabel a project.
    var lastComponent: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }
}
