import AndonKit
import AppKit
import Carbon.HIToolbox

/// The board's system-wide shortcuts: ⌃⌥Y allow, ⌃⌥N deny, ⌃⌥A always allow,
/// ⌃⌥B show or hide the board.
///
/// The card's own ⌘Y / ⌘N only reach it while the panel has keyboard focus,
/// and a panel that never steals focus almost never does — so in practice
/// they worked only after a click. These are Carbon hot keys
/// (`RegisterEventHotKey`), which fire from whichever app is in front and,
/// unlike a global key monitor, need no Accessibility permission.
///
/// What a press does is `CardShortcut`'s business; this type only owns the
/// registrations and routes a press to the board.
@MainActor
final class BoardShortcuts {
    private let app: AppState
    private let notch: NotchController
    private var registered: [UInt32: (ref: EventHotKeyRef, shortcut: CardShortcut)] = [:]
    private var handler: EventHandlerRef?

    /// "ANDN": tags our hot keys, so a press is ours to route.
    private static let signature: OSType = "ANDN".utf8.reduce(0) { ($0 << 8) | OSType($1) }

    init(app: AppState, notch: NotchController) {
        self.app = app
        self.notch = notch
    }

    /// Register or drop the shortcuts to match the setting.
    func apply() {
        unregisterAll()
        guard app.settings.globalShortcuts else { return }
        installHandler()
        for (index, shortcut) in CardShortcut.allCases.enumerated() {
            guard let keyCode = Self.keyCode(for: shortcut.key) else { continue }
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                keyCode, UInt32(controlKey | optionKey), id,
                GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[id.id] = (ref, shortcut)
            } else {
                // Taken by another app. The rest still work, and the card's
                // own ⌘ shortcuts are unaffected.
                AndonLog.ui.error("Hot key \(shortcut.label) unavailable (\(status))")
            }
        }
    }

    func unregisterAll() {
        for entry in registered.values { UnregisterEventHotKey(entry.ref) }
        registered.removeAll()
    }

    fileprivate func fired(id: UInt32) {
        guard let shortcut = registered[id]?.shortcut else { return }
        perform(shortcut)
    }

    func perform(_ shortcut: CardShortcut) {
        if shortcut == .toggleBoard {
            notch.toggleExpanded(revealing: true)
            return
        }
        // The card the panel shows: the first session waiting on a person.
        let request = app.board.sessionsNeedingHuman.first?.pending
        let effect = shortcut.effect(on: request, cardOnScreen: notch.isShowingCard)
        switch effect {
        case .reveal: notch.reveal()
        case .approve: request.map { app.board.approve($0) }
        case .approveAlways(let suggestion): request.map { app.board.approve($0, always: suggestion) }
        case .deny: request.map { app.board.deny($0) }
        case .approvePlan: request.map { app.board.approvePlan($0) }
        case .keepPlanning: request.map { app.board.rejectPlan($0, feedback: "") }
        case .ignore: NSSound.beep()
        }
        if effect != .reveal, effect != .ignore {
            // Another request may be next in line; only an empty board closes.
            if app.board.sessionsNeedingHuman.isEmpty { notch.shortcutActed() }
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(), boardShortcutHandler, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// US-layout virtual key codes for the letters we bind. Carbon hot keys
    /// are positional, which is what people expect of ⌃⌥ chords.
    private static func keyCode(for key: Character) -> UInt32? {
        switch key {
        case "Y": return UInt32(kVK_ANSI_Y)
        case "N": return UInt32(kVK_ANSI_N)
        case "A": return UInt32(kVK_ANSI_A)
        case "B": return UInt32(kVK_ANSI_B)
        default: return nil
        }
    }
}

/// C entry point for Carbon: find our hot key's id and hand it back.
private func boardShortcutHandler(
    _ call: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let shortcuts = Unmanaged<BoardShortcuts>.fromOpaque(context).takeUnretainedValue()
    let hotKey = id.id
    // Carbon calls back on the main thread for the application event target.
    MainActor.assumeIsolated { shortcuts.fired(id: hotKey) }
    return noErr
}
