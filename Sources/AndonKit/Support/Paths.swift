import Foundation

/// Every on-disk location AndonCord touches, in one place.
///
/// Everything the app owns lives under `~/.andoncord`. The only file outside
/// that tree we ever write is `~/.claude/settings.json`, and that write is
/// always additive + backed up (see `ClaudeSettingsInstaller`).
public enum Paths {
    /// Redirects every path below a different root.
    ///
    /// Exists so the installer can be exercised against a throwaway copy of a
    /// real `settings.json` — the merge logic is the one part of this codebase
    /// that can damage something the user cares about, and it needs to be
    /// testable without pointing it at their actual config.
    nonisolated(unsafe) public static var homeOverride: URL?

    public static var home: URL {
        if let homeOverride { return homeOverride }
        // `NSHomeDirectory()` resolves through the password database and
        // ignores `$HOME`, so a subprocess cannot be redirected by setting it.
        // This gives the shim an explicit, inheritable override — needed to
        // point a spawned `andon-hook` at a test socket, and useful when
        // debugging against a scratch config.
        if let path = ProcessInfo.processInfo.environment["ANDON_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    /// `~/.andoncord`
    public static var root: URL { home.appendingPathComponent(".andoncord") }

    /// Launcher script + any cached bundle location.
    public static var bin: URL { root.appendingPathComponent("bin") }
    /// Socket and pidfile. Recreated on every launch.
    public static var run: URL { root.appendingPathComponent("run") }
    /// Backups of files we modified outside our own tree.
    public static var backups: URL { root.appendingPathComponent("backups") }
    /// User-supplied sound packs.
    public static var sounds: URL { root.appendingPathComponent("sounds") }

    /// The shim Claude Code invokes. A shell launcher, not the binary itself,
    /// so that moving or updating the .app never breaks an installed hook.
    public static var hookLauncher: URL { bin.appendingPathComponent("andon-hook") }
    public static var statuslineLauncher: URL { bin.appendingPathComponent("andon-statusline") }
    /// Written by the launcher when it locates the bundle via Spotlight.
    public static var bundleCache: URL { bin.appendingPathComponent(".bundle-cache") }

    public static var socket: URL { run.appendingPathComponent("andon.sock") }
    public static var pidFile: URL { run.appendingPathComponent("andon.pid") }

    /// Where the statusline shim parks the `rate_limits` blob it sees.
    public static var rateLimitsCache: URL { root.appendingPathComponent("rate-limits.json") }
    /// Records what `statusLine.command` was before we took it over, so
    /// uninstall can put it back exactly.
    public static var statuslineChain: URL { root.appendingPathComponent("statusline-chain.json") }
    /// Indexed transcript totals. Pure derived data — deleting it costs one
    /// re-scan and nothing else.
    public static var usageIndex: URL { root.appendingPathComponent("usage-index.json") }
    /// Append-only log of quota readings. Two readings are all it takes to
    /// know whether the current pace fits in the window that is left, and
    /// Claude Code exposes only the instantaneous percentage.
    public static var usageHistory: URL { root.appendingPathComponent("usage-history.jsonl") }
    /// The learned scale between measured spend and Claude Code's percentages.
    public static var quotaCalibration: URL { root.appendingPathComponent("quota-calibration.json") }

    public static var claudeDir: URL { home.appendingPathComponent(".claude") }

    /// The Claude desktop app's own quota record, sampled every five minutes.
    /// Read-only, and the best quota source on the machine — see `PlanUsage`.
    public static var planUsageHistory: URL {
        home
            .appendingPathComponent("Library/Application Support/Claude")
            .appendingPathComponent("plan-usage-history.json")
    }
    public static var claudeSettings: URL { claudeDir.appendingPathComponent("settings.json") }

    /// Socket paths are capped at 104 bytes on Darwin (`sun_path`). A long
    /// username can push `~/.andoncord/run/andon.sock` past that, so callers
    /// need a way to find out before they try to bind.
    public static var socketPathFitsInSunPath: Bool {
        socket.path.utf8.count < 104
    }

    public static func ensureDirectories() throws {
        for dir in [root, bin, run, backups, sounds] {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                // Session titles and prompts pass through here; keep it private.
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
}
