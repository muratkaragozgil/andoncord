import XCTest
@testable import AndonKit

/// The index and the windowed views built on it.
///
/// The clipping is the part worth guarding: a session that started yesterday
/// and is still running must not pour yesterday's tokens into "today", or
/// every number derived from a window — the spend beside each quota card, the
/// calibration that scales the estimates — is quietly wrong.
@MainActor
final class UsageLedgerTests: XCTestCase {
    var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("andon-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: sandbox.appendingPathComponent(".claude/projects"),
            withIntermediateDirectories: true)
        Paths.homeOverride = sandbox
    }

    override func tearDownWithError() throws {
        Paths.homeOverride = nil
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    /// Writes a transcript with one response per hour, counting back from now.
    /// `file` places it somewhere other than `<session>.jsonl` under the
    /// project, which is where subagents' transcripts live.
    private func writeTranscript(
        project: String, session: String, cwd: String,
        hoursAgo: [Int], outputPerResponse: Int = 1_000, file: String? = nil
    ) throws {
        let target = sandbox
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(project)
            .appendingPathComponent(file ?? "\(session).jsonl")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let messagePrefix = file ?? session

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = []
        for (index, hours) in hoursAgo.enumerated() {
            let stamp = formatter.string(from: Date().addingTimeInterval(-Double(hours) * 3600))
            lines.append("""
                {"type":"user","cwd":"\(cwd)","timestamp":"\(stamp)","promptId":"p\(index)",\
                "message":{"role":"user","content":"prompt \(index)"}}
                """)
            lines.append("""
                {"type":"assistant","cwd":"\(cwd)","timestamp":"\(stamp)",\
                "message":{"id":"\(messagePrefix)-m\(index)","model":"claude-opus-5",\
                "content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":0,\
                "output_tokens":\(outputPerResponse),"cache_creation_input_tokens":0,\
                "cache_read_input_tokens":0}}}
                """)
        }
        try lines.joined(separator: "\n").write(to: target, atomically: true, encoding: .utf8)
    }

    func testIndexesEveryProjectDirectory() async throws {
        try writeTranscript(
            project: "-work-alpha", session: "s1", cwd: "/work/alpha", hoursAgo: [1, 2])
        try writeTranscript(
            project: "-work-beta", session: "s2", cwd: "/work/beta", hoursAgo: [1])

        let ledger = UsageLedger()
        await ledger.reindexNow()

        XCTAssertEqual(ledger.sessions.count, 2)
        XCTAssertEqual(Set(ledger.projects().map(\.name)), ["alpha", "beta"])
        XCTAssertEqual(ledger.total(since: .distantPast).output, 3_000)
    }

    /// Subagents write their own transcripts under `<session>/subagents/`,
    /// workflow agents a level further down, and on a heavy day that is most
    /// of the spend. It has to be counted, and counted against the session
    /// that spawned it rather than as a row per agent.
    func testSubagentTranscriptsBillToTheSessionThatSpawnedThem() async throws {
        try writeTranscript(
            project: "-work-alpha", session: "s1", cwd: "/work/alpha", hoursAgo: [1])
        try writeTranscript(
            project: "-work-alpha", session: "s1", cwd: "/work/alpha", hoursAgo: [1, 2],
            file: "s1/subagents/agent-a1.jsonl")
        try writeTranscript(
            project: "-work-alpha", session: "s1", cwd: "/work/alpha", hoursAgo: [1],
            outputPerResponse: 4_000, file: "s1/subagents/workflows/wf_1/agent-b2.jsonl")

        let ledger = UsageLedger()
        await ledger.reindexNow()

        XCTAssertEqual(ledger.sessions.count, 1)
        let session = try XCTUnwrap(ledger.session(id: "s1"))
        XCTAssertEqual(session.usage.output, 1_000 + 2_000 + 4_000)
        XCTAssertEqual(ledger.total(since: .distantPast).output, 7_000)
        // Only the parent's own prompt is a prompt; the subagents' briefs are not.
        XCTAssertEqual(session.turns.map(\.prompt), ["prompt 0"])
    }

    /// The window views must count only what happened inside the window, not
    /// every token of every session that happens to overlap it.
    func testWindowedTotalsAreClippedNotWhole() async throws {
        try writeTranscript(
            project: "-work-alpha", session: "s1", cwd: "/work/alpha",
            hoursAgo: [30, 20, 1])

        let ledger = UsageLedger()
        await ledger.reindexNow()

        XCTAssertEqual(ledger.total(since: .distantPast).output, 3_000)
        // Only the most recent response falls inside a five-hour window, even
        // though the session it belongs to started well outside one.
        let recent = ledger.total(since: Date().addingTimeInterval(-5 * 3600))
        XCTAssertEqual(recent.output, 1_000)
        XCTAssertEqual(recent.requests, 1)
    }

    func testSessionsOutsideTheWindowDropOutEntirely() async throws {
        try writeTranscript(
            project: "-work-alpha", session: "s1", cwd: "/work/alpha", hoursAgo: [50])
        try writeTranscript(
            project: "-work-beta", session: "s2", cwd: "/work/beta", hoursAgo: [1])

        let ledger = UsageLedger()
        await ledger.reindexNow()

        XCTAssertEqual(ledger.sessions.count, 2)
        let recent = ledger.sessions(since: Date().addingTimeInterval(-5 * 3600))
        XCTAssertEqual(recent.map(\.projectName), ["beta"])
    }

    func testProjectsAreRankedBySpend() async throws {
        try writeTranscript(
            project: "-work-alpha", session: "s1", cwd: "/work/alpha",
            hoursAgo: [1], outputPerResponse: 500)
        try writeTranscript(
            project: "-work-beta", session: "s2", cwd: "/work/beta",
            hoursAgo: [1], outputPerResponse: 5_000)

        let ledger = UsageLedger()
        await ledger.reindexNow()

        XCTAssertEqual(ledger.projects().map(\.name), ["beta", "alpha"])
    }

    /// A second pass must not re-read files that have not moved — that is the
    /// whole reason a relaunch is instant instead of a minute of disk.
    func testUnchangedFilesAreServedFromTheCache() async throws {
        try writeTranscript(
            project: "-work-alpha", session: "s1", cwd: "/work/alpha", hoursAgo: [1])

        let ledger = UsageLedger()
        await ledger.reindexNow()
        let first = ledger.indexedAt

        await ledger.reindexNow()
        XCTAssertEqual(ledger.sessions.count, 1)
        XCTAssertNotNil(first)
        // The index file is written on the pass that found changes, and left
        // alone by one that found none.
        XCTAssertTrue(FileManager.default.fileExists(atPath: Paths.usageIndex.path))
    }

    func testCacheSurvivesARelaunch() async throws {
        try writeTranscript(
            project: "-work-alpha", session: "s1", cwd: "/work/alpha", hoursAgo: [1])

        let first = UsageLedger()
        await first.reindexNow()
        XCTAssertEqual(first.sessions.count, 1)

        // A fresh ledger loads the index before scanning anything, so the
        // board has numbers on it the instant the app opens.
        let second = UsageLedger()
        second.start()
        XCTAssertEqual(second.sessions.count, 1)
        second.stop()
    }

    /// Carried cost belongs to a session as a whole and cannot be sliced by
    /// time, so a footprint is included or excluded whole — but on when it was
    /// last touched, not on whether its session happens to still be alive.
    func testFootprintsOutsideTheWindowAreLeftOut() async throws {
        let directory = sandbox
            .appendingPathComponent(".claude/projects/-work-alpha")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let old = formatter.string(from: Date().addingTimeInterval(-40 * 3600))
        let recent = formatter.string(from: Date().addingTimeInterval(-1800))
        let payload = String(repeating: "x", count: 20_000)

        // One session, one file read two days ago and another half an hour ago.
        let lines = [
            #"{"type":"user","cwd":"/work/alpha","timestamp":"\#(old)","promptId":"p0","message":{"role":"user","content":"go"}}"#,
            #"{"type":"assistant","cwd":"/work/alpha","timestamp":"\#(old)","message":{"id":"m0","model":"claude-opus-5","content":[{"type":"tool_use","id":"t0","name":"Read","input":{"file_path":"/work/alpha/old.swift"}}],"usage":{"input_tokens":0,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#,
            #"{"type":"user","cwd":"/work/alpha","timestamp":"\#(old)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t0","content":"\#(payload)"}]}}"#,
            #"{"type":"assistant","cwd":"/work/alpha","timestamp":"\#(recent)","message":{"id":"m1","model":"claude-opus-5","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/work/alpha/new.swift"}}],"usage":{"input_tokens":0,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#,
            #"{"type":"user","cwd":"/work/alpha","timestamp":"\#(recent)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"\#(payload)"}]}}"#,
            #"{"type":"assistant","cwd":"/work/alpha","timestamp":"\#(recent)","message":{"id":"m2","model":"claude-opus-5","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":0,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#,
        ]
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("s1.jsonl"),
            atomically: true, encoding: .utf8)

        let ledger = UsageLedger()
        await ledger.reindexNow()

        XCTAssertEqual(
            Set(ledger.costliestFootprints(since: .distantPast).map(\.key)),
            ["/work/alpha/old.swift", "/work/alpha/new.swift"])
        XCTAssertEqual(
            ledger.costliestFootprints(since: Date().addingTimeInterval(-5 * 3600)).map(\.key),
            ["/work/alpha/new.swift"])
    }

    func testMissingTranscriptDirectoryIsReportedNotCrashed() async throws {
        try FileManager.default.removeItem(at: sandbox.appendingPathComponent(".claude/projects"))
        let ledger = UsageLedger()
        await ledger.reindexNow()
        XCTAssertTrue(ledger.sessions.isEmpty)
        XCTAssertNotNil(ledger.failure)
    }
}
