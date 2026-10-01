import AndonKit
import AppKit
import Observation
import os

enum AndonLog {
    static let ui = Logger(subsystem: "app.andoncord", category: "app")
}

/// Wires the pieces together and owns their lifecycle.
///
/// Deliberately thin: the board holds state, the server holds transport, the
/// installer holds the on-disk contract. This just starts them in the right
/// order and routes between them.
@Observable
@MainActor
final class AppState {
    let board = BoardStore()
    /// Token accounting, read from Claude Code's own transcripts.
    let ledger = UsageLedger()
    /// Quota, read from the Claude desktop app's own five-minute record. The
    /// statusline cache in `BoardStore` is the fallback for machines without
    /// the desktop app.
    let planUsage = PlanUsageStore()
    let settings = AndonSettings()
    let installer = ClaudeSettingsInstaller()
    let codexInstaller = CodexHooksInstaller()
    let geminiInstaller = GeminiHooksInstaller()
    let cursorInstaller = CursorHooksInstaller()

    @ObservationIgnored
    private let server = HookServer()
    @ObservationIgnored
    private let chiptune = ChiptuneEngine()

    /// Surfaced in the menu bar and settings so a broken install is visible
    /// rather than presenting as "the app just doesn't work".
    private(set) var installStatus: ClaudeSettingsInstaller.Status = .notInstalled
    private(set) var codexStatus: CodexHooksInstaller.Status = .notInstalled
    private(set) var geminiStatus: GeminiHooksInstaller.Status = .notInstalled
    private(set) var cursorStatus: CursorHooksInstaller.Status = .notInstalled
    private(set) var serverError: String?
    /// Set when another copy of the app already owns the socket.
    private(set) var duplicateInstancePID: pid_t?

    /// Opens the real settings window. Wired by `MenuBarController`, which
    /// owns the window. The notch panel calls this instead of presenting a
    /// SwiftUI sheet — a sheet attaches to the fixed-size notch window and
    /// floats inside its transparent expanse, which looks like a dialog lost
    /// on a black field.
    @ObservationIgnored
    var openSettingsWindow: (() -> Void)?
    /// Same arrangement for the usage breakdown window.
    @ObservationIgnored
    var openUsageWindow: (() -> Void)?

    /// The learned scale between measured spend and Claude Code's quota
    /// percentages. Persisted, because a reading may be days apart from the
    /// moment it is needed.
    private(set) var calibration = QuotaCalibration.load()

    init() {
        board.onSound = { [weak self] sound in self?.playSound(sound) }
        board.onQuotaSample = { [weak self] snapshot in self?.calibrate(against: snapshot) }
        // The reading that lands at launch is paired against whatever the
        // index held at that instant, which on a first run is nothing. Every
        // completed pass is a chance to do that pairing properly.
        ledger.onIndexed = { [weak self] in
            guard let self else { return }
            if let status = self.board.status { self.calibrate(against: status) }
            self.calibrateAgainstPlanRecord()
        }
    }

    // MARK: - Quota

    /// Memo for `quotaReadout`.
    ///
    /// The collapsed pill draws its quota meter, and the pill's body is
    /// re-evaluated every frame while a session is working — the lamp is a
    /// real animation, not a two-state pulse. Summing a year of ledger buckets
    /// sixty times a second to redraw five segments is not a trade worth
    /// making, and none of the inputs move at anything like that rate.
    @ObservationIgnored
    private var readoutCache: [QuotaWindowKind: (key: ReadoutKey, value: QuotaReadout)] = [:]

    /// Everything a readout depends on that can actually change, plus a
    /// coarse clock so countdowns still tick.
    private struct ReadoutKey: Equatable {
        var indexedAt: Date?
        var planReadAt: Date?
        var capturedAt: Date?
        var tick: Int
    }

    /// The best available figure for one window, and an honest label for where
    /// it came from.
    ///
    /// Three sources, in descending order of how much they can be trusted:
    /// the desktop app's five-minute record, the statusline cache, and — only
    /// when both have gone quiet — spend measured from the transcripts scaled
    /// against whatever real reading was seen last.
    func quotaReadout(_ kind: QuotaWindowKind, now: Date = Date()) -> QuotaReadout {
        let key = ReadoutKey(
            indexedAt: ledger.indexedAt,
            planReadAt: planUsage.readAt,
            capturedAt: board.status?.capturedAt,
            tick: Int(now.timeIntervalSinceReferenceDate / 15))
        if let cached = readoutCache[kind], cached.key == key { return cached.value }
        let readout = computeQuotaReadout(kind, now: now)
        readoutCache[kind] = (key, readout)
        return readout
    }

    private func computeQuotaReadout(_ kind: QuotaWindowKind, now: Date) -> QuotaReadout {
        let spent = ledger.total(since: windowStart(kind, now: now))
        if let plan = planUsage.readout(kind, spent: spent, now: now) {
            // The desktop app only polls while its usage tray has been opened
            // in the last day, so its record can stop for hours with the app
            // still running. A stale reading from it is carried forward by
            // measured spend, exactly as a stale statusline one is, rather
            // than drawn frozen at whatever it last saw.
            guard case .reported(let at, stale: true) = plan.source,
                  let used = plan.usedPercentage else { return plan }
            let window = RateLimitWindow(usedPercentage: used, resetsAt: plan.resetsAt)
            return QuotaReadout.compose(
                kind: kind,
                inputs: .init(
                    limits: kind == .fiveHour
                        ? RateLimits(fiveHour: window) : RateLimits(sevenDay: window),
                    capturedAt: at,
                    isStale: true,
                    spentInWindow: spent,
                    spentSinceReading: ledger.total(since: at),
                    calibration: calibration,
                    samples: quotaSamples(for: kind)),
                now: now)
        }

        let status = board.status
        return QuotaReadout.compose(
            kind: kind,
            inputs: .init(
                limits: board.rateLimits,
                capturedAt: status?.capturedAt,
                isStale: status?.isStale ?? true,
                spentInWindow: spent,
                spentSinceReading: status.map { ledger.total(since: $0.capturedAt) } ?? TokenUsage(),
                calibration: calibration,
                samples: quotaSamples(for: kind)),
            now: now)
    }

    /// When the window currently in force opened, for scoping spend to it.
    func windowStart(_ kind: QuotaWindowKind, now: Date = Date()) -> Date {
        planUsage.windowStart(kind, now: now)
            ?? kind.windowStart(limits: board.rateLimits, now: now)
    }

    /// Readings to measure pace from. The desktop app's series is denser and
    /// far longer than anything the statusline produces, so it wins when it
    /// has anything to offer.
    func quotaSamples(for kind: QuotaWindowKind) -> [QuotaSample] {
        let plan = planUsage.samples.filter { $0.value(for: kind) != nil }
        return plan.isEmpty ? board.quotaHistory.samples(for: kind) : plan
    }

    /// Whichever window will stop you first.
    func bindingQuota(now: Date = Date()) -> QuotaReadout? {
        QuotaWindowKind.allCases
            .map { quotaReadout($0, now: now) }
            .filter { $0.usedPercentage != nil }
            .max { ($0.usedPercentage ?? 0) < ($1.usedPercentage ?? 0) }
    }

    /// Learn the cap from a reading and the spend that produced it.
    ///
    /// Age is not disqualifying, and that matters: someone who works mostly
    /// through the desktop app may have exactly one statusline reading on
    /// disk, weeks old. It is still a perfectly good calibration — the window
    /// it described is reconstructible from its own reset time, and the
    /// transcripts still hold every request that went into it.
    ///
    /// What *is* disqualifying is measuring past the reading: the percentage
    /// knows nothing about requests made after it was taken, so the interval
    /// is clipped at `capturedAt`.
    private func calibrate(against snapshot: StatusSnapshot) {
        guard let limits = snapshot.rateLimits else { return }
        var updated = calibration
        for kind in QuotaWindowKind.allCases {
            guard let window = limits.window(kind) else { continue }
            let end = min(window.resetsAt ?? snapshot.capturedAt, snapshot.capturedAt)
            let start = (window.resetsAt ?? snapshot.capturedAt)
                .addingTimeInterval(-kind.length)
            guard start < end else { continue }
            updated.observe(
                kind: kind, usedPercentage: window.usedPercentage,
                spent: ledger.total(in: start..<end), at: snapshot.capturedAt)
        }
        guard updated != calibration else { return }
        calibration = updated
        updated.save()
    }

    /// The same, against the desktop app's record.
    ///
    /// The statusline fires only while a terminal session draws one, so on a
    /// machine worked mostly through the desktop app the scale could sit for
    /// days on one old reading — long enough for the mix of models, and how
    /// much of the work runs in subagents, to have moved under it. The record
    /// is a reading every fifteen minutes whatever the work runs in. Every
    /// sample newer than the last one folded in is replayed in order, each
    /// paired with the spend from the start of its own window to the moment
    /// it was taken.
    private func calibrateAgainstPlanRecord() {
        let samples = planUsage.samples
        var updated = calibration
        for kind in QuotaWindowKind.allCases {
            let since = updated.date(for: kind) ?? .distantPast
            for (index, sample) in samples.enumerated() where sample.at > since {
                guard let used = sample.value(for: kind) else { continue }
                // Only what the record knew at the time: the five-hour window
                // is dated from the latest reset, which must not be a later one.
                let known = Array(samples[...index])
                guard let resetsAt = PlanUsageFile.resetsAt(
                    for: kind, samples: known, now: sample.at)
                else { continue }
                var start = resetsAt.addingTimeInterval(-kind.length)
                // An off-cycle reset zeroes the figure without moving the
                // cadence, and nothing spent before it is in the percentage.
                if let dropped = PlanUsageFile.resets(for: kind, samples: known).last?.instant {
                    start = max(start, dropped)
                }
                guard start < sample.at else { continue }
                updated.observe(
                    kind: kind, usedPercentage: used,
                    spent: ledger.total(in: start..<sample.at), at: sample.at)
            }
        }
        guard updated != calibration else { return }
        calibration = updated
        updated.save()
    }

    // MARK: - Lifecycle

    func start() {
        do {
            try PidGuard.claim()
        } catch let running as PidGuard.AlreadyRunning {
            // Two instances would fight over the socket, and the loser would
            // look alive while receiving nothing.
            duplicateInstancePID = running.pid
            AndonLog.ui.error("Another instance is running (pid \(running.pid))")
            return
        } catch {
            serverError = error.localizedDescription
        }

        server.onEvent = { [weak self] envelope, decision in
            guard let self else { return }
            self.board.apply(envelope, decision: decision)
            // A finished turn means the transcript just gained the response
            // that turn cost. Re-reading it now keeps the readout in step with
            // the board instead of trailing the poll interval.
            if envelope.payload.event == .stop { self.ledger.refresh() }
        }

        do {
            try server.start()
            serverError = nil
        } catch {
            serverError = Self.describe(error)
            AndonLog.ui.error("Server failed to start: \(self.serverError ?? "")")
        }

        // Started before the quota watcher so the cached index is in memory
        // by the time the first reading arrives and asks what it cost.
        // Indexing a year of transcripts takes a while the first time and is
        // near-free after that, so it runs at launch rather than making
        // someone wait when they open the window.
        ledger.start()
        planUsage.start()
        board.startWatchingRateLimits()
        // Sessions whose process died without a SessionEnd would otherwise sit
        // on the board reading "running" indefinitely.
        board.startReapingDeadSessions()
        refreshInstallStatus()

        // The launcher embeds the current bundle path. Rewriting it on every
        // launch keeps hooks working after the app is moved or updated,
        // without touching settings.json again.
        if case .installed = installStatus {
            try? LauncherWriter.writeLaunchers()
        }
    }

    func stop() {
        planUsage.stop()
        ledger.stop()
        board.stopReaping()
        server.stop()
        chiptune.shutdown()
        PidGuard.release()
    }

    private static func describe(_ error: Error) -> String {
        if case SocketTransport.TransportError.pathTooLong = error {
            return "Home directory path is too long for a Unix socket (104 byte limit)."
        }
        return error.localizedDescription
    }

    // MARK: - Integration

    func refreshInstallStatus() {
        installStatus = installer.currentStatus()
        codexStatus = codexInstaller.currentStatus()
        geminiStatus = geminiInstaller.currentStatus()
        cursorStatus = cursorInstaller.currentStatus(gateEnabled: settings.cursorGateEnabled)
    }

    var isIntegrationHealthy: Bool {
        if case .installed = installStatus { return serverError == nil }
        return false
    }

    var isCodexInstalled: Bool {
        if case .installed = codexStatus { return true }
        return false
    }

    @discardableResult
    func installCodex() -> Result<CodexHooksInstaller.Report, Error> {
        do {
            let report = try codexInstaller.install()
            refreshInstallStatus()
            return .success(report)
        } catch {
            AndonLog.ui.error("Codex install failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    @discardableResult
    func removeCodex() -> Result<URL?, Error> {
        do {
            let backup = try codexInstaller.uninstall()
            refreshInstallStatus()
            return .success(backup)
        } catch {
            return .failure(error)
        }
    }

    var isGeminiInstalled: Bool {
        if case .installed = geminiStatus { return true }
        return false
    }

    @discardableResult
    func installGemini() -> Result<GeminiHooksInstaller.Report, Error> {
        do {
            let report = try geminiInstaller.install()
            refreshInstallStatus()
            return .success(report)
        } catch {
            AndonLog.ui.error("Gemini install failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    @discardableResult
    func removeGemini() -> Result<URL?, Error> {
        do {
            let backup = try geminiInstaller.uninstall()
            refreshInstallStatus()
            return .success(backup)
        } catch {
            return .failure(error)
        }
    }

    var isCursorInstalled: Bool {
        if case .installed = cursorStatus { return true }
        return false
    }

    @discardableResult
    func installCursor() -> Result<CursorHooksInstaller.Report, Error> {
        do {
            let report = try cursorInstaller.install(gateEnabled: settings.cursorGateEnabled)
            refreshInstallStatus()
            return .success(report)
        } catch {
            AndonLog.ui.error("Cursor install failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    @discardableResult
    func removeCursor() -> Result<URL?, Error> {
        do {
            let backup = try cursorInstaller.uninstall()
            refreshInstallStatus()
            return .success(backup)
        } catch {
            return .failure(error)
        }
    }

    /// Flip the shell gate and rewrite the hooks file to match. Cursor
    /// hot-reloads hooks.json, so the change takes effect without a restart.
    func setCursorGate(_ enabled: Bool) {
        settings.cursorGateEnabled = enabled
        if isCursorInstalled { installCursor() }
    }

    @discardableResult
    func installIntegration() -> Result<ClaudeSettingsInstaller.Report, Error> {
        do {
            let report = try installer.install()
            refreshInstallStatus()
            return .success(report)
        } catch {
            AndonLog.ui.error("Install failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    @discardableResult
    func removeIntegration() -> Result<URL?, Error> {
        do {
            let backup = try installer.uninstall()
            LauncherWriter.removeLaunchers()
            board.reset()
            refreshInstallStatus()
            return .success(backup)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Sound

    private func playSound(_ sound: BoardSound) {
        guard settings.soundsEnabled else { return }
        if settings.quietWhileFocused && Self.isDoNotDisturbLikely { return }
        chiptune.volume = Float(settings.volume)
        chiptune.play(sound)
    }

    func previewSound(_ sound: BoardSound) {
        chiptune.volume = Float(settings.volume)
        chiptune.preview(sound)
    }

    /// Best-effort Focus detection.
    ///
    /// macOS exposes no public API for Focus state, so this checks the one
    /// closely-related signal that is public: an active screen recording or
    /// sharing session, where a surprise chiptune is worst. Presenting this as
    /// "quiet while focused" is a slight overstatement, and the settings copy
    /// says so.
    private static var isDoNotDisturbLikely: Bool {
        NSApplication.shared.occlusionState.contains(.visible) == false
    }
}
