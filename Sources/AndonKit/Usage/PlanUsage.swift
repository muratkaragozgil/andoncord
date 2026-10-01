import Foundation
import Observation

/// Quota, read from the record the Claude desktop app already keeps.
///
/// `~/Library/Application Support/Claude/plan-usage-history.json` is written
/// every five minutes with the same two percentages the app's own Usage panel
/// shows. It is a far better source than the statusline AndonCord was built
/// around: the statusline only fires while a session is rendering one — never
/// for desktop, SDK, or headless work — whereas this keeps ticking as long as
/// the app is open, and it carries a month of history rather than a single
/// instant.
///
/// The history is what makes the rest possible. Neither the file nor the
/// statusline says when a window *opened*, but a window that resets shows up
/// as the percentage falling, and the samples bracket that moment:
///
///     13:29  fh 30%     ← still the old window
///     13:44  fh  1%     ← new one, so it opened in between
///
/// which puts the five-hour window's reset at 18:44. The weekly window resets
/// on a fixed weekly cadence, so every reset ever recorded constrains the same
/// phase — the tightest bracket across a month pins it to a few minutes.
///
/// The file is read; nothing is ever written back to it.
@Observable
@MainActor
public final class PlanUsageStore {
    public private(set) var samples: [QuotaSample] = []
    public private(set) var readAt: Date?

    @ObservationIgnored
    private var watcher: FileWatcher?
    @ObservationIgnored
    private var ticker: Task<Void, Never>?

    /// The desktop app samples every five minutes, so anything older than
    /// three of those means it is not running and the numbers have stopped.
    private static let freshnessWindow: TimeInterval = 16 * 60
    /// A backstop for the watcher: the file is replaced atomically and a
    /// missed rename would otherwise freeze the readout silently.
    private static let pollInterval: Duration = .seconds(120)

    public init() {}

    public func start() {
        reload()
        watcher = FileWatcher(url: Paths.planUsageHistory) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                self?.reload()
            }
        }
    }

    public func stop() {
        ticker?.cancel()
        ticker = nil
        watcher?.cancel()
        watcher = nil
    }

    public func reload() {
        guard let parsed = PlanUsageFile.read() else { return }
        samples = parsed
        readAt = Date()
    }

    public var latest: QuotaSample? { samples.last }

    public var isFresh: Bool {
        guard let latest else { return false }
        return Date().timeIntervalSince(latest.at) < Self.freshnessWindow
    }

    /// Everything known about one window, ready to draw.
    ///
    /// Nil when this source has nothing to say — no samples at all, or a
    /// five-hour window that is not open because nothing has been sent since
    /// the last reset. Callers fall back to the statusline cache from there.
    public func readout(_ kind: QuotaWindowKind, spent: TokenUsage, now: Date = Date())
        -> QuotaReadout?
    {
        guard let latest, let used = latest.value(for: kind) else { return nil }
        let resetsAt = PlanUsageFile.resetsAt(for: kind, samples: samples, now: now)
        // Without a reset time there is no evidence a five-hour window is
        // open. Two ways that happens, and neither is worth drawing: the
        // figure is zero because nothing has been sent since the last reset,
        // or the record has gone quiet and whatever it last saw has since
        // lapsed. (A record that is still being written is current by
        // definition, so a missing bracket there just costs the countdown.)
        if kind == .fiveHour, resetsAt == nil, used == 0 || !isFresh { return nil }
        // A record that went quiet before the window last turned over is
        // describing the previous one. The weekly reset is projected forward
        // regardless of how old the samples are, so without this a figure from
        // last week would be drawn against this week's countdown.
        if let resetsAt, latest.at < resetsAt.addingTimeInterval(-kind.length) { return nil }

        let forecast = resetsAt.map {
            QuotaForecast.project(
                window: RateLimitWindow(usedPercentage: used, resetsAt: $0),
                kind: kind, samples: samples, now: now)
        } ?? .unknown

        return QuotaReadout(
            kind: kind, usedPercentage: used, resetsAt: resetsAt,
            source: .reported(at: latest.at, stale: !isFresh),
            spent: spent, forecast: forecast)
    }

    /// When the current window opened, for scoping spend to it.
    public func windowStart(_ kind: QuotaWindowKind, now: Date = Date()) -> Date? {
        PlanUsageFile.resetsAt(for: kind, samples: samples, now: now)?
            .addingTimeInterval(-kind.length)
    }
}

/// Parsing and reset detection. Separated from the store so both can be
/// exercised without a filesystem or a main actor.
public enum PlanUsageFile {
    /// `{"version":2,"samples":[{"t":<epoch ms>,"org":"…","u":{"fh":30,"sd":26}}]}`
    private struct Document: Decodable {
        struct Sample: Decodable {
            struct Usage: Decodable {
                let fh: Double?
                let sd: Double?
            }
            let t: Double
            let u: Usage
        }
        let samples: [Sample]
    }

    public static func read(from url: URL = Paths.planUsageHistory) -> [QuotaSample]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    public static func parse(_ data: Data) -> [QuotaSample]? {
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            return nil
        }
        return document.samples
            .map {
                QuotaSample(
                    at: Date(timeIntervalSince1970: $0.t / 1000),
                    fiveHour: $0.u.fh, sevenDay: $0.u.sd)
            }
            .sorted { $0.at < $1.at }
    }

    /// A reset, as the samples saw it: the percentage fell between `before`
    /// and `after`, so the window turned over somewhere in that gap.
    public struct Reset: Sendable, Equatable {
        public var before: Date
        public var after: Date
        public var span: TimeInterval { after.timeIntervalSince(before) }
        /// Best single guess at the moment it happened.
        public var instant: Date {
            Date(timeIntervalSince1970:
                (before.timeIntervalSince1970 + after.timeIntervalSince1970) / 2)
        }
    }

    public static func resets(
        for kind: QuotaWindowKind, samples: [QuotaSample]
    ) -> [Reset] {
        var found: [Reset] = []
        var previous: (at: Date, value: Double)?
        for sample in samples {
            guard let value = sample.value(for: kind) else { continue }
            if let previous, value < previous.value {
                found.append(Reset(before: previous.at, after: sample.at))
            }
            previous = (sample.at, value)
        }
        return found
    }

    /// When the window in force right now will reset.
    ///
    /// The two windows need different reasoning, because only one of them is
    /// periodic:
    ///
    /// * **Weekly** resets on a fixed cadence, so every reset ever recorded is
    ///   evidence about the same phase. The tightest bracket wins and is
    ///   projected forward in whole weeks — a month of history normally pins
    ///   it to a few minutes.
    /// * **Five-hour** windows open on the first request after the previous
    ///   one lapsed, so they are not on a grid at all and only the most recent
    ///   reset says anything. Its bracket is as good as the sampling was
    ///   around it.
    public static func resetsAt(
        for kind: QuotaWindowKind, samples: [QuotaSample], now: Date = Date()
    ) -> Date? {
        let found = resets(for: kind, samples: samples)
        guard !found.isEmpty else { return nil }

        switch kind {
        case .sevenDay:
            guard let tightest = found.min(by: { $0.span < $1.span }) else { return nil }
            var candidate = tightest.instant.addingTimeInterval(kind.length)
            // Project forward in whole windows. Bounded rather than `while
            // true` so a corrupt timestamp cannot spin here.
            let steps = Int(max(0, now.timeIntervalSince(candidate)) / kind.length) + 1
            candidate.addTimeInterval(Double(steps) * kind.length)
            while candidate.timeIntervalSince(now) > kind.length {
                candidate.addTimeInterval(-kind.length)
            }
            return candidate

        case .fiveHour:
            // The window opens with the first request after the reset, which
            // is the first sample showing a non-zero figure — not the reset
            // itself, since someone may have stopped for an hour first.
            guard let last = found.last else { return nil }
            guard let opened = samples.first(where: {
                $0.at >= last.after && ($0.value(for: kind) ?? 0) > 0
            })?.at else { return nil }
            let resetsAt = opened.addingTimeInterval(kind.length)
            // A window that should already have lapsed means the samples
            // stopped — the app was closed — and there is nothing current to
            // report.
            return resetsAt > now ? resetsAt : nil
        }
    }
}
