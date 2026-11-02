import Foundation

/// Turns one Claude Code transcript into a `SessionUsage`.
///
/// Claude Code writes `~/.claude/projects/<mangled-cwd>/<session-id>.jsonl`,
/// one JSON object per line, and every assistant line carries the `usage`
/// block from the API response that produced it. That is the only place a
/// per-prompt or per-file token number exists at all — the statusline payload
/// has percentages but no breakdown, and no API call will tell you which of
/// *your* prompts was the expensive one.
///
/// Two details in that format decide whether the numbers come out right:
///
///   * **One API response spans several lines.** Claude Code writes one line
///     per content block — thinking, text, each tool_use — and repeats the
///     identical `usage` object on all of them. Summing per line inflates
///     every total by roughly 3×, so responses are counted once per
///     `message.id`.
///   * **Cache reads are charged per request, not per file.** A file read on
///     turn 3 of a 60-turn session is re-sent as a cache read on all 57
///     requests that follow. Attributing only the first read makes big files
///     look cheap, which is exactly backwards.
public enum TranscriptScanner {

    /// Anything above this is treated as one prompt's worth of text; the rest
    /// is dropped so a pasted logfile does not sit in memory for the session's
    /// whole lifetime.
    static let maxPromptLength = 400
    /// Distinct files/commands kept per session. Sessions that touch
    /// thousands of paths are real, but the panel shows a top ten, and every
    /// session ever recorded stays in memory once indexed.
    static let maxFootprints = 60
    /// Same reasoning for turns: keep the expensive ones, count the rest.
    static let maxTurns = 50

    public static func scan(file: URL, sessionId: String? = nil) -> SessionUsage? {
        scan(file: file, sessionId: sessionId, from: nil).session
    }

    /// How far a scan got through a transcript, and everything it had added up
    /// by then.
    ///
    /// Claude Code only ever appends to a transcript, so a file that has grown
    /// since can be read on from here rather than from the top. For a live
    /// session that is the difference between re-reading two hundred
    /// megabytes on every poll and reading the few kilobytes it gained.
    struct Checkpoint: Sendable {
        /// Byte offset just past the last complete line consumed.
        let offset: UInt64
        fileprivate let state: ScanState
    }

    /// The same scan, resumable: picks up at `checkpoint` when given one, and
    /// hands back a checkpoint for the next pass to pick up from.
    static func scan(
        file: URL, sessionId: String?, from checkpoint: Checkpoint?
    ) -> (session: SessionUsage?, checkpoint: Checkpoint?) {
        guard let reader = LineReader(url: file, offset: checkpoint?.offset ?? 0) else {
            return (nil, nil)
        }
        var state = checkpoint?.state ?? ScanState(
            id: sessionId ?? file.deletingPathExtension().lastPathComponent,
            transcriptPath: file.path)

        let tail = reader.forEachLine { line in
            state.consume(line)
        }
        let resumable = Checkpoint(offset: reader.consumedOffset, state: state)

        // Text after the last newline may be a line Claude Code is halfway
        // through writing. It stays out of the checkpoint so the next pass
        // reads it whole, but it still counts now, in case it was complete
        // and merely unterminated.
        if !tail.isEmpty { state.consume(tail) }
        return (state.finish(), resumable)
    }
}

// MARK: - Scan state

private struct ScanState: Sendable {
    let id: String
    let transcriptPath: String

    var projectPath = ""
    var customTitle: String?
    var firstPrompt: String?
    var startedAt: Date?
    var lastActivityAt: Date?
    var usage = TokenUsage()
    var models: [String] = []

    var turns: [PromptTurn] = []
    var currentTurn: Int?
    var hourly: [Date: TokenUsage] = [:]
    /// Timestamp of the line being consumed, so `consumeAssistant` can bucket
    /// without re-parsing it.
    var lineDate: Date?

    /// Responses already counted, so the per-content-block duplicate lines do
    /// not each add their copy of the same `usage` block.
    var seenMessages = Set<String>()
    /// Unique API responses so far. Doubles as "how many later requests will
    /// re-read whatever is in the context right now".
    var requestCount = 0

    /// tool_use_id → what it was addressing, until its result arrives.
    var pendingTools: [String: (tool: String, key: String)] = [:]
    var footprints: [String: FootprintAccumulator] = [:]

    init(id: String, transcriptPath: String) {
        self.id = id
        self.transcriptPath = transcriptPath
    }

    mutating func consume(_ line: Data) {
        // Attachment lines are both the most numerous and the largest thing in
        // a transcript, and none of them carry usage. Skipping them before the
        // JSON parser sees them is most of this scanner's speed.
        guard TranscriptMarkers.mayMatter(line),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String
        else { return }

        if projectPath.isEmpty, let cwd = object["cwd"] as? String { projectPath = cwd }
        lineDate = (object["timestamp"] as? String).flatMap(TranscriptDate.parse)
        if let date = lineDate {
            if startedAt == nil { startedAt = date }
            lastActivityAt = date
        }

        switch type {
        case "custom-title":
            if let title = object["customTitle"] as? String, !title.isEmpty {
                customTitle = title
            }
        case "user":
            consumeUser(object)
        case "assistant":
            consumeAssistant(object)
        default:
            break
        }
    }

    // MARK: User lines

    private mutating func consumeUser(_ object: [String: Any]) {
        let message = object["message"] as? [String: Any]
        let content = message?["content"]

        if let blocks = content as? [[String: Any]] {
            let results = blocks.filter { $0["type"] as? String == "tool_result" }
            if !results.isEmpty {
                results.forEach { consumeToolResult($0) }
                return
            }
        }

        guard let text = Self.promptText(from: content), !text.isEmpty else { return }
        let isSynthetic = (object["isMeta"] as? Bool == true) || Self.looksSynthetic(text)
        let at = lineDate ?? Date()
        // Namespaced by session: turn ids end up in one list across many
        // sessions, and the positional fallback would collide immediately.
        let turnId = (object["promptId"] as? String)
            ?? (object["uuid"] as? String)
            ?? "\(id)-\(turns.count)"

        if !isSynthetic, firstPrompt == nil { firstPrompt = text }
        turns.append(PromptTurn(
            id: turnId,
            prompt: String(text.prefix(TranscriptScanner.maxPromptLength)),
            at: at,
            isSynthetic: isSynthetic))
        currentTurn = turns.count - 1
    }

    private mutating func consumeToolResult(_ block: [String: Any]) {
        guard let useId = block["tool_use_id"] as? String,
              let pending = pendingTools.removeValue(forKey: useId) else { return }
        let tokens = Self.estimateTokens(of: block["content"])
        guard tokens > 0 else { return }

        let key = "\(pending.tool)\u{1}\(pending.key)"
        var accumulator = footprints[key]
            ?? FootprintAccumulator(tool: pending.tool, key: pending.key)
        accumulator.occurrences += 1
        accumulator.directTokens += tokens
        if let date = lineDate, date > accumulator.lastAt { accumulator.lastAt = date }
        // Carried cost is `tokens × (requests that came after)`, which is not
        // knowable until the file ends. Bank the two running sums it factors
        // into instead of keeping every event.
        accumulator.sumTokens += tokens
        // `requestCount` here is the number of responses already made,
        // including the one that asked for this result — so the requests that
        // will re-read it are exactly the ones still to come.
        accumulator.sumTokensTimesIndex += tokens * requestCount
        footprints[key] = accumulator
    }

    // MARK: Assistant lines

    private mutating func consumeAssistant(_ object: [String: Any]) {
        guard let message = object["message"] as? [String: Any] else { return }
        let model = message["model"] as? String

        // Tool calls live on the individual content-block lines, so they are
        // collected on every line — unlike usage, which is deduplicated below.
        if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks where block["type"] as? String == "tool_use" {
                guard let useId = block["id"] as? String else { continue }
                let tool = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any] ?? [:]
                pendingTools[useId] = (
                    tool: tool, key: Self.footprintKey(tool: tool, input: input))
                if let turn = currentTurn { turns[turn].toolCalls += 1 }
            }
        }

        // One API response, many lines, one `usage` block repeated on each.
        guard let messageId = message["id"] as? String else { return }
        guard seenMessages.insert(messageId).inserted else { return }
        guard let raw = message["usage"] as? [String: Any] else { return }

        var response = TokenUsage(
            input: raw["input_tokens"] as? Int ?? 0,
            output: raw["output_tokens"] as? Int ?? 0,
            cacheWrite: raw["cache_creation_input_tokens"] as? Int ?? 0,
            cacheRead: raw["cache_read_input_tokens"] as? Int ?? 0,
            requests: 1)
        response.costUsd = ModelPricing.forModel(model).cost(response)

        usage += response
        requestCount += 1
        if let date = lineDate {
            let hour = Date(timeIntervalSinceReferenceDate:
                (date.timeIntervalSinceReferenceDate / 3600).rounded(.down) * 3600)
            hourly[hour, default: TokenUsage()] += response
        }
        if let model, !models.contains(model) { models.append(model) }
        // Sidechain (subagent) responses have no prompt of their own; they
        // belong to whatever turn spawned them, which is the current one.
        if let turn = currentTurn { turns[turn].usage += response }
    }

    // MARK: Finish

    mutating func finish() -> SessionUsage? {
        guard requestCount > 0 else { return nil }
        let started = startedAt ?? Date()
        let last = lastActivityAt ?? started

        let resolved = footprints.values
            .map { $0.materialize(totalRequests: requestCount) }
            .sorted { $0.totalTokens > $1.totalTokens }
            .prefix(TranscriptScanner.maxFootprints)

        let ranked = turns
            .filter { !$0.usage.isEmpty }
            .sorted { $0.usage.total > $1.usage.total }
            .prefix(TranscriptScanner.maxTurns)

        let title = customTitle
            ?? firstPrompt.map(Self.titleize)
            ?? URL(fileURLWithPath: projectPath).lastPathComponent

        return SessionUsage(
            id: id,
            projectPath: projectPath,
            title: title.isEmpty ? "Session \(id.prefix(8))" : title,
            startedAt: started,
            lastActivityAt: last,
            usage: usage,
            models: models,
            turns: Array(ranked),
            promptCount: turns.filter { !$0.isSynthetic }.count,
            footprints: Array(resolved),
            hourly: hourly.map { HourBucket(hour: $0.key, usage: $0.value) }
                .sorted { $0.hour < $1.hour },
            transcriptPath: transcriptPath)
    }

    // MARK: Helpers

    /// A user line is a prompt when it carries text. Content arrives either as
    /// a bare string or as blocks, depending on whether anything was attached.
    static func promptText(from content: Any?) -> String? {
        if let text = content as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Claude Code writes several kinds of machine-authored turn into the same
    /// `user` slot as a typed prompt. They cost real tokens, so they stay in
    /// the totals — but a list titled "your most expensive prompts" that is
    /// topped by a slash-command echo is useless, so they are flagged.
    static func looksSynthetic(_ text: String) -> Bool {
        let markers = [
            "<command-name>", "<local-command-stdout>", "<local-command-caveat>",
            "<task-notification>", "<bash-input>", "<system-reminder>",
            "[Request interrupted", "Caveat: The messages below",
        ]
        return markers.contains { text.hasPrefix($0) }
    }

    static func titleize(_ prompt: String) -> String {
        let collapsed = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 60 else { return collapsed }
        return String(collapsed.prefix(60)) + "…"
    }

    /// What a tool call was *about*, so repeated work on the same target adds
    /// up instead of scattering across a hundred anonymous rows.
    static func footprintKey(tool: String, input: [String: Any]) -> String {
        if let path = input["file_path"] as? String ?? input["notebook_path"] as? String {
            return path
        }
        if let command = input["command"] as? String {
            return String(command.prefix(60))
        }
        if let url = input["url"] as? String { return url }
        if let pattern = input["pattern"] as? String {
            let path = input["path"] as? String
            return path.map { "\(pattern) in \($0)" } ?? pattern
        }
        if let query = input["query"] as? String { return String(query.prefix(60)) }
        if let description = input["description"] as? String { return description }
        // Screenshot and browser-control tools address a mode rather than a
        // path; the mode is what distinguishes an expensive call from a cheap
        // one, so it earns its own row.
        if let action = input["action"] as? String { return "\(tool) \(action)" }
        return tool
    }

    /// Tool results are not billed separately — they enter the next request as
    /// ordinary input — so there is no recorded token count for them. Four
    /// characters per token is the standard English approximation and is close
    /// enough to rank one file against another, which is all this is for.
    static func estimateTokens(of content: Any?) -> Int {
        if let text = content as? String { return text.count / 4 }
        guard let blocks = content as? [Any] else { return 0 }
        var total = 0
        for block in blocks {
            guard let block = block as? [String: Any] else { continue }
            switch block["type"] as? String {
            case "text":
                total += (block["text"] as? String ?? "").count / 4
            case "image":
                // No dimensions are recorded, and image tokens scale with area.
                // A mid-size screenshot is the honest middle of the range.
                total += 1_200
            default:
                break
            }
        }
        return total
    }
}

/// Running sums for one footprint. Carried cost needs the session's final
/// request count, so it is resolved at the end rather than per event.
private struct FootprintAccumulator: Sendable {
    let tool: String
    let key: String
    var occurrences = 0
    var directTokens = 0
    var sumTokens = 0
    var sumTokensTimesIndex = 0
    var lastAt = Date.distantPast

    func materialize(totalRequests: Int) -> ContextFootprint {
        // Σ tokensᵢ × (totalRequests − atRequestᵢ), expanded so the individual
        // events never had to be kept.
        let carried = max(0, sumTokens * totalRequests - sumTokensTimesIndex)
        return ContextFootprint(
            key: key, tool: tool, occurrences: occurrences,
            directTokens: directTokens, carriedTokens: carried, lastAt: lastAt)
    }
}

// MARK: - Byte-level prefilter

enum TranscriptMarkers {
    private static let user = Array(#""type":"user""#.utf8)
    private static let assistant = Array(#""type":"assistant""#.utf8)
    private static let title = Array(#""type":"custom-title""#.utf8)

    /// True when a line could possibly carry usage, a prompt, or a tool
    /// result. Attachment and bookkeeping lines — the bulk of a transcript by
    /// bytes — are rejected here without ever reaching `JSONSerialization`.
    static func mayMatter(_ line: Data) -> Bool {
        line.contains(subsequence: assistant)
            || line.contains(subsequence: user)
            || line.contains(subsequence: title)
    }
}

extension Data {
    /// `memmem`, which is vectorised. The needles are short, but every line of
    /// every transcript passes through here up to three times.
    func contains(subsequence needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        return withUnsafeBytes { raw -> Bool in
            needle.withUnsafeBytes { pattern -> Bool in
                memmem(raw.baseAddress, raw.count, pattern.baseAddress, pattern.count) != nil
            }
        }
    }
}

// MARK: - Dates

enum TranscriptDate {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    private static let lock = NSLock()

    static func parse(_ string: String) -> Date? {
        if let date = parseUTC(string) { return date }
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: string) ?? plain.date(from: string)
    }

    /// The one shape Claude Code writes, `2026-11-02T16:21:33.123Z`, read
    /// without a formatter.
    ///
    /// Every relevant line carries a timestamp, so this runs millions of times
    /// over a first index, and the formatters behind the lock serialised the
    /// scans that are meant to run across every core. Anything else — an
    /// offset, a missing `Z` — falls through to them.
    static func parseUTC(_ string: String) -> Date? {
        string.utf8.withContiguousStorageIfAvailable { bytes -> Date? in
            guard bytes.count >= 20, bytes.last == UInt8(ascii: "Z"),
                  bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
                  bytes[10] == UInt8(ascii: "T"),
                  bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":")
            else { return nil }

            func number(_ range: Range<Int>) -> Int? {
                var value = 0
                for index in range {
                    let digit = Int(bytes[index]) - 48
                    guard (0...9).contains(digit) else { return nil }
                    value = value * 10 + digit
                }
                return value
            }
            guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
                  let hour = number(11..<13), let minute = number(14..<16),
                  let second = number(17..<19),
                  (1...12).contains(month), (1...31).contains(day),
                  hour < 24, minute < 60, second < 61
            else { return nil }

            var fraction = 0.0
            let end = bytes.count - 1
            if end > 19 {
                // Up to nine digits, read as an integer and scaled once so the
                // result rounds the same way a formatter's would.
                guard bytes[19] == UInt8(ascii: "."), end > 20, end - 20 <= 9,
                      let digits = number(20..<end)
                else { return nil }
                var scale = 1.0
                for _ in 20..<end { scale *= 10 }
                fraction = Double(digits) / scale
            }

            // Days since 1970-01-01 in the proleptic Gregorian calendar
            // (Howard Hinnant's `days_from_civil`).
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yearOfEra = y - era * 400
            let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            let days = era * 146_097 + dayOfEra - 719_468

            let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second
            return Date(timeIntervalSince1970: Double(seconds) + fraction)
        } ?? nil
    }
}

// MARK: - Line reading

/// Reads a file one line at a time without ever holding more than a chunk.
///
/// Transcripts run to hundreds of megabytes; `String(contentsOf:)` on the
/// largest of them would allocate the whole thing twice over just to split it.
final class LineReader {
    private let handle: FileHandle
    private let chunkSize = 1 << 20
    /// Byte offset just past the last newline handed out, which is where a
    /// later reader can start without seeing any line twice.
    private(set) var consumedOffset: UInt64

    init?(url: URL, offset: UInt64 = 0) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        if offset > 0 {
            do {
                try handle.seek(toOffset: offset)
            } catch {
                try? handle.close()
                return nil
            }
        }
        self.handle = handle
        self.consumedOffset = offset
    }

    deinit { try? handle.close() }

    /// Calls `body` with every complete line, then returns whatever followed
    /// the last newline: nothing for a file that ends in one, otherwise a line
    /// that may still be being written.
    @discardableResult
    func forEachLine(_ body: (Data) -> Void) -> Data {
        var buffer = Data()
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            // What was carried over from the last chunk was searched then and
            // holds no newline, so only the new bytes need looking at.
            let carried = buffer.count
            buffer.append(chunk)
            let consumed = buffer.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                var lineStart = 0
                var searchFrom = carried
                while searchFrom < raw.count,
                      let hit = memchr(base + searchFrom, 0x0A, raw.count - searchFrom) {
                    let end = base.distance(to: UnsafeRawPointer(hit))
                    if end > lineStart { body(Data(bytes: base + lineStart, count: end - lineStart)) }
                    lineStart = end + 1
                    searchFrom = lineStart
                }
                return lineStart
            }
            consumedOffset += UInt64(consumed)
            // Compacted once per chunk. Dropping each line off the front as it
            // was read moved every byte behind it, which made a chunk of short
            // lines cost its length times its line count — on a first index,
            // minutes of CPU spent on nothing but memmove.
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + consumed))
        }
        return buffer
    }
}
