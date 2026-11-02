import XCTest
@testable import AndonKit

/// The installer is the only component that writes to a file the user cares
/// about, so it gets the most testing. Every case here runs against a
/// throwaway HOME.
final class InstallerTests: XCTestCase {
    var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("andon-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: sandbox.appendingPathComponent(".claude"),
            withIntermediateDirectories: true)
        Paths.homeOverride = sandbox
    }

    override func tearDownWithError() throws {
        Paths.homeOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func writeSettings(_ text: String) throws {
        try text.write(to: Paths.claudeSettings, atomically: true, encoding: .utf8)
    }

    private func readSettings() throws -> [String: Any] {
        try JSONC.parseObject(try String(contentsOf: Paths.claudeSettings, encoding: .utf8))
    }

    // MARK: - Core round trip

    func testInstallThenUninstallRestoresOriginalExactly() throws {
        let original = """
        {
          "env": { "FOO": "bar" },
          "statusLine": { "type": "command", "command": "/usr/local/bin/my-statusline" },
          "permissions": { "allow": ["Bash(ls:*)"] }
        }
        """
        try writeSettings(original)

        let installer = ClaudeSettingsInstaller()
        try installer.install()
        XCTAssertEqual(installer.currentStatus(), .installed)

        try installer.uninstall()

        let restored = try readSettings()
        XCTAssertNil(restored["hooks"], "uninstall must remove the hooks block it created")

        let statusline = restored["statusLine"] as? [String: Any]
        XCTAssertEqual(statusline?["command"] as? String, "/usr/local/bin/my-statusline",
                       "the displaced statusline must come back verbatim")
        XCTAssertEqual((restored["env"] as? [String: Any])?["FOO"] as? String, "bar",
                       "unrelated settings must survive untouched")
        XCTAssertNotNil(restored["permissions"])
    }

    func testUninstallRemovesStatuslineKeyWhenThereWasNoneBefore() throws {
        try writeSettings("{}")
        let installer = ClaudeSettingsInstaller()
        try installer.install()
        try installer.uninstall()

        let restored = try readSettings()
        XCTAssertNil(restored["statusLine"],
                     "we must not leave behind a statusLine the user never had")
    }

    // MARK: - Coexistence

    func testForeignHooksSurviveInstallAndUninstall() throws {
        // Mirrors a real machine with another notch app already installed.
        let foreign = """
        {
          "hooks": {
            "PreToolUse": [
              { "matcher": "*", "hooks": [
                  { "type": "command", "command": "/bin/sh -c 'other-tool; exit 0'" } ] }
            ],
            "Stop": [
              { "hooks": [ { "type": "command", "command": "/opt/other/bridge" } ] }
            ]
          },
          "statusLine": { "type": "command", "command": "/opt/other/statusline" }
        }
        """
        try writeSettings(foreign)

        let installer = ClaudeSettingsInstaller()
        try installer.install()

        let afterInstall = try readSettings()
        let hooks = afterInstall["hooks"] as! [String: Any]
        let preToolUse = hooks["PreToolUse"] as! [[String: Any]]

        let commands = preToolUse
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(commands.contains { $0.contains("other-tool") },
                      "another tool's hook must keep running alongside ours")
        XCTAssertTrue(commands.contains { $0.contains(ClaudeSettingsInstaller.marker) })

        try installer.uninstall()

        let afterUninstall = try readSettings()
        let remaining = (afterUninstall["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]]
        let remainingCommands = remaining
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        XCTAssertEqual(remainingCommands.filter { $0.contains("other-tool") }.count, 1)
        XCTAssertFalse(remainingCommands.contains { $0.contains(ClaudeSettingsInstaller.marker) })
        XCTAssertEqual(
            (afterUninstall["statusLine"] as? [String: Any])?["command"] as? String,
            "/opt/other/statusline")
    }

    // MARK: - Idempotency

    func testRepeatedInstallsDoNotStackDuplicates() throws {
        try writeSettings("{}")
        let installer = ClaudeSettingsInstaller()
        try installer.install()
        try installer.install()
        try installer.install()

        let hooks = try readSettings()["hooks"] as! [String: Any]
        let permissionGroups = hooks["PermissionRequest"] as! [[String: Any]]
        let ourHandlers = permissionGroups
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .filter { ($0["command"] as? String)?.contains(ClaudeSettingsInstaller.marker) == true }
        XCTAssertEqual(ourHandlers.count, 1, "reinstalling must replace, not append")
    }

    func testReinstallDoesNotClobberSavedStatuslineChain() throws {
        try writeSettings("""
        { "statusLine": { "type": "command", "command": "/usr/local/bin/original" } }
        """)
        let installer = ClaudeSettingsInstaller()
        try installer.install()
        try installer.install()  // second install sees our own launcher in place
        try installer.uninstall()

        XCTAssertEqual(
            (try readSettings()["statusLine"] as? [String: Any])?["command"] as? String,
            "/usr/local/bin/original",
            "a second install must not overwrite the chain with our own launcher")
    }

    // MARK: - Robustness

    func testHandlesSettingsFileWithComments() throws {
        try writeSettings("""
        {
          // my settings
          "env": { "A": "1" }, /* inline */
          "statusLine": { "type": "command", "command": "/x/y" }
        }
        """)
        let installer = ClaudeSettingsInstaller()
        let report = try installer.install()
        XCTAssertTrue(report.commentsWillBeLost,
                      "caller needs to be able to warn the user before comments are dropped")
        XCTAssertEqual(installer.currentStatus(), .installed)
    }

    func testHandlesMissingSettingsFile() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.claudeSettings.path))
        let installer = ClaudeSettingsInstaller()
        try installer.install()
        XCTAssertEqual(installer.currentStatus(), .installed)
    }

    func testBackupIsCreatedBeforeWriting() throws {
        try writeSettings("{ \"marker\": \"original\" }")
        let report = try ClaudeSettingsInstaller().install()
        let backup = try XCTUnwrap(report.backupURL)
        let contents = try String(contentsOf: backup, encoding: .utf8)
        XCTAssertTrue(contents.contains("original"))
    }

    func testDriftIsDetectedWhenHooksAreStripped() throws {
        try writeSettings("{}")
        let installer = ClaudeSettingsInstaller()
        try installer.install()

        // Simulate another tool rewriting the file and dropping some of ours.
        var settings = try readSettings()
        var hooks = settings["hooks"] as! [String: Any]
        hooks.removeValue(forKey: "PermissionRequest")
        settings["hooks"] = hooks
        try Data(JSONC.serialize(settings)).write(to: Paths.claudeSettings)

        guard case .drifted = installer.currentStatus() else {
            return XCTFail("removing an installed hook must register as drift")
        }
    }

    // MARK: - Generated hook commands

    func testBlockingHooksCarryLongTimeoutAndFailOpenGuard() throws {
        try writeSettings("{}")
        try ClaudeSettingsInstaller().install()

        let hooks = try readSettings()["hooks"] as! [String: Any]
        let group = (hooks["PermissionRequest"] as! [[String: Any]])[0]
        let handler = (group["hooks"] as! [[String: Any]])[0]

        XCTAssertEqual(handler["timeout"] as? Int,
                       ClaudeSettingsInstaller.blockingTimeoutSeconds)
        let command = handler["command"] as! String
        XCTAssertTrue(command.contains("--blocking"))
        XCTAssertTrue(command.hasSuffix("exit 0'"),
                      "a missing launcher must never fail the hook")
        XCTAssertTrue(command.contains("$HOME"),
                      "paths should stay home-relative rather than absolute")
    }

    /// A blocking `PreToolUse` hook holds back Claude Code's own dialog until
    /// it returns. Questions and plans are answered through
    /// `PermissionRequest`, which runs beside that dialog instead.
    func testNothingBlocksInPreToolUse() throws {
        try writeSettings("{}")
        try ClaudeSettingsInstaller().install()

        let hooks = try readSettings()["hooks"] as! [String: Any]
        let groups = hooks["PreToolUse"] as! [[String: Any]]
        XCTAssertEqual(groups.count, 1)
        let handler = (groups[0]["hooks"] as! [[String: Any]])[0]
        XCTAssertNil(handler["timeout"], "the hot path must not be configured as blocking")
        XCTAssertFalse((handler["command"] as! String).contains("--blocking"))

        let permission = (hooks["PermissionRequest"] as! [[String: Any]])[0]
        XCTAssertEqual(permission["matcher"] as? String, "*",
                       "questions and plans arrive here, so it must match every tool")
        XCTAssertNotNil(hooks["PermissionDenied"])
    }

    /// What 0.2 wrote: the same hooks plus a blocking `PreToolUse` group for
    /// the two tools it answered by denying them.
    private func writeLegacyInstall() throws {
        let passive = ClaudeSettingsInstaller.command()
        let blocking = ClaudeSettingsInstaller.command(arguments: "--blocking")
        func group(_ command: String, matcher: String? = nil, timeout: Bool = false) -> String {
            let handler = timeout
                ? #"{"type":"command","command":\#(json(command)),"timeout":86400}"#
                : #"{"type":"command","command":\#(json(command))}"#
            return matcher.map { #"{"matcher":"\#($0)","hooks":[\#(handler)]}"# }
                ?? #"{"hooks":[\#(handler)]}"#
        }
        try writeSettings("""
        {
          "hooks": {
            "PreToolUse": [\(group(passive, matcher: "*")),
                           \(group(blocking, matcher: "ExitPlanMode|AskUserQuestion", timeout: true)),
                           {"matcher":"Bash","hooks":[{"type":"command","command":"other-tool check"}]}],
            "PermissionRequest": [\(group(blocking, matcher: "*", timeout: true))],
            "Stop": [\(group(passive))]
          },
          "statusLine": {"type":"command","command":"/Users/x/.andoncord/bin/andon-statusline"}
        }
        """)
    }

    private func json(_ string: String) -> String {
        String(decoding: try! JSONEncoder().encode(string), as: UTF8.self)
    }

    func testAnOlderInstallIsUpgradedWithoutTouchingAnythingElse() throws {
        try writeLegacyInstall()
        let installer = ClaudeSettingsInstaller()
        XCTAssertTrue(installer.hooksNeedUpgrade)

        try installer.upgradeHooks()

        XCTAssertFalse(installer.hooksNeedUpgrade)
        XCTAssertEqual(installer.currentStatus(), .installed)
        let settings = try readSettings()
        let preToolUse = (settings["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]]
        let commands = preToolUse.flatMap { ($0["hooks"] as! [[String: Any]]).map { $0["command"] as! String } }
        XCTAssertEqual(commands.filter { $0.contains("--blocking") }.count, 0)
        XCTAssertEqual(commands.filter { $0 == "other-tool check" }.count, 1,
                       "another tool's hook must survive the upgrade")
        XCTAssertEqual((settings["statusLine"] as? [String: Any])?["command"] as? String,
                       "/Users/x/.andoncord/bin/andon-statusline")
    }

    func testCommentsAreNotDroppedBehindSomeonesBack() throws {
        try writeLegacyInstall()
        let text = try String(contentsOf: Paths.claudeSettings, encoding: .utf8)
        try writeSettings("// keep this note\n" + text)
        XCTAssertFalse(ClaudeSettingsInstaller().hooksNeedUpgrade,
                       "a rewrite would drop the comment, so it waits for Repair")
    }
}

final class JSONCTests: XCTestCase {
    func testDoesNotStripCommentMarkersInsideStrings() {
        let source = #"{ "url": "https://example.com//path", "note": "a /* b */ c" }"#
        let stripped = JSONC.stripComments(source)
        XCTAssertTrue(stripped.contains("https://example.com//path"))
        XCTAssertTrue(stripped.contains("a /* b */ c"))
    }

    func testHandlesEscapedQuotesBeforeComments() {
        let source = #"{ "a": "he said \"hi\"" } // trailing"#
        let parsed = try? JSONC.parseObject(source)
        XCTAssertEqual(parsed?["a"] as? String, #"he said "hi""#)
    }

    func testEmptyFileParsesAsEmptyObject() throws {
        XCTAssertTrue(try JSONC.parseObject("   \n  ").isEmpty)
    }
}
