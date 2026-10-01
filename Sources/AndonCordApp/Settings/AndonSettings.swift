import Foundation
import Observation
import ServiceManagement

/// User preferences, backed by `UserDefaults`.
@Observable
@MainActor
final class AndonSettings {
    private enum Key {
        static let soundsEnabled = "soundsEnabled"
        static let volume = "soundVolume"
        static let autoExpand = "autoExpandOnCord"
        static let showUsage = "showUsage"
        static let preferredDisplay = "preferredDisplayName"
        static let hideWhenIdle = "hideWhenIdle"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let quietWhileFocused = "quietWhileFocused"
        static let migratedAlwaysVisiblePill = "migratedAlwaysVisiblePill"
        static let exactUsage = "exactUsageFromAnthropic"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.soundsEnabled: true,
            Key.volume: 0.5,
            Key.autoExpand: true,
            Key.showUsage: true,
            // Off by default: a pill that vanishes when the board empties made
            // "is it broken or just idle?" unanswerable. The idle pill now
            // shows a red stopped lamp instead — visible proof of both states.
            Key.hideWhenIdle: false,
            Key.hasCompletedOnboarding: false,
            Key.quietWhileFocused: true,
            Key.exactUsage: false,
        ])

        // One-time migration for installs that predate the new default. A
        // registered default only wins when no value was ever stored, so
        // without this, anyone whose toggle was written back while the old
        // default was `true` would never see the change.
        if !defaults.bool(forKey: Key.migratedAlwaysVisiblePill) {
            defaults.removeObject(forKey: Key.hideWhenIdle)
            defaults.set(true, forKey: Key.migratedAlwaysVisiblePill)
        }
    }

    var soundsEnabled: Bool {
        get { defaults.bool(forKey: Key.soundsEnabled) }
        set { defaults.set(newValue, forKey: Key.soundsEnabled) }
    }

    var volume: Double {
        get { defaults.double(forKey: Key.volume) }
        set { defaults.set(newValue, forKey: Key.volume) }
    }

    /// Whether a pulled cord opens the panel on its own.
    ///
    /// On by default: the point of the app is that you find out without
    /// looking, and an alert you have to go and open is a worse notification
    /// than the terminal bell it replaces.
    var autoExpandOnCord: Bool {
        get { defaults.bool(forKey: Key.autoExpand) }
        set { defaults.set(newValue, forKey: Key.autoExpand) }
    }

    var showUsage: Bool {
        get { defaults.bool(forKey: Key.showUsage) }
        set { defaults.set(newValue, forKey: Key.showUsage) }
    }

    /// Ask Anthropic for the quota instead of inferring it.
    ///
    /// Off by default because it is the one thing AndonCord does over the
    /// network: Claude Code's sign-in token, read from the Keychain, sent to
    /// Anthropic's usage endpoint every five minutes. Everything else stays
    /// on the Mac whichever way this is set.
    var exactUsage: Bool {
        get { defaults.bool(forKey: Key.exactUsage) }
        set { defaults.set(newValue, forKey: Key.exactUsage) }
    }

    /// Which display the board lives on, by `localizedName`. `nil` means
    /// automatic: the built-in notched screen when present, otherwise the
    /// screen with the pointer. Explicit choice matters for docked setups
    /// where the notched MacBook screen is off to the side and the user
    /// actually looks at the external monitor.
    var preferredDisplayName: String? {
        get { defaults.string(forKey: Key.preferredDisplay) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.preferredDisplay) }
            else { defaults.removeObject(forKey: Key.preferredDisplay) }
        }
    }

    /// Hide the pill entirely when nothing is running, so the notch looks
    /// stock while you are not using Claude Code.
    var hideWhenIdle: Bool {
        get { defaults.bool(forKey: Key.hideWhenIdle) }
        set { defaults.set(newValue, forKey: Key.hideWhenIdle) }
    }

    /// Respect macOS Focus and screen sharing by staying silent.
    var quietWhileFocused: Bool {
        get { defaults.bool(forKey: Key.quietWhileFocused) }
        set { defaults.set(newValue, forKey: Key.quietWhileFocused) }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Unsigned development builds cannot register a login item.
                // Surfacing this as a thrown error would be noise; the toggle
                // simply reads back false.
                AndonLog.ui.error("Login item change failed: \(error.localizedDescription)")
            }
        }
    }
}
