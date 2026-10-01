import XCTest
@testable import AndonKit

/// Reading Anthropic's own usage answer, and the Claude Code sign-in used to
/// ask for it.
///
/// Nothing here touches the network or the Keychain: the shapes are what can
/// go wrong without anyone noticing, so the shapes are what is pinned.
final class AnthropicUsageTests: XCTestCase {

    func testWindowsLandOnTheStatuslineFields() throws {
        let limits = try XCTUnwrap(AnthropicUsageAPI.parse(Data("""
            {"five_hour":{"utilization":14.0,"resets_at":"2026-10-02T01:00:00.123456+00:00"},
             "seven_day":{"utilization":58.0,"resets_at":"2026-10-07T14:00:00+00:00"}}
            """.utf8)))

        XCTAssertEqual(limits.fiveHour?.usedPercentage, 14)
        XCTAssertEqual(limits.sevenDay?.usedPercentage, 58)
        // Fractional seconds and a bare timestamp both parse — the endpoint
        // has used each.
        XCTAssertEqual(
            try XCTUnwrap(limits.fiveHour?.resetsAt).timeIntervalSince1970,
            ISO8601DateFormatter().date(from: "2026-10-02T01:00:00Z")!.timeIntervalSince1970 + 0.123,
            accuracy: 0.001)
        XCTAssertEqual(
            limits.sevenDay?.resetsAt, ISO8601DateFormatter().date(from: "2026-10-07T14:00:00Z"))
    }

    /// Model-scoped weekly limits arrive both as flat keys and as entries in
    /// `limits`. Either way they are kept, under a name that says which model.
    func testModelScopedWeeklyLimitsAreKept() throws {
        let limits = try XCTUnwrap(AnthropicUsageAPI.parse(Data("""
            {"five_hour":{"utilization":14,"resets_at":null},
             "seven_day":{"utilization":58,"resets_at":null},
             "seven_day_opus":{"utilization":20,"resets_at":null},
             "limits":[
               {"kind":"weekly_scoped","group":"weekly","percent":1,
                "resets_at":"2026-10-07T14:00:00Z","is_active":true,
                "scope":{"model":{"id":"claude-fable-5-1","display_name":"Fable"}}},
               {"kind":"weekly","group":"weekly","percent":58,"scope":{}}
             ]}
            """.utf8)))

        XCTAssertEqual(limits.others["seven_day_opus"]?.usedPercentage, 20)
        XCTAssertEqual(limits.others["seven_day_fable"]?.usedPercentage, 1)
        XCTAssertNotNil(limits.others["seven_day_fable"]?.resetsAt)
        // The unscoped entry is the same window as `seven_day`, not another one.
        XCTAssertEqual(limits.others.count, 2)
    }

    func testAnAnswerWithNoWindowsIsNotAReading() {
        XCTAssertNil(AnthropicUsageAPI.parse(Data(#"{"extra_usage":{"is_enabled":false}}"#.utf8)))
        XCTAssertNil(AnthropicUsageAPI.parse(Data("not json".utf8)))
    }

    func testCredentialsAreReadFromClaudeCodesRecord() throws {
        let credentials = try XCTUnwrap(ClaudeCodeCredentials.parse(Data("""
            {"claudeAiOauth":{"accessToken":"tok","refreshToken":"ref",
              "expiresAt":1790000000000,"scopes":["user:inference","user:profile"]},
             "mcpOAuth":{}}
            """.utf8)))

        XCTAssertEqual(credentials.accessToken, "tok")
        XCTAssertEqual(credentials.expiresAt?.timeIntervalSince1970, 1_790_000_000)
        XCTAssertTrue(credentials.canReadUsage)
    }

    /// The Keychain item can hold nothing but MCP servers' OAuth state, and a
    /// token from `claude setup-token` can run models but not read usage.
    func testRecordsThatCannotReadUsageAreRecognised() throws {
        XCTAssertNil(ClaudeCodeCredentials.parse(Data(#"{"mcpOAuth":{"server":{}}}"#.utf8)))

        let inferenceOnly = try XCTUnwrap(ClaudeCodeCredentials.parse(Data("""
            {"claudeAiOauth":{"accessToken":"tok","scopes":["user:inference"]}}
            """.utf8)))
        XCTAssertFalse(inferenceOnly.canReadUsage)
    }

    func testATokenIsTreatedAsExpiredAMinuteEarly() {
        let now = Date()
        let credentials = { (left: TimeInterval) in
            ClaudeCodeCredentials(
                accessToken: "tok", expiresAt: now.addingTimeInterval(left), scopes: [])
        }
        XCTAssertTrue(credentials(-3_600).isExpired(asOf: now))
        XCTAssertTrue(credentials(30).isExpired(asOf: now))
        XCTAssertFalse(credentials(600).isExpired(asOf: now))
        // No stamp at all: let the endpoint be the judge.
        XCTAssertFalse(
            ClaudeCodeCredentials(accessToken: "tok", expiresAt: nil, scopes: []).isExpired())
    }
}
