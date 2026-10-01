import XCTest
@testable import AndonKit

/// Reading quota out of the Claude desktop app's own record, and working out
/// from it when each window resets.
///
/// Neither that file nor the statusline says when a window *opened* — but a
/// reset shows up as the percentage falling, and consecutive samples bracket
/// the moment it happened. Everything downstream (the countdown, the pace, the
/// spend scoped to the window) hangs off getting that right.
final class PlanUsageFileTests: XCTestCase {
    private let day: TimeInterval = 86_400

    /// `t` is epoch milliseconds, which is the one detail that silently turns
    /// every timestamp into 1970 if it is read as seconds.
    private func document(_ points: [(Double, Double?, Double?)]) -> Data {
        let samples = points.map { time, fh, sd -> String in
            let usage = [
                fh.map { "\"fh\":\($0)" },
                sd.map { "\"sd\":\($0)" },
            ].compactMap { $0 }.joined(separator: ",")
            return #"{"t":\#(time * 1000),"org":"o","u":{\#(usage)}}"#
        }
        return Data(#"{"version":2,"samples":[\#(samples.joined(separator: ","))]}"#.utf8)
    }

    func testParsesMillisecondTimestamps() throws {
        let data = document([(1_800_000_000, 30, 26)])
        let samples = try XCTUnwrap(PlanUsageFile.parse(data))
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].at.timeIntervalSince1970, 1_800_000_000, accuracy: 0.001)
        XCTAssertEqual(samples[0].fiveHour, 30)
        XCTAssertEqual(samples[0].sevenDay, 26)
    }

    func testMalformedFileIsRejectedRatherThanGuessedAt() {
        XCTAssertNil(PlanUsageFile.parse(Data("not json".utf8)))
        XCTAssertNil(PlanUsageFile.parse(Data(#"{"version":2}"#.utf8)))
    }

    /// The five-hour window is not on a grid — it opens with the first request
    /// after the last one lapsed — so only the most recent reset says anything
    /// about where it is now.
    func testFiveHourResetIsTakenFromTheLatestDrop() throws {
        let base: Double = 1_800_000_000
        let samples = try XCTUnwrap(PlanUsageFile.parse(document([
            (base, 20, 10),
            (base + 900, 30, 10),
            (base + 1_800, 1, 10),      // reset, and already in use again
            (base + 2_700, 4, 10),
        ])))

        let resetsAt = try XCTUnwrap(PlanUsageFile.resetsAt(
            for: .fiveHour, samples: samples,
            now: Date(timeIntervalSince1970: base + 3_000)))
        // The window opened at the sample that first showed it in use.
        XCTAssertEqual(
            resetsAt.timeIntervalSince1970, base + 1_800 + 5 * 3_600, accuracy: 1)
    }

    /// A window that lapsed but shows no use has not reopened. Reporting it as
    /// "0% used, resets in 5h" would invent a window that does not exist yet.
    func testWindowThatHasNotReopenedYetHasNoResetTime() throws {
        let base: Double = 1_800_000_000
        let samples = try XCTUnwrap(PlanUsageFile.parse(document([
            (base, 30, 10),
            (base + 900, 0, 10),
            (base + 1_800, 0, 10),
        ])))
        XCTAssertNil(PlanUsageFile.resetsAt(
            for: .fiveHour, samples: samples,
            now: Date(timeIntervalSince1970: base + 2_000)))
    }

    /// The weekly window is periodic, so every reset ever recorded is evidence
    /// about the same phase. A tight bracket weeks back beats a loose one from
    /// yesterday.
    func testWeeklyResetUsesTheTightestBracketAcrossAllWeeks() throws {
        let base: Double = 1_800_000_000
        let week: Double = 7 * 86_400
        let samples = try XCTUnwrap(PlanUsageFile.parse(document([
            // A five-minute bracket three weeks ago.
            (base, nil, 61),
            (base + 300, nil, 0),
            // A two-hour bracket last week — same phase, much less precise.
            (base + week - 3_600, nil, 53),
            (base + week + 3_600, nil, 0),
            (base + week + 7_200, nil, 4),
        ])))

        let now = Date(timeIntervalSince1970: base + week + 86_400)
        let resetsAt = try XCTUnwrap(
            PlanUsageFile.resetsAt(for: .sevenDay, samples: samples, now: now))
        // Phase from the tight bracket: base + 150s, projected forward.
        let phase = (resetsAt.timeIntervalSince1970 - (base + 150))
            .truncatingRemainder(dividingBy: week)
        XCTAssertEqual(phase, 0, accuracy: 60)
        XCTAssertGreaterThan(resetsAt, now)
        XCTAssertLessThan(resetsAt.timeIntervalSince(now), week)
    }

    /// A limit reset off-cycle — a plan change, a reset from Anthropic's
    /// side — leaves a drop that is not the cadence, and often a tight one.
    /// It must not drag the phase: the next reset still comes on schedule.
    func testOffCycleResetDoesNotMoveTheWeeklyPhase() throws {
        let base: Double = 1_800_000_000
        let week: Double = 7 * 86_400
        let offCycle = base + week + 1.2 * 86_400
        let samples = try XCTUnwrap(PlanUsageFile.parse(document([
            (base - 1_200, nil, 70), (base + 2_400, nil, 0),
            (base + week - 600, nil, 60), (base + week + 1_200, nil, 0),
            // The tightest bracket on record, and the wrong day.
            (offCycle, nil, 100), (offCycle + 300, nil, 0),
            (base + 2 * week - 3_000, nil, 50), (base + 2 * week + 2_400, nil, 1),
        ])))

        let now = Date(timeIntervalSince1970: base + 2 * week + 86_400)
        let resetsAt = try XCTUnwrap(
            PlanUsageFile.resetsAt(for: .sevenDay, samples: samples, now: now))
        // The three on-cadence brackets intersect to [-600s, +1200s] around
        // the true reset, so the estimate lands five minutes after it.
        XCTAssertEqual(resetsAt.timeIntervalSince1970, base + 3 * week + 300, accuracy: 1)
    }

    func testNoResetsMeansNoResetTime() throws {
        let base: Double = 1_800_000_000
        let samples = try XCTUnwrap(PlanUsageFile.parse(document([
            (base, 5, 10), (base + 300, 9, 11), (base + 600, 14, 11),
        ])))
        XCTAssertNil(PlanUsageFile.resetsAt(
            for: .fiveHour, samples: samples,
            now: Date(timeIntervalSince1970: base + 900)))
    }

    /// A record that stopped days ago describes a window that has since
    /// lapsed. Counting down to a reset in the past is worse than saying
    /// nothing.
    func testLapsedWindowFromAnAbandonedRecordIsDropped() throws {
        let base: Double = 1_800_000_000
        let samples = try XCTUnwrap(PlanUsageFile.parse(document([
            (base, 30, 10), (base + 300, 2, 10),
        ])))
        XCTAssertNil(PlanUsageFile.resetsAt(
            for: .fiveHour, samples: samples,
            now: Date(timeIntervalSince1970: base + 3 * 86_400)))
    }

    func testResetsAreBracketedByTheSamplesAroundThem() throws {
        let base: Double = 1_800_000_000
        let samples = try XCTUnwrap(PlanUsageFile.parse(document([
            (base, 30, 10), (base + 900, 1, 10),
        ])))
        let resets = PlanUsageFile.resets(for: .fiveHour, samples: samples)
        XCTAssertEqual(resets.count, 1)
        XCTAssertEqual(resets[0].span, 900, accuracy: 1)
        XCTAssertEqual(resets[0].instant.timeIntervalSince1970, base + 450, accuracy: 1)
    }
}

/// The store that turns those samples into something the board can draw.
@MainActor
final class PlanUsageStoreTests: XCTestCase {
    var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("andon-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: sandbox.appendingPathComponent("Library/Application Support/Claude"),
            withIntermediateDirectories: true)
        Paths.homeOverride = sandbox
    }

    override func tearDownWithError() throws {
        Paths.homeOverride = nil
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    private func write(_ json: String) throws {
        try json.write(to: Paths.planUsageHistory, atomically: true, encoding: .utf8)
    }

    func testReadoutCarriesTheLatestFigureAndItsResetTime() throws {
        let now = Date()
        let opened = now.addingTimeInterval(-3_600)
        try write("""
            {"version":2,"samples":[
              {"t":\(Int((opened.timeIntervalSince1970 - 900) * 1000)),"org":"o","u":{"fh":40,"sd":20}},
              {"t":\(Int(opened.timeIntervalSince1970 * 1000)),"org":"o","u":{"fh":2,"sd":21}},
              {"t":\(Int(now.timeIntervalSince1970 * 1000)),"org":"o","u":{"fh":18,"sd":22}}
            ]}
            """)

        let store = PlanUsageStore()
        store.reload()

        let readout = try XCTUnwrap(store.readout(.fiveHour, spent: TokenUsage(), now: now))
        XCTAssertEqual(readout.usedPercentage, 18)
        XCTAssertTrue(readout.isMeasured)
        XCTAssertFalse(readout.isEstimate)
        XCTAssertEqual(
            try XCTUnwrap(readout.resetsAt).timeIntervalSince1970,
            opened.timeIntervalSince1970 + 5 * 3_600, accuracy: 2)
    }

    /// The desktop app writes every five minutes. When it stops, the numbers
    /// stop with it — and saying so is the whole difference between this and
    /// the stale statusline cache it replaces.
    func testAbandonedRecordIsMarkedNotCurrent() throws {
        let old = Date().addingTimeInterval(-6 * 3_600)
        try write("""
            {"version":2,"samples":[
              {"t":\(Int((old.timeIntervalSince1970 - 900) * 1000)),"org":"o","u":{"fh":40,"sd":20}},
              {"t":\(Int(old.timeIntervalSince1970 * 1000)),"org":"o","u":{"fh":2,"sd":21}}
            ]}
            """)

        let store = PlanUsageStore()
        store.reload()
        XCTAssertFalse(store.isFresh)
        // The five-hour window it described has lapsed, so there is nothing to
        // report for it at all.
        XCTAssertNil(store.readout(.fiveHour, spent: TokenUsage()))
        // The weekly one is still running, and is reported as not current.
        let weekly = try XCTUnwrap(store.readout(.sevenDay, spent: TokenUsage()))
        XCTAssertFalse(weekly.isMeasured)
    }

    /// The weekly reset is projected forward however old the samples are, so
    /// a record that stopped before the last turnover would otherwise have
    /// last week's figure drawn against this week's countdown.
    func testRecordThatStoppedBeforeTheWeeklyResetSaysNothing() throws {
        let now = Date()
        let reset = now.addingTimeInterval(-10 * 86_400)
        let last = now.addingTimeInterval(-4 * 86_400)   // the window turned over 3 days ago
        try write("""
            {"version":2,"samples":[
              {"t":\(Int((reset.timeIntervalSince1970 - 450) * 1000)),"org":"o","u":{"fh":10,"sd":80}},
              {"t":\(Int((reset.timeIntervalSince1970 + 450) * 1000)),"org":"o","u":{"fh":12,"sd":1}},
              {"t":\(Int(last.timeIntervalSince1970 * 1000)),"org":"o","u":{"fh":30,"sd":64}}
            ]}
            """)

        let store = PlanUsageStore()
        store.reload()
        XCTAssertNil(store.readout(.sevenDay, spent: TokenUsage(), now: now))
    }

    func testMissingFileYieldsNothingRatherThanZeroes() {
        let store = PlanUsageStore()
        store.reload()
        XCTAssertTrue(store.samples.isEmpty)
        XCTAssertNil(store.readout(.fiveHour, spent: TokenUsage()))
        XCTAssertNil(store.readout(.sevenDay, spent: TokenUsage()))
    }
}
