import Foundation

/// Installs, verifies, and removes AndonCord's wiring in `~/.claude/settings.json`.
///
/// This is the only file outside `~/.andoncord` that we ever write, and it is
/// a file the user (and Claude Code, and possibly other notch apps) also
/// writes. The rules here follow from that:
///
///   * **Additive.** We append our handler to existing matcher groups. Another
///     tool's hooks keep working alongside ours; Claude Code runs every
///     handler registered for an event.
///   * **Backed up.** Every write snapshots the previous file first.
///   * **Idempotent.** Reinstalling removes our old entries by marker, then
///     re-adds, so repeated installs cannot stack duplicates.
///   * **Exactly reversible.** Uninstall strips only entries carrying our
///     marker and restores the displaced `statusLine` verbatim.
public struct ClaudeSettingsInstaller {
    /// Substring that identifies a hook entry as ours. Every command we write
    /// contains it, and uninstall matches on it.
    public static let marker = ".andoncord/bin/andon-hook"

    /// Claude Code's own hook timeout for a blocking hook. A permission
    /// request should be able to sit on the board as long as it would sit in
    /// the terminal, so this is deliberately long rather than a UI-friendly
    /// few seconds.
    public static let blockingTimeoutSeconds = 86_400

    public enum Status: Equatable {
        case notInstalled
        /// Installed and matching what this version would write.
        case installed
        /// Our marker is present but the entries differ — usually an app
        /// upgrade, or another tool rewrote the file.
        case drifted(reason: String)
        case settingsUnreadable(reason: String)
    }

    public struct Report {
        public var status: Status
        public var backupURL: URL?
        /// True when the settings file carried comments that a rewrite drops.
        public var commentsWillBeLost: Bool
        public var displacedStatusline: String?
    }

    public init() {}

    // MARK: - Command construction

    /// The shell command Claude Code runs for a hook.
    ///
    /// Two deliberate details:
    ///   * `$HOME` rather than an absolute path, so the entry survives a
    ///     different home directory and reads sensibly in a shared dotfile.
    ///   * `; exit 0` so a missing or broken launcher can never fail a hook
    ///     and interrupt someone's session.
    static func command(arguments: String = "") -> String {
        let launcher = "\"$HOME/\(marker)\""
        let invocation = arguments.isEmpty
            ? "\(launcher)" : "\(launcher) \(arguments)"
        return "/bin/sh -c '[ -x \(launcher) ] && \(invocation); exit 0'"
    }

    private func handler(arguments: String = "", blocking: Bool = false) -> [String: Any] {
        var entry: [String: Any] = [
            "type": "command",
            "command": Self.command(arguments: arguments),
        ]
        if blocking { entry["timeout"] = Self.blockingTimeoutSeconds }
        return entry
    }

    /// The full set of hook groups this version installs.
    ///
    /// Only events that drive the board are registered — every extra hook is a
    /// process spawn on the user's critical path.
    func desiredGroups() -> [String: [[String: Any]]] {
        let passive = handler()
        let blocking = handler(arguments: "--blocking", blocking: true)

        return [
            // Lifecycle: create and retire stations.
            HookEventName.sessionStart.rawValue: [["hooks": [passive]]],
            HookEventName.sessionEnd.rawValue: [["hooks": [passive]]],
            // Gives us the session title before Claude has generated one.
            HookEventName.userPromptSubmit.rawValue: [["hooks": [passive]]],

            // Activity stream. Never blocking: a `PreToolUse` hook that waits
            // holds back Claude Code's own dialog until it returns, which
            // would leave a person at the terminal unable to answer there.
            HookEventName.preToolUse.rawValue: [["matcher": "*", "hooks": [passive]]],
            HookEventName.postToolUse.rawValue: [["matcher": "*", "hooks": [passive]]],
            HookEventName.postToolUseFailure.rawValue: [["matcher": "*", "hooks": [passive]]],
            // Auto mode turning a call down. Rare, and otherwise invisible.
            HookEventName.permissionDenied.rawValue: [["matcher": "*", "hooks": [passive]]],

            // The cord itself — permissions, questions and plans alike. Claude
            // Code shows its own dialog while this runs, and whichever answer
            // comes first wins, so the terminal keeps working as it always did.
            HookEventName.permissionRequest.rawValue: [
                ["matcher": "*", "hooks": [blocking]],
            ],
            HookEventName.notification.rawValue: [["matcher": "*", "hooks": [passive]]],
            // MCP servers asking for input. Passive on purpose: Claude Code
            // waits for these hooks before showing its own form, so the
            // board describes the request and never holds it.
            HookEventName.elicitation.rawValue: [["hooks": [passive]]],
            HookEventName.elicitationResult.rawValue: [["hooks": [passive]]],

            // Turn boundaries.
            HookEventName.stop.rawValue: [["hooks": [passive]]],
            HookEventName.stopFailure.rawValue: [["hooks": [passive]]],
            HookEventName.subagentStart.rawValue: [["hooks": [passive]]],
            HookEventName.subagentStop.rawValue: [["hooks": [passive]]],
        ]
    }

    // MARK: - Reading

    public func readSettings() throws -> (object: [String: Any], hadComments: Bool) {
        let url = Paths.claudeSettings
        guard FileManager.default.fileExists(atPath: url.path) else { return ([:], false) }
        let text = try String(contentsOf: url, encoding: .utf8)
        return (try JSONC.parseObject(text), JSONC.containsComments(text))
    }

    public func currentStatus() -> Status {
        let settings: [String: Any]
        do {
            settings = try readSettings().object
        } catch {
            return .settingsUnreadable(reason: error.localizedDescription)
        }

        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        var foundMarker = false
        var missingEvents: [String] = []

        for (event, groups) in desiredGroups() {
            let installed = hooks[event] as? [[String: Any]] ?? []
            let ours = installed.filter { groupCarriesMarker($0) }
            if ours.isEmpty {
                missingEvents.append(event)
            } else {
                foundMarker = true
                // Compare handler count so a version that adds a group is
                // treated as drift rather than silently under-installed.
                if ours.count != groups.count { missingEvents.append(event) }
            }
        }

        // Events an earlier version registered and this one no longer does.
        for (event, groups) in hooks where desiredGroups()[event] == nil {
            if let groups = groups as? [[String: Any]], groups.contains(where: groupCarriesMarker) {
                foundMarker = true
                missingEvents.append(event)
            }
        }

        guard foundMarker else { return .notInstalled }
        if !missingEvents.isEmpty {
            return .drifted(reason: "\(Self.outdatedHooksPrefix)\(missingEvents.sorted().joined(separator: ", "))")
        }

        let statusline = settings["statusLine"] as? [String: Any]
        let statuslineCommand = statusline?["command"] as? String ?? ""
        if !statuslineCommand.contains("andon-statusline") {
            return .drifted(reason: "statusline not installed")
        }
        return .installed
    }

    static let outdatedHooksPrefix = "hooks out of date: "

    /// Whether our hooks are present but were written by a different version,
    /// and can be brought up to date without losing anything.
    ///
    /// That is the one drift worth fixing without asking: the person already
    /// agreed to these entries, and an app update changing what it needs is
    /// not a new decision. Anything else — the statusline taken back, the
    /// file unreadable, comments a rewrite would drop — is left for them to
    /// repair.
    public var hooksNeedUpgrade: Bool {
        guard case .drifted(let reason) = currentStatus(),
              reason.hasPrefix(Self.outdatedHooksPrefix)
        else { return false }
        return (try? readSettings().hadComments) == false
    }

    /// Rewrite our hook entries to this version's set, leaving everything
    /// else — other tools' hooks, the statusline — exactly as it is.
    @discardableResult
    public func upgradeHooks() throws -> URL? {
        try Paths.ensureDirectories()
        try LauncherWriter.writeLaunchers()
        let (existing, _) = try readSettings()
        let backup = try makeBackup()

        var settings = existing
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let desired = desiredGroups()
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let remaining = groups.compactMap { groupWithoutMarker($0) }
            if remaining.isEmpty, desired[event] == nil {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = remaining
            }
        }
        for (event, groups) in desired {
            hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + groups
        }
        settings["hooks"] = hooks
        try writeAtomically(settings, to: Paths.claudeSettings)
        return backup
    }

    private func groupCarriesMarker(_ group: [String: Any]) -> Bool {
        guard let handlers = group["hooks"] as? [[String: Any]] else {
            return (group["command"] as? String)?.contains(Self.marker) ?? false
        }
        return handlers.contains { ($0["command"] as? String)?.contains(Self.marker) ?? false }
    }

    /// Strip our handlers from a group, returning nil when nothing is left.
    private func groupWithoutMarker(_ group: [String: Any]) -> [String: Any]? {
        guard var handlers = group["hooks"] as? [[String: Any]] else {
            return groupCarriesMarker(group) ? nil : group
        }
        handlers.removeAll { ($0["command"] as? String)?.contains(Self.marker) ?? false }
        if handlers.isEmpty { return nil }
        var updated = group
        updated["hooks"] = handlers
        return updated
    }

    // MARK: - Install

    @discardableResult
    public func install() throws -> Report {
        try Paths.ensureDirectories()
        try LauncherWriter.writeLaunchers()

        let url = Paths.claudeSettings
        let (existing, hadComments) = try readSettings()
        let backup = try makeBackup()

        var settings = existing
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for (event, desired) in desiredGroups() {
            var groups = hooks[event] as? [[String: Any]] ?? []
            // Remove any previous entries of ours first, so reinstalling after
            // an upgrade replaces rather than stacks.
            groups = groups.compactMap { groupWithoutMarker($0) }
            groups.append(contentsOf: desired)
            hooks[event] = groups
        }
        settings["hooks"] = hooks

        // Take over statusLine, remembering whatever was there.
        let displaced = try installStatusline(into: &settings)

        try writeAtomically(settings, to: url)

        return Report(
            status: .installed,
            backupURL: backup,
            commentsWillBeLost: hadComments,
            displacedStatusline: displaced)
    }

    /// Point `statusLine` at our shim and persist the previous entry.
    ///
    /// Claude Code exposes `rate_limits` on the statusline payload and nowhere
    /// else, so this is the only way to show real quota. Because only one
    /// statusline can exist, we chain: our shim invokes the displaced command
    /// with the identical stdin, so an existing statusline keeps rendering.
    private func installStatusline(into settings: inout [String: Any]) throws -> String? {
        let existing = settings["statusLine"] as? [String: Any]
        let existingCommand = existing?["command"] as? String

        // Re-installing over ourselves must not overwrite the saved chain with
        // our own launcher, which would make uninstall restore a dangling entry.
        let alreadyOurs = existingCommand?.contains("andon-statusline") ?? false

        if !alreadyOurs {
            let chain = StatuslineChain(
                command: existingCommand,
                type: existing?["type"] as? String,
                padding: existing?["padding"] as? Int,
                refreshInterval: existing?["refreshInterval"] as? Int,
                wasAbsent: existing == nil)
            if let data = try? JSONEncoder().encode(chain) {
                try? data.write(to: Paths.statuslineChain, options: .atomic)
            }
        }

        var statusline: [String: Any] = [
            "type": "command",
            "command": Paths.statuslineLauncher.path,
        ]
        // Preserve presentation settings the user chose for their statusline.
        if let padding = existing?["padding"] { statusline["padding"] = padding }
        if let refresh = existing?["refreshInterval"] { statusline["refreshInterval"] = refresh }
        settings["statusLine"] = statusline

        return alreadyOurs ? nil : existingCommand
    }

    // MARK: - Uninstall

    @discardableResult
    public func uninstall() throws -> URL? {
        let url = Paths.claudeSettings
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var settings = try readSettings().object
        let backup = try makeBackup()

        if var hooks = settings["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                let remaining = groups.compactMap { groupWithoutMarker($0) }
                if remaining.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = remaining
                }
            }
            if hooks.isEmpty {
                settings.removeValue(forKey: "hooks")
            } else {
                settings["hooks"] = hooks
            }
        }

        restoreStatusline(in: &settings)
        try writeAtomically(settings, to: url)
        return backup
    }

    private func restoreStatusline(in settings: inout [String: Any]) {
        let current = settings["statusLine"] as? [String: Any]
        let isOurs = (current?["command"] as? String)?.contains("andon-statusline") ?? false
        guard isOurs else { return }

        guard let data = try? Data(contentsOf: Paths.statuslineChain),
              let chain = try? JSONDecoder().decode(StatuslineChain.self, from: data)
        else {
            // No record of what was there. Removing the key is safer than
            // leaving a pointer to a launcher we are about to delete.
            settings.removeValue(forKey: "statusLine")
            return
        }

        if chain.wasAbsent || chain.command == nil {
            settings.removeValue(forKey: "statusLine")
        } else {
            var restored: [String: Any] = ["command": chain.command!]
            restored["type"] = chain.type ?? "command"
            if let padding = chain.padding { restored["padding"] = padding }
            if let refresh = chain.refreshInterval { restored["refreshInterval"] = refresh }
            settings["statusLine"] = restored
        }
        try? FileManager.default.removeItem(at: Paths.statuslineChain)
    }

    // MARK: - Safe writes

    private func makeBackup() throws -> URL? {
        let source = Paths.claudeSettings
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        try Paths.ensureDirectories()

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let name = "settings-\(stamp.string(from: Date()).replacingOccurrences(of: ":", with: "-")).json"
        let destination = Paths.backups.appendingPathComponent(name)

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        pruneBackups()
        return destination
    }

    /// Keep the last 20 backups; this directory should never grow unbounded.
    private func pruneBackups() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Paths.backups, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let sorted = entries
            .filter { $0.lastPathComponent.hasPrefix("settings-") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return a > b
            }
        for stale in sorted.dropFirst(20) { try? fm.removeItem(at: stale) }
    }

    private func writeAtomically(_ settings: [String: Any], to url: URL) throws {
        let data = try JSONC.serialize(settings)
        // `.atomic` writes to a sibling temp file and renames, so a crash
        // mid-write cannot leave Claude Code with a truncated settings file.
        try data.write(to: url, options: .atomic)
        Log.install.info("Wrote \(url.path, privacy: .public)")
    }
}
