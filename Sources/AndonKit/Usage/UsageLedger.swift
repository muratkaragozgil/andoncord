import Foundation
import Observation

/// The token book: every Claude Code session on this Mac, what it cost, and
/// where the cost went.
///
/// Claude Code already writes everything needed for this — it just never adds
/// it up. `~/.claude/projects/<mangled-cwd>/<session>.jsonl` holds one line per
/// content block with the API's `usage` attached, which is the only record
/// anywhere of what an individual prompt or file read actually cost. The
/// ledger indexes those files, keeps the result on disk so a relaunch is
/// instant, and re-reads only what changed.
///
/// Nothing here talks to the network, and nothing is written outside
/// `~/.andoncord`.
@Observable
@MainActor
public final class UsageLedger {
    public private(set) var sessions: [SessionUsage] = []
    /// True during the first full index, which on a year of transcripts takes
    /// long enough that the panel needs to say so rather than look empty.
    public private(set) var isIndexing = false
    public private(set) var indexedAt: Date?
    /// Set when the transcripts directory cannot be read at all, so a blank
    /// board is explainable instead of mysterious.
    public private(set) var failure: String?

    /// Called after every pass. The app uses it to revisit anything that was
    /// computed against an index that had not finished loading yet.
    @ObservationIgnored
    public var onIndexed: (() -> Void)?

    @ObservationIgnored
    private var cache: [String: IndexEntry] = [:]
    /// Where the last scan of each live transcript stopped, so the next pass
    /// reads only what was appended. Memory only: a checkpoint carries the
    /// scanner's whole running state, which is cheap to keep for the handful
    /// of sessions in use and pointless for the thousands that are finished.
    @ObservationIgnored
    private var checkpoints: [String: TranscriptScanner.Checkpoint] = [:]
    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var ticker: Task<Void, Never>?
    @ObservationIgnored
    private var isDirty = false
    @ObservationIgnored
    private var lastSavedAt: Date?

    /// How often the transcript directory is re-checked. Only files whose
    /// size or mtime moved are re-read, so this is a `stat` per transcript —
    /// cheap enough to keep the board close to live without a watcher on
    /// twenty directories.
    private static let pollInterval: Duration = .seconds(20)
    /// The index runs to tens of megabytes and any live session changes it on
    /// every poll. It is entirely derived, so it is written at most this often
    /// (and on quit): a crash in between costs a re-read of what changed.
    private static let saveInterval: TimeInterval = 300
    /// Transcripts touched within this long keep a checkpoint.
    private nonisolated static let checkpointHorizon: TimeInterval = 2 * 3600

    public init() {}

    // MARK: - Lifecycle

    public func start() {
        loadCache()
        refresh()
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    public func stop() {
        ticker?.cancel()
        ticker = nil
        refreshTask?.cancel()
        refreshTask = nil
        // Whatever the save interval held back, so a relaunch starts from it.
        if isDirty {
            isDirty = false
            Self.write(CacheFile(version: Self.cacheVersion, entries: cache))
        }
    }

    /// Re-index anything that changed. Safe to call from a hook event — a
    /// refresh already in flight is left to finish rather than restarted.
    public func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            await self?.reindexNow()
            self?.refreshTask = nil
        }
    }

    /// The same pass, awaited. Separate from `refresh()` so a caller that
    /// needs the result — a test, or a first load that must finish before
    /// anything is drawn — can wait for it.
    public func reindexNow() async {
        let known = cache
        if sessions.isEmpty { isIndexing = true }
        let result = await Self.reindex(known: known, checkpoints: checkpoints)
        cache = result.entries
        checkpoints = result.checkpoints
        // Reassigned only when something moved: every view reading the ledger
        // redraws on assignment, and most polls change nothing.
        if result.changed || sessions.isEmpty {
            sessions = Self.assemble(result.entries.values)
        }
        failure = result.failure
        isIndexing = false
        indexedAt = Date()
        if result.changed { isDirty = true }
        await saveCacheIfDue()
        onIndexed?()
    }

    // MARK: - Derived views

    /// Sessions whose activity falls inside a window, with their usage clipped
    /// to it. A session that started yesterday and is still running must not
    /// contribute yesterday's tokens to "today".
    public func sessions(since cutoff: Date) -> [SessionUsage] {
        sessions.compactMap { session in
            guard session.lastActivityAt >= cutoff else { return nil }
            let inWindow = session.hourly.filter { $0.hour >= cutoff }
            guard !inWindow.isEmpty else { return nil }
            var clipped = session
            clipped.hourly = inWindow
            clipped.usage = inWindow.reduce(TokenUsage()) { $0 + $1.usage }
            return clipped
        }
    }

    /// Summed straight off the buckets rather than through `sessions(since:)`.
    ///
    /// Views call this several times per redraw — two quota cards, the pill,
    /// the strip — so it does no work beyond the addition itself.
    public func total(since cutoff: Date) -> TokenUsage {
        sessions.reduce(TokenUsage()) { running, session in
            guard session.lastActivityAt >= cutoff else { return running }
            return running + session.hourly
                .filter { $0.hour >= cutoff }
                .reduce(TokenUsage()) { $0 + $1.usage }
        }
    }

    /// Spend inside an arbitrary interval, including ones that have already
    /// closed.
    ///
    /// Needed to pair a quota reading with the spend that produced it. That
    /// reading may be days old, and "the last five hours" is then the wrong
    /// five hours entirely — the window it described has to be reconstructed
    /// from its own reset time.
    public func total(in interval: Range<Date>) -> TokenUsage {
        sessions.reduce(TokenUsage()) { running, session in
            running + session.hourly
                .filter { interval.contains($0.hour) }
                .reduce(TokenUsage()) { $0 + $1.usage }
        }
    }

    /// Sessions grouped by the directory they ran in, biggest spend first.
    public func projects(since cutoff: Date? = nil) -> [ProjectUsage] {
        let scope = cutoff.map { sessions(since: $0) } ?? sessions
        var grouped: [String: [SessionUsage]] = [:]
        for session in scope {
            let path = session.projectPath.isEmpty ? "Unknown" : session.projectPath
            grouped[path, default: []].append(session)
        }
        return grouped.map { path, sessions in
            ProjectUsage(
                path: path,
                usage: sessions.reduce(TokenUsage()) { $0 + $1.usage },
                sessions: sessions.sorted { $0.usage.total > $1.usage.total },
                lastActivityAt: sessions.map(\.lastActivityAt).max() ?? .distantPast)
        }
        .sorted { $0.usage.total > $1.usage.total }
    }

    /// The heaviest single prompts across everything in the window, each
    /// carrying the session it belongs to so a row can name the project.
    public func costliestPrompts(since cutoff: Date, limit: Int = 12) -> [(SessionUsage, PromptTurn)] {
        sessions(since: cutoff)
            .flatMap { session in
                session.turns
                    .filter { !$0.isSynthetic && $0.at >= cutoff }
                    .map { (session, $0) }
            }
            .sorted { $0.1.usage.total > $1.1.usage.total }
            .prefix(limit)
            .map { $0 }
    }

    /// The heaviest context contributors — files re-read, commands whose
    /// output never left the window — merged across sessions.
    public func costliestFootprints(since cutoff: Date, limit: Int = 12) -> [ContextFootprint] {
        var merged: [String: ContextFootprint] = [:]
        for session in sessions(since: cutoff) {
            for footprint in session.footprints where footprint.lastAt >= cutoff {
                let id = "\(footprint.tool)\u{1}\(footprint.key)"
                if var existing = merged[id] {
                    existing.occurrences += footprint.occurrences
                    existing.directTokens += footprint.directTokens
                    existing.carriedTokens += footprint.carriedTokens
                    existing.lastAt = max(existing.lastAt, footprint.lastAt)
                    merged[id] = existing
                } else {
                    merged[id] = footprint
                }
            }
        }
        return merged.values
            .sorted { $0.totalTokens > $1.totalTokens }
            .prefix(limit)
            .map { $0 }
    }

    /// Hour-by-hour totals across every session, oldest first. The basis for
    /// burn rate and the activity strip.
    public func hourlyTotals(since cutoff: Date) -> [HourBucket] {
        var merged: [Date: TokenUsage] = [:]
        for session in sessions where session.lastActivityAt >= cutoff {
            for bucket in session.hourly where bucket.hour >= cutoff {
                merged[bucket.hour, default: TokenUsage()] += bucket.usage
            }
        }
        return merged.map { HourBucket(hour: $0.key, usage: $0.value) }
            .sorted { $0.hour < $1.hour }
    }

    public func session(id: String) -> SessionUsage? {
        sessions.first { $0.id == id }
    }

    // MARK: - Indexing

    struct IndexEntry: Codable, Sendable {
        var size: Int
        var modified: Date
        var session: SessionUsage?
        /// A subagent's own transcript, billed to the session that spawned it.
        /// Optional so an index written before subagents were counted still
        /// decodes; everything in it was a top-level transcript.
        var isSubagent: Bool?
    }

    /// One row per conversation, with every subagent it spawned folded in.
    ///
    /// The parent's own transcript supplies the title, the prompts and the
    /// footprints; a subagent adds its spend and nothing else, because its
    /// "prompt" is the brief it was handed, not something anyone typed.
    nonisolated static func assemble(_ entries: some Sequence<IndexEntry>) -> [SessionUsage] {
        var byId: [String: SessionUsage] = [:]
        var subagents: [SessionUsage] = []
        for entry in entries {
            guard let session = entry.session else { continue }
            if entry.isSubagent == true {
                subagents.append(session)
            } else {
                byId[session.id] = session
            }
        }
        for subagent in subagents {
            if var parent = byId[subagent.id] {
                parent.absorb(subagent)
                byId[subagent.id] = parent
            } else {
                // The parent transcript is gone but the spend still happened.
                byId[subagent.id] = subagent
            }
        }
        return byId.values.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// Every transcript under one project directory, and the session each one
    /// bills to.
    ///
    /// Subagents do not write into their parent's transcript. Each one — and
    /// every agent a workflow fans out — gets its own file under
    /// `<session>/subagents/`, and on a day of workflows that is most of the
    /// spend: reading only the top level once had the board at half the
    /// weekly figure Claude itself was showing.
    private nonisolated static func transcripts(
        in directory: URL
    ) -> [(url: URL, sessionId: String, isSubagent: Bool)] {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var found: [(url: URL, sessionId: String, isSubagent: Bool)] = []
        for child in children {
            if child.pathExtension == "jsonl" {
                found.append((child, child.deletingPathExtension().lastPathComponent, false))
                continue
            }
            let subagents = child.appendingPathComponent("subagents")
            guard let walker = fm.enumerator(
                at: subagents, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
            else { continue }
            for case let file as URL in walker where file.pathExtension == "jsonl" {
                found.append((file, child.lastPathComponent, true))
            }
        }
        return found
    }

    private struct ReindexResult: Sendable {
        var entries: [String: IndexEntry]
        var checkpoints: [String: TranscriptScanner.Checkpoint]
        var changed: Bool
        var failure: String?
    }

    /// A transcript whose size or mtime moved since it was last indexed.
    private struct StaleTranscript: Sendable {
        var path: String
        var url: URL
        var sessionId: String
        var isSubagent: Bool
        var size: Int
        var modified: Date
    }

    /// Walk the transcript tree and re-read only what moved.
    ///
    /// Runs off the main actor: a first index over a year of transcripts is
    /// gigabytes of JSON, and doing that on the main thread would freeze the
    /// notch panel for the duration.
    private nonisolated static func reindex(
        known: [String: IndexEntry],
        checkpoints: [String: TranscriptScanner.Checkpoint]
    ) async -> ReindexResult {
        await Task.detached(priority: .utility) { () -> ReindexResult in
            let root = Paths.claudeDir.appendingPathComponent("projects")
            guard let projectDirs = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey])
            else {
                return ReindexResult(
                    entries: known, checkpoints: [:], changed: false,
                    failure: "No transcripts at \(root.path)")
            }

            let horizon = Date().addingTimeInterval(-checkpointHorizon)
            var entries: [String: IndexEntry] = [:]
            var kept: [String: TranscriptScanner.Checkpoint] = [:]
            var stale: [StaleTranscript] = []

            for directory in projectDirs {
                for (file, sessionId, isSubagent) in transcripts(in: directory) {
                    let values = try? file.resourceValues(
                        forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let size = values?.fileSize ?? 0
                    let modified = values?.contentModificationDate ?? .distantPast

                    if let cached = known[file.path],
                       cached.size == size, cached.modified == modified {
                        entries[file.path] = cached
                        if modified > horizon, let checkpoint = checkpoints[file.path] {
                            kept[file.path] = checkpoint
                        }
                    } else {
                        stale.append(StaleTranscript(
                            path: file.path, url: file, sessionId: sessionId,
                            isSubagent: isSubagent, size: size, modified: modified))
                    }
                }
            }

            // The first index is gigabytes of JSON and the only moment this
            // could plausibly feel slow. Files are independent, so they are
            // scanned in parallel — but on half the cores, not all of them: a
            // first index that pins every core heats the machine and stalls
            // whatever the person is actually doing. After that first run this
            // list is normally a file or two — whichever sessions are live.
            if !stale.isEmpty {
                let width = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
                let scanned = await withTaskGroup(
                    of: (StaleTranscript, IndexEntry, TranscriptScanner.Checkpoint?).self
                ) { group in
                    var queue = stale.makeIterator()
                    for _ in 0..<width {
                        guard let item = queue.next() else { break }
                        group.addTask { scan(item, resuming: checkpoints[item.path]) }
                    }
                    var results: [(StaleTranscript, IndexEntry, TranscriptScanner.Checkpoint?)] = []
                    for await result in group {
                        results.append(result)
                        if let item = queue.next() {
                            group.addTask { scan(item, resuming: checkpoints[item.path]) }
                        }
                    }
                    return results
                }
                for (item, entry, checkpoint) in scanned {
                    entries[item.path] = entry
                    if item.modified > horizon, let checkpoint { kept[item.path] = checkpoint }
                }
            }

            // A transcript that disappeared drops out by omission, which is
            // still a change worth persisting.
            let changed = !stale.isEmpty || entries.count != known.count
            return ReindexResult(
                entries: entries, checkpoints: kept, changed: changed, failure: nil)
        }.value
    }

    /// One transcript, read on from its checkpoint when it has only grown
    /// since — which is how Claude Code writes them. One that shrank was
    /// rewritten, and is read again from the top.
    private nonisolated static func scan(
        _ item: StaleTranscript, resuming checkpoint: TranscriptScanner.Checkpoint?
    ) -> (StaleTranscript, IndexEntry, TranscriptScanner.Checkpoint?) {
        let resumable = checkpoint.flatMap { UInt64(item.size) >= $0.offset ? $0 : nil }
        let (session, next) = TranscriptScanner.scan(
            file: item.url, sessionId: item.sessionId, from: resumable)
        let entry = IndexEntry(
            size: item.size, modified: item.modified, session: session,
            isSubagent: item.isSubagent)
        return (item, entry, next)
    }

    // MARK: - Cache

    /// The index is expensive to build and entirely derived, so it lives in
    /// our own directory and is thrown away rather than migrated when its
    /// shape changes.
    private static let cacheVersion = 2

    private struct CacheFile: Codable, Sendable {
        var version: Int
        var entries: [String: IndexEntry]
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Paths.usageIndex),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              file.version == Self.cacheVersion
        else { return }
        cache = file.entries
        sessions = Self.assemble(file.entries.values)
    }

    /// Writes the index when it has changed and the last write is old enough.
    /// Encoding it is tens of megabytes of JSON, so that happens off the main
    /// actor — on it, the notch stuttered every time a live session moved.
    private func saveCacheIfDue() async {
        guard isDirty else { return }
        if let lastSavedAt, Date().timeIntervalSince(lastSavedAt) < Self.saveInterval { return }
        isDirty = false
        lastSavedAt = Date()
        let file = CacheFile(version: Self.cacheVersion, entries: cache)
        await Task.detached(priority: .utility) { Self.write(file) }.value
    }

    private nonisolated static func write(_ file: CacheFile) {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? Paths.ensureDirectories()
        try? data.write(to: Paths.usageIndex, options: .atomic)
    }
}
