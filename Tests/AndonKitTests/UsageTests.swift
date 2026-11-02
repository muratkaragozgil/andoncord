import XCTest
@testable import AndonKit

/// Transcript accounting.
///
/// The two things that decide whether the numbers on the board are true:
/// one API response must be counted once even though Claude Code writes it
/// across several lines, and a file's cost has to include the cache reads it
/// causes on every later request, not just the read that fetched it.
final class TranscriptScannerTests: XCTestCase {
    var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("andon-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    private func write(_ lines: [String], name: String = "session-a") throws -> URL {
        let url = sandbox.appendingPathComponent("\(name).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func assistant(
        messageId: String, model: String = "claude-opus-5", at: String,
        input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0,
        content: String = #"[{"type":"text","text":"ok"}]"#
    ) -> String {
        """
        {"type":"assistant","cwd":"/work/proj","timestamp":"\(at)","message":{"id":"\(messageId)",\
        "model":"\(model)","content":\(content),"usage":{"input_tokens":\(input),\
        "output_tokens":\(output),"cache_creation_input_tokens":\(cacheWrite),\
        "cache_read_input_tokens":\(cacheRead)}}}
        """
    }

    private func prompt(_ text: String, id: String, at: String) -> String {
        """
        {"type":"user","cwd":"/work/proj","timestamp":"\(at)","promptId":"\(id)",\
        "message":{"role":"user","content":"\(text)"}}
        """
    }

    // MARK: - Deduplication

    /// Claude Code writes one line per content block and repeats the identical
    /// `usage` object on each. Counting per line triples every total, which is
    /// the difference between a dashboard and a rumour.
    func testOneResponseSpanningManyLinesIsCountedOnce() throws {
        let url = try write([
            prompt("do the thing", id: "p1", at: "2026-08-25T10:00:00.000Z"),
            assistant(messageId: "msg_1", at: "2026-08-25T10:00:01.000Z",
                      input: 2, output: 400, cacheWrite: 600, cacheRead: 90_000,
                      content: #"[{"type":"thinking","thinking":"…"}]"#),
            assistant(messageId: "msg_1", at: "2026-08-25T10:00:02.000Z",
                      input: 2, output: 400, cacheWrite: 600, cacheRead: 90_000,
                      content: #"[{"type":"text","text":"ok"}]"#),
            assistant(messageId: "msg_1", at: "2026-08-25T10:00:03.000Z",
                      input: 2, output: 400, cacheWrite: 600, cacheRead: 90_000,
                      content: #"[{"type":"text","text":"more"}]"#),
        ])

        let session = try XCTUnwrap(TranscriptScanner.scan(file: url))
        XCTAssertEqual(session.usage.requests, 1)
        XCTAssertEqual(session.usage.output, 400)
        XCTAssertEqual(session.usage.cacheRead, 90_000)
        XCTAssertEqual(session.usage.total, 2 + 400 + 600 + 90_000)
    }

    func testDistinctResponsesAccumulate() throws {
        let url = try write([
            prompt("first", id: "p1", at: "2026-08-25T10:00:00.000Z"),
            assistant(messageId: "msg_1", at: "2026-08-25T10:00:01.000Z", output: 100),
            assistant(messageId: "msg_2", at: "2026-08-25T10:00:05.000Z", output: 250),
        ])
        let session = try XCTUnwrap(TranscriptScanner.scan(file: url))
        XCTAssertEqual(session.usage.requests, 2)
        XCTAssertEqual(session.usage.output, 350)
    }

    // MARK: - Attribution

    func testTokensAttachToThePromptThatCausedThem() throws {
        let url = try write([
            prompt("cheap question", id: "p1", at: "2026-08-25T10:00:00.000Z"),
            assistant(messageId: "msg_1", at: "2026-08-25T10:00:01.000Z", output: 100),
            prompt("expensive refactor", id: "p2", at: "2026-08-25T11:00:00.000Z"),
            assistant(messageId: "msg_2", at: "2026-08-25T11:00:01.000Z", output: 5_000),
            assistant(messageId: "msg_3", at: "2026-08-25T11:00:09.000Z", output: 3_000),
        ])

        let session = try XCTUnwrap(TranscriptScanner.scan(file: url))
        let top = try XCTUnwrap(session.costliestPrompts.first)
        XCTAssertEqual(top.prompt, "expensive refactor")
        XCTAssertEqual(top.usage.output, 8_000)
        XCTAssertEqual(session.promptCount, 2)
    }

    /// Slash-command echoes and interrupt notices arrive in the same slot as a
    /// typed prompt. They cost real tokens so they stay in the totals, but a
    /// list of "your expensive prompts" topped by `<command-name>` is noise.
    func testMachineWrittenTurnsAreFlaggedButStillCounted() throws {
        let url = try write([
            prompt("<command-name>/model</command-name>", id: "p1", at: "2026-08-25T10:00:00.000Z"),
            assistant(messageId: "msg_1", at: "2026-08-25T10:00:01.000Z", output: 900),
            prompt("real work", id: "p2", at: "2026-08-25T10:05:00.000Z"),
            assistant(messageId: "msg_2", at: "2026-08-25T10:05:01.000Z", output: 100),
        ])

        let session = try XCTUnwrap(TranscriptScanner.scan(file: url))
        XCTAssertEqual(session.usage.output, 1_000)
        XCTAssertEqual(session.promptCount, 1)
        XCTAssertEqual(session.costliestPrompts.map(\.prompt), ["real work"])
    }

    // MARK: - Context footprints

    /// A file read early in a long session is re-sent as a cache read on every
    /// request that follows. Charging it once makes the biggest context hog in
    /// a session look like its cheapest line item.
    func testFileCostIncludesTheCacheReadsItCausesLater() throws {
        let big = String(repeating: "x", count: 40_000)   // ≈10k tokens
        let url = try write([
            prompt("read it", id: "p1", at: "2026-08-25T10:00:00.000Z"),
            assistant(messageId: "msg_1", at: "2026-08-25T10:00:01.000Z", output: 10,
                      content: #"[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/work/proj/huge.swift"}}]"#),
            """
            {"type":"user","cwd":"/work/proj","timestamp":"2026-08-25T10:00:02.000Z",\
            "message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1",\
            "content":"\(big)"}]}}
            """,
            assistant(messageId: "msg_2", at: "2026-08-25T10:00:03.000Z", output: 10),
            assistant(messageId: "msg_3", at: "2026-08-25T10:00:04.000Z", output: 10),
            assistant(messageId: "msg_4", at: "2026-08-25T10:00:05.000Z", output: 10),
        ])

        let session = try XCTUnwrap(TranscriptScanner.scan(file: url))
        let footprint = try XCTUnwrap(session.footprints.first)
        XCTAssertEqual(footprint.key, "/work/proj/huge.swift")
        XCTAssertEqual(footprint.tool, "Read")
        XCTAssertEqual(footprint.directTokens, 10_000)
        // Fetched after request 1; three more requests followed, each of which
        // re-sent it.
        XCTAssertEqual(footprint.carriedTokens, 30_000)
        XCTAssertEqual(footprint.displayKey, "work/proj/huge.swift")
    }

    func testRepeatedReadsOfOneFileCollapseIntoOneRow() throws {
        let chunk = String(repeating: "y", count: 4_000)   // 1k tokens each
        var lines = [prompt("go", id: "p1", at: "2026-08-25T10:00:00.000Z")]
        for index in 0..<3 {
            lines.append(assistant(
                messageId: "msg_\(index)", at: "2026-08-25T10:00:0\(index).000Z", output: 5,
                content: #"[{"type":"tool_use","id":"t\#(index)","name":"Read","input":{"file_path":"/work/proj/same.swift"}}]"#))
            lines.append("""
                {"type":"user","cwd":"/work/proj","timestamp":"2026-08-25T10:00:0\(index).500Z",\
                "message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t\(index)",\
                "content":"\(chunk)"}]}}
                """)
        }
        let url = try write(lines)

        let session = try XCTUnwrap(TranscriptScanner.scan(file: url))
        XCTAssertEqual(session.footprints.count, 1)
        XCTAssertEqual(session.footprints[0].occurrences, 3)
        XCTAssertEqual(session.footprints[0].directTokens, 3_000)
    }

    // MARK: - Shape

    func testHourlyBucketsSplitAcrossTheHourBoundary() throws {
        let url = try write([
            prompt("go", id: "p1", at: "2026-08-25T10:59:00.000Z"),
            assistant(messageId: "msg_1", at: "2026-08-25T10:59:30.000Z", output: 100),
            assistant(messageId: "msg_2", at: "2026-08-25T11:00:30.000Z", output: 200),
        ])
        let session = try XCTUnwrap(TranscriptScanner.scan(file: url))
        XCTAssertEqual(session.hourly.count, 2)
        XCTAssertEqual(session.hourly.map(\.usage.output), [100, 200])
    }

    func testCostUsesThePerResponseModel() throws {
        let url = try write([
            prompt("go", id: "p1", at: "2026-08-25T10:00:00.000Z"),
            assistant(messageId: "msg_1", model: "claude-opus-5",
                      at: "2026-08-25T10:00:01.000Z", output: 1_000_000),
            assistant(messageId: "msg_2", model: "claude-haiku-4-5",
                      at: "2026-08-25T10:00:02.000Z", output: 1_000_000),
        ])
        let session = try XCTUnwrap(TranscriptScanner.scan(file: url))
        XCTAssertEqual(session.usage.costUsd, 25 + 5, accuracy: 0.001)
        XCTAssertEqual(Set(session.models), ["claude-opus-5", "claude-haiku-4-5"])
    }

    func testTranscriptWithNoResponsesIsNotASession() throws {
        let url = try write([prompt("typed and quit", id: "p1", at: "2026-08-25T10:00:00.000Z")])
        XCTAssertNil(TranscriptScanner.scan(file: url))
    }

    func testProjectPathComesFromTheTranscript() throws {
        let url = try write([
            prompt("go", id: "p1", at: "2026-08-25T10:00:00.000Z"),
            assistant(messageId: "msg_1", at: "2026-08-25T10:00:01.000Z", output: 10),
        ])
        let session = try XCTUnwrap(TranscriptScanner.scan(file: url))
        XCTAssertEqual(session.projectPath, "/work/proj")
        XCTAssertEqual(session.projectName, "proj")
    }

    // MARK: - Resuming

    /// A live transcript is read on from where the last pass stopped. That is
    /// only allowed if it lands on exactly the numbers a read from the top
    /// would — including a response whose lines straddle the two passes.
    func testResumingFromACheckpointMatchesAFullScan() throws {
        let first = [
            prompt("first", id: "p1", at: "2026-08-25T10:00:00.000Z"),
            assistant(messageId: "msg_1", at: "2026-08-25T10:00:01.000Z", output: 100,
                      content: #"[{"type":"tool_use","id":"tu_1","name":"Read","input":{"file_path":"/work/proj/a.swift"}}]"#),
        ]
        let second = [
            #"{"type":"user","timestamp":"2026-08-25T10:00:02.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","content":"\#(String(repeating: "x", count: 4_000))"}]}}"#,
            assistant(messageId: "msg_1", at: "2026-08-25T10:00:03.000Z", output: 100),
            assistant(messageId: "msg_2", at: "2026-08-25T10:00:04.000Z", output: 250),
            prompt("second", id: "p2", at: "2026-08-25T11:00:00.000Z"),
            assistant(messageId: "msg_3", at: "2026-08-25T11:00:01.000Z", output: 900),
        ]
        let url = sandbox.appendingPathComponent("live.jsonl")
        try (first.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let (_, checkpoint) = TranscriptScanner.scan(file: url, sessionId: "live", from: nil)
        let resumeFrom = try XCTUnwrap(checkpoint)
        XCTAssertEqual(resumeFrom.offset, UInt64(try Data(contentsOf: url).count))

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((second.joined(separator: "\n") + "\n").utf8))
        try handle.close()

        let resumed = try XCTUnwrap(
            TranscriptScanner.scan(file: url, sessionId: "live", from: resumeFrom).session)
        let whole = try XCTUnwrap(TranscriptScanner.scan(file: url, sessionId: "live"))
        XCTAssertEqual(resumed, whole)
        XCTAssertEqual(resumed.usage.requests, 3)
        XCTAssertEqual(resumed.usage.output, 1_250)
        XCTAssertEqual(resumed.footprints.first?.key, "/work/proj/a.swift")
    }

    /// Claude Code may be halfway through writing the last line when a pass
    /// runs. That line must not be skipped for good: the checkpoint stops
    /// short of it, so the next pass reads it whole.
    func testAHalfWrittenLastLineIsReadAgainOnceFinished() throws {
        let complete = assistant(messageId: "msg_2", at: "2026-08-25T10:00:05.000Z", output: 250)
        let url = sandbox.appendingPathComponent("partial.jsonl")
        let head = [
            prompt("go", id: "p1", at: "2026-08-25T10:00:00.000Z"),
            assistant(messageId: "msg_1", at: "2026-08-25T10:00:01.000Z", output: 100),
        ].joined(separator: "\n") + "\n"
        try (head + complete.prefix(40)).write(to: url, atomically: true, encoding: .utf8)

        let (partial, checkpoint) = TranscriptScanner.scan(file: url, sessionId: "p", from: nil)
        XCTAssertEqual(partial?.usage.output, 100)
        XCTAssertEqual(checkpoint?.offset, UInt64(Data(head.utf8).count))

        try (head + complete + "\n").write(to: url, atomically: true, encoding: .utf8)
        let finished = TranscriptScanner.scan(file: url, sessionId: "p", from: checkpoint).session
        XCTAssertEqual(finished?.usage.output, 350)
    }

    /// An unterminated final line that is complete still counts on the pass
    /// that sees it.
    func testAnUnterminatedFinalLineStillCounts() throws {
        let url = try write([
            prompt("go", id: "p1", at: "2026-08-25T10:00:00.000Z"),
            assistant(messageId: "msg_1", at: "2026-08-25T10:00:01.000Z", output: 70),
        ])
        XCTAssertEqual(TranscriptScanner.scan(file: url)?.usage.output, 70)
    }

    func testLinesLongerThanAChunkSurviveIntact() throws {
        let long = String(repeating: "y", count: 3 << 20)
        let url = sandbox.appendingPathComponent("long.txt")
        try "a\n\(long)\nb\n\nc".write(to: url, atomically: true, encoding: .utf8)

        let reader = try XCTUnwrap(LineReader(url: url))
        var lines: [Data] = []
        let tail = reader.forEachLine { lines.append($0) }
        XCTAssertEqual(lines.map(\.count), [1, long.utf8.count, 1])
        XCTAssertEqual(String(decoding: tail, as: UTF8.self), "c")
        XCTAssertEqual(reader.consumedOffset, UInt64(2 + long.utf8.count + 1 + 2 + 1))
    }

    // MARK: - Dates

    func testTimestampsParseLikeTheFormatterDid() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for stamp in [
            "2026-11-02T16:21:33.123Z", "2026-02-28T23:59:59.999Z", "2024-02-29T00:00:00.000Z",
            "2000-01-01T00:00:00.5Z", "1999-12-31T12:30:45.000001Z",
        ] {
            let fast = try XCTUnwrap(TranscriptDate.parseUTC(stamp), stamp)
            let reference = try XCTUnwrap(formatter.date(from: stamp), stamp)
            XCTAssertEqual(fast.timeIntervalSince1970, reference.timeIntervalSince1970,
                           accuracy: 0.001, stamp)
        }
        XCTAssertEqual(
            TranscriptDate.parseUTC("2026-11-02T16:21:33Z")?.timeIntervalSince1970,
            ISO8601DateFormatter().date(from: "2026-11-02T16:21:33Z")?.timeIntervalSince1970)
        // Anything else is left to the formatters.
        XCTAssertNil(TranscriptDate.parseUTC("2026-11-02T16:21:33+03:00"))
        XCTAssertNil(TranscriptDate.parseUTC("2026-13-02T16:21:33Z"))
        XCTAssertNotNil(TranscriptDate.parse("2026-11-02T16:21:33+03:00"))
    }
}

/// Forecast arithmetic.
///
/// The rule these all encode: a percentage means nothing without knowing how
/// far into the window it was measured.
final class QuotaForecastTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(used: Double, resetsIn: TimeInterval) -> RateLimitWindow {
        RateLimitWindow(usedPercentage: used, resetsAt: now.addingTimeInterval(resetsIn))
    }

    func testSameNumberIsFineLateAndFatalEarly() {
        // 60% with 30 minutes left: 4.5h of the window spent, it holds.
        let late = QuotaForecast.project(
            window: window(used: 60, resetsIn: 30 * 60), kind: .fiveHour, now: now)
        XCTAssertEqual(late.verdict, .holds)

        // 60% with 4 hours left: one hour in, and on pace for 300%.
        let early = QuotaForecast.project(
            window: window(used: 60, resetsIn: 4 * 3600), kind: .fiveHour, now: now)
        XCTAssertEqual(early.verdict, .exhausts)
        XCTAssertNotNil(early.exhaustsAt)
    }

    func testProjectionExtrapolatesTheWindowLongAverage() {
        // Half the window gone, 30% used → 60% projected.
        let forecast = QuotaForecast.project(
            window: window(used: 30, resetsIn: 2.5 * 3600), kind: .fiveHour, now: now)
        XCTAssertEqual(try XCTUnwrap(forecast.projectedAtReset), 60, accuracy: 0.5)
        XCTAssertEqual(forecast.verdict, .holds)
    }

    func testProjectionLandingJustUnderTheCapIsCalledTight() {
        // 47% at the halfway mark projects to ~94%.
        let forecast = QuotaForecast.project(
            window: window(used: 47, resetsIn: 2.5 * 3600), kind: .fiveHour, now: now)
        XCTAssertEqual(forecast.verdict, .tight)
    }

    /// Someone who burned hard and then stopped should not be told they are
    /// about to run out; the recent samples say the line is idle.
    func testRecentSamplesOverrideTheWindowAverage() {
        let samples = [
            QuotaSample(at: now.addingTimeInterval(-60 * 60), fiveHour: 60, sevenDay: 10),
            QuotaSample(at: now.addingTimeInterval(-10 * 60), fiveHour: 60, sevenDay: 10),
        ]
        let forecast = QuotaForecast.project(
            window: window(used: 60, resetsIn: 4 * 3600), kind: .fiveHour,
            samples: samples, now: now)
        XCTAssertTrue(forecast.usesRecentPace)
        XCTAssertEqual(forecast.verdict, .holds)
        XCTAssertEqual(try XCTUnwrap(forecast.burnPerHour), 0, accuracy: 0.01)
    }

    func testSamplesTooCloseTogetherAreIgnored() {
        let samples = [
            QuotaSample(at: now.addingTimeInterval(-120), fiveHour: 10, sevenDay: 5),
            QuotaSample(at: now.addingTimeInterval(-60), fiveHour: 30, sevenDay: 5),
        ]
        // A 20-point jump in one minute extrapolates to 1200%/h. The window
        // average must win instead.
        let forecast = QuotaForecast.project(
            window: window(used: 30, resetsIn: 2.5 * 3600), kind: .fiveHour,
            samples: samples, now: now)
        XCTAssertFalse(forecast.usesRecentPace)
    }

    /// A window whose reset time has passed describes a window that no longer
    /// exists. Extrapolating from it would put a confident number on the board
    /// that is about nothing at all — which is exactly how a stale cache turns
    /// into a wrong readout.
    func testExpiredWindowRefusesToForecast() {
        let forecast = QuotaForecast.project(
            window: window(used: 88, resetsIn: -3600), kind: .fiveHour, now: now)
        XCTAssertEqual(forecast.verdict, .unknown)
        XCTAssertNil(forecast.projectedAtReset)
    }

    func testFreshWindowRefusesToForecast() {
        let forecast = QuotaForecast.project(
            window: window(used: 2, resetsIn: 4.95 * 3600), kind: .fiveHour, now: now)
        XCTAssertEqual(forecast.verdict, .unknown)
    }

    func testMissingResetTimeRefusesToForecast() {
        let forecast = QuotaForecast.project(
            window: RateLimitWindow(usedPercentage: 50, resetsAt: nil),
            kind: .fiveHour, now: now)
        XCTAssertEqual(forecast.verdict, .unknown)
    }
}

/// The sample log the forecast reads from.
@MainActor
final class QuotaHistoryTests: XCTestCase {
    var url: URL!

    override func setUpWithError() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("andon-quota-\(UUID().uuidString).jsonl")
    }

    override func tearDownWithError() throws {
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// The statusline fires on every assistant message; almost none of them
    /// move the percentage. Recording them all would bury the readings that
    /// carry information.
    func testUnchangedReadingsAreNotRecorded() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let history = QuotaHistory(url: url)
        XCTAssertTrue(history.record(QuotaSample(at: base, fiveHour: 10, sevenDay: 4)))
        XCTAssertFalse(history.record(
            QuotaSample(at: base.addingTimeInterval(60), fiveHour: 10, sevenDay: 4)))
        XCTAssertTrue(history.record(
            QuotaSample(at: base.addingTimeInterval(120), fiveHour: 12, sevenDay: 4)))

        XCTAssertEqual(history.samples.map(\.fiveHour), [10, 12])
    }

    func testRoundTripsThroughDisk() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let writer = QuotaHistory(url: url)
        writer.record(QuotaSample(at: base, fiveHour: 1, sevenDay: nil))
        writer.record(QuotaSample(at: base.addingTimeInterval(300), fiveHour: 9, sevenDay: 2))

        // A fresh instance is what the app has after a relaunch: the pace
        // calculation depends on readings taken before this launch, so they
        // have to survive one.
        let reloaded = QuotaHistory(url: url)
        XCTAssertEqual(reloaded.samples.count, 2)
        XCTAssertEqual(reloaded.samples[1].sevenDay, 2)
        XCTAssertEqual(
            reloaded.samples[0].at.timeIntervalSince1970,
            base.timeIntervalSince1970, accuracy: 1)
    }

    /// Only one window reporting is normal — Claude Code omits `five_hour`
    /// outside a session — and it must not knock out the other one.
    func testSamplesWithOneWindowMissingStillFeedTheForecast() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let history = QuotaHistory(url: url)
        history.record(QuotaSample(at: base, fiveHour: nil, sevenDay: 20))
        history.record(QuotaSample(at: base.addingTimeInterval(1800), fiveHour: nil, sevenDay: 24))

        XCTAssertTrue(history.samples(for: .fiveHour).isEmpty)
        XCTAssertEqual(history.samples(for: .sevenDay).count, 2)
    }
}

/// Runs the scanner over this machine's real transcripts.
///
/// Synthetic fixtures cannot tell you whether a year of real Claude Code
/// history indexes in seconds or minutes, and the first index is the one
/// moment the app could plausibly hang. Skipped unless `ANDON_SCAN_REAL` is
/// set; read-only, and prints rather than asserts on the numbers themselves.
final class RealTranscriptScanTests: XCTestCase {
    func testIndexesRealTranscripts() throws {
        guard ProcessInfo.processInfo.environment["ANDON_SCAN_REAL"] != nil
        else { throw XCTSkip("set ANDON_SCAN_REAL to run") }

        let root = Paths.claudeDir.appendingPathComponent("projects")
        let directories = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)

        var sessions: [SessionUsage] = []
        var bytes = 0
        let started = Date()
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if let session = TranscriptScanner.scan(file: file) { sessions.append(session) }
            }
        }
        let elapsed = Date().timeIntervalSince(started)

        let total = sessions.reduce(TokenUsage()) { $0 + $1.usage }
        print("""

        ── real transcript scan ──────────────────────────────────
        files      \(sessions.count) sessions from \(bytes / 1_048_576) MB
        elapsed    \(String(format: "%.1fs", elapsed)) (\(String(format: "%.0f", Double(bytes) / 1_048_576 / max(elapsed, 0.001))) MB/s)
        requests   \(total.requests)
        tokens     in \(formatTokens(total.input)) · out \(formatTokens(total.output)) \
        · write \(formatTokens(total.cacheWrite)) · read \(formatTokens(total.cacheRead))
        total      \(formatTokens(total.total))  ≈ \(formatCost(total.costUsd))
        """)

        for session in sessions.sorted(by: { $0.usage.total > $1.usage.total }).prefix(5) {
            print("  \(formatTokens(session.usage.total).padded(8)) \(formatCost(session.usage.costUsd).padded(9)) \(session.projectName)/\(session.shortId)  \(session.title)")
        }
        print("  ── heaviest context ──")
        var merged: [String: ContextFootprint] = [:]
        for session in sessions {
            for footprint in session.footprints {
                let id = "\(footprint.tool)\u{1}\(footprint.key)"
                if var existing = merged[id] {
                    existing.occurrences += footprint.occurrences
                    existing.directTokens += footprint.directTokens
                    existing.carriedTokens += footprint.carriedTokens
                    merged[id] = existing
                } else { merged[id] = footprint }
            }
        }
        for footprint in merged.values.sorted(by: { $0.totalTokens > $1.totalTokens }).prefix(8) {
            print("  \(formatTokens(footprint.totalTokens).padded(8)) ×\(footprint.occurrences) \(footprint.tool)  \(footprint.displayKey)")
        }
        print("──────────────────────────────────────────────────────────\n")

        XCTAssertFalse(sessions.isEmpty)
    }
}

private extension String {
    func padded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
