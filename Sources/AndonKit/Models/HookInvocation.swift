import Foundation

/// How `andon-hook` was invoked, and whether it should act at all.
///
/// Pulled out of the shim so the one decision that must never go wrong — do
/// the work, or exit 0 having touched nothing — can be tested without spawning
/// a process.
public struct HookInvocation: Equatable, Sendable {
    /// `--statusline`: cache `rate_limits` and chain to the user's own
    /// statusline, rather than forward a hook event.
    public var isStatusline: Bool
    /// `--blocking`: set by the installer only on the hooks where a human
    /// decision is expected, so the common path never waits on a reply.
    public var isBlocking: Bool
    /// Whether this command line belongs to a Claude Code hook.
    ///
    /// 0.1.x also wrote hooks into Codex, Gemini CLI and Cursor, each tagged
    /// `--source codex|gemini|cursor`. Those entries sit in files that are the
    /// user's to clean up, not ours, so they go on firing long after this build
    /// stopped understanding them. Claude's own entries never carried
    /// `--source` at all, which makes an absent tag mean Claude Code.
    public var isClaudeCode: Bool

    public init(arguments: [String]) {
        isStatusline = arguments.contains("--statusline")
        isBlocking = arguments.contains("--blocking")
        if let index = arguments.firstIndex(of: "--source"), index + 1 < arguments.count {
            isClaudeCode = ["claude", "claude-code"].contains(arguments[index + 1].lowercased())
        } else {
            isClaudeCode = true
        }
    }

    /// Whether a hook payload came from Claude Code itself.
    ///
    /// Cursor imports `~/.claude/settings.json` and runs the hooks it finds
    /// there, by default — so the entries AndonCord writes for Claude fire for
    /// Cursor sessions too, carrying Cursor's payload. Every one of those has
    /// `cursor_version`; nothing Claude Code sends does.
    public static func isFromClaudeCode(_ payload: JSONValue) -> Bool {
        payload["cursor_version"] == nil
    }
}
