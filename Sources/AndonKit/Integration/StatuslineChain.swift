import Foundation

/// Records the `statusLine` configuration that was in place before AndonCord
/// took it over.
///
/// Only one statusline command can be configured at a time, so installing ours
/// necessarily displaces whatever was there. Rather than refuse to install, or
/// silently discard someone else's statusline, we remember it and invoke it
/// from our shim with the identical payload — their output still renders, and
/// uninstall restores the original entry byte for byte.
public struct StatuslineChain: Codable, Sendable {
    /// The displaced `statusLine.command`, if there was one.
    public var command: String?
    /// The displaced `statusLine.type`, preserved for exact restoration.
    public var type: String?
    public var padding: Int?
    public var refreshInterval: Int?
    /// Set when there was no prior statusline, so uninstall removes the key
    /// entirely instead of writing back an empty one.
    public var wasAbsent: Bool

    public init(
        command: String? = nil, type: String? = nil,
        padding: Int? = nil, refreshInterval: Int? = nil,
        wasAbsent: Bool = false
    ) {
        self.command = command
        self.type = type
        self.padding = padding
        self.refreshInterval = refreshInterval
        self.wasAbsent = wasAbsent
    }

    /// The command to hand the payload on to, or nil when there is none —
    /// or when it is AndonCord's own statusline. A chain that leads back to
    /// itself starts a copy of itself on every redraw, each of which starts
    /// another; another notch app shipped exactly that and forked thousands
    /// of processes. The installer never records itself, but a chain file is
    /// only a file, and this is the last place it can be caught.
    public var forwardCommand: String? {
        guard let command, !command.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard !command.contains("andon-statusline"),
              !command.contains(ClaudeSettingsInstaller.marker),
              !command.contains("AndonCord.app/Contents/MacOS/andon-hook")
        else { return nil }
        return command
    }
}
