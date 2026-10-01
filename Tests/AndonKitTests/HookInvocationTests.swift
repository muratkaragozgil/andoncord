import XCTest
@testable import AndonKit

/// Whether the shim acts at all.
///
/// Claude Code is the only caller AndonCord answers to, but not the only thing
/// that runs the shim: 0.1.x left hooks in other agents' config files, and
/// Cursor runs Claude's. Getting this wrong in one direction drops Claude's
/// events; in the other, it puts someone else's tool on our critical path.
final class HookInvocationTests: XCTestCase {
    func testClaudeHooksAreUntagged() {
        let passive = HookInvocation(arguments: [])
        XCTAssertTrue(passive.isClaudeCode)
        XCTAssertFalse(passive.isBlocking)
        XCTAssertFalse(passive.isStatusline)

        XCTAssertTrue(HookInvocation(arguments: ["--blocking"]).isBlocking)
        XCTAssertTrue(HookInvocation(arguments: ["--blocking"]).isClaudeCode)
        // What the statusline launcher passes, ahead of anything forwarded.
        XCTAssertTrue(HookInvocation(arguments: ["--statusline"]).isStatusline)
        XCTAssertTrue(HookInvocation(arguments: ["--statusline"]).isClaudeCode)
    }

    func testHooksLeftInOtherAgentsAreNotClaude() {
        for source in ["codex", "gemini", "cursor", "something-new"] {
            XCTAssertFalse(HookInvocation(arguments: ["--source", source]).isClaudeCode,
                           "--source \(source)")
            // The tag decides, wherever it sits relative to the flags.
            XCTAssertFalse(HookInvocation(arguments: ["--source", source, "--blocking"]).isClaudeCode,
                           "--source \(source) --blocking")
            XCTAssertFalse(HookInvocation(arguments: ["--blocking", "--source", source]).isClaudeCode,
                           "--blocking --source \(source)")
        }
    }

    func testAnExplicitClaudeTagIsStillClaude() {
        XCTAssertTrue(HookInvocation(arguments: ["--source", "claude"]).isClaudeCode)
        XCTAssertTrue(HookInvocation(arguments: ["--source", "Claude-Code"]).isClaudeCode)
        // A dangling flag tags nothing, which leaves the untagged default.
        XCTAssertTrue(HookInvocation(arguments: ["--source"]).isClaudeCode)
    }

    /// The shim treats an untagged hook as Claude's, which is only safe while
    /// the installer keeps writing them untagged.
    func testClaudeInstallerWritesUntaggedHooks() {
        let commands = ClaudeSettingsInstaller().desiredGroups().values
            .flatMap { $0 }
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        XCTAssertFalse(commands.isEmpty)
        for command in commands {
            XCTAssertFalse(command.contains("--source"), command)
        }
    }

    func testCursorPayloadsAreNotClaude() throws {
        let cursor = try JSONDecoder().decode(JSONValue.self, from: Data("""
            {"conversation_id":"c1","cursor_version":"2.4","hook_event_name":"preToolUse"}
            """.utf8))
        XCTAssertFalse(HookInvocation.isFromClaudeCode(cursor))

        let claude = try JSONDecoder().decode(JSONValue.self, from: Data("""
            {"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash"}
            """.utf8))
        XCTAssertTrue(HookInvocation.isFromClaudeCode(claude))
    }

    /// The session AndonCord starts to have Claude Code renew its sign-in
    /// fires hooks like any other. They must not put it on the board.
    func testTheRenewalSessionIsRecognised() {
        XCTAssertTrue(HookInvocation.isRenewalSession([HookInvocation.renewalMarker: "1"]))
        XCTAssertFalse(HookInvocation.isRenewalSession([:]))
        XCTAssertFalse(HookInvocation.isRenewalSession([HookInvocation.renewalMarker: "0"]))
    }

    /// The other direction of the same upgrade: a 0.1.x shim still tags every
    /// envelope with the agent it ran for.
    func testEnvelopeFromAnOlderShimStillDecodes() throws {
        let line = """
            {"protocolVersion":1,"blocking":false,"agentSource":"codex",\
            "payload":{"session_id":"s1","hook_event_name":"Stop"},"raw":{},\
            "shimPid":42,"receivedAt":0}
            """
        let envelope = try JSONDecoder().decode(HookEnvelope.self, from: Data(line.utf8))
        XCTAssertEqual(envelope.payload.sessionId, "s1")
        XCTAssertEqual(envelope.payload.event, .stop)
    }
}
