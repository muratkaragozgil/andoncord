import Darwin
import Foundation
import Observation

/// Quota straight from Anthropic — the figures Claude's own usage panel shows,
/// rather than anything reconstructed from them.
///
/// Every other source AndonCord has is a copy of this number taken somewhere
/// else, and each one has a way of going quiet: the statusline only fires while
/// a terminal session draws one, and the desktop app's record now only updates
/// while its usage tray has been opened in the last day. Between copies the
/// board can only carry the last one forward by measured spend, which is an
/// estimate however carefully it is scaled.
///
/// Claude Code reads its own quota from `GET /api/oauth/usage`, signed in with
/// the token it keeps in the login Keychain. This asks the same question with
/// the same token. It is opt-in, because it is the one thing AndonCord does
/// that leaves the Mac — and what leaves is a bearer token Anthropic issued,
/// sent to Anthropic, and nothing else.
@Observable
@MainActor
public final class AnthropicUsageStore {
    public private(set) var limits: RateLimits?
    public private(set) var fetchedAt: Date?
    /// Why the last attempt produced no reading, when it did not. A reading
    /// already on screen is kept through a failure; this only says why it has
    /// stopped moving.
    public private(set) var problem: Problem?

    public enum Problem: Sendable, Equatable {
        /// No Claude Code sign-in in the Keychain or `~/.claude`.
        case notSignedIn
        /// Signed in with a token that cannot read usage — `claude setup-token`
        /// issues inference-only ones.
        case missingScope
        /// The token has lapsed and Claude Code could not be got to renew it.
        case signInExpired
        case rateLimited(until: Date)
        case rejected(status: Int)
        case unreachable
        case unreadableResponse
    }

    /// Called with each new reading, so it can calibrate the scale the
    /// estimates use when this source is unavailable.
    @ObservationIgnored
    public var onReading: ((RateLimits, Date) -> Void)?

    @ObservationIgnored
    private var ticker: Task<Void, Never>?
    @ObservationIgnored
    private var blockedUntil: Date?
    @ObservationIgnored
    private var lastRenewal: Date?

    /// Claude's own panel refreshes on about this cadence, and the endpoint
    /// answers anything much faster with a 429.
    private static let pollInterval: Duration = .seconds(300)
    /// Two missed polls and the figure is no longer current.
    private static let freshnessWindow: TimeInterval = 11 * 60
    /// The shortest back-off after a 429, whatever `Retry-After` says.
    private static let minimumBackoff: TimeInterval = 5 * 60
    /// Renewal starts a Claude Code session, so it is rationed.
    private static let renewalCooldown: TimeInterval = 30 * 60

    public init() {}

    public var isRunning: Bool { ticker != nil }

    public var isFresh: Bool {
        guard let fetchedAt else { return false }
        return Date().timeIntervalSince(fetchedAt) < Self.freshnessWindow
    }

    public func start() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// Stops asking and forgets what was last heard, so a source that has
    /// been switched off cannot go on supplying the board with an old figure.
    public func stop() {
        ticker?.cancel()
        ticker = nil
        limits = nil
        fetchedAt = nil
        problem = nil
    }

    func poll() async {
        if let blockedUntil, blockedUntil > Date() { return }

        guard var credentials = await Self.readCredentials() else {
            problem = .notSignedIn
            return
        }
        guard credentials.canReadUsage else {
            problem = .missingScope
            return
        }
        if credentials.isExpired() {
            guard let renewed = await renew() else {
                problem = .signInExpired
                return
            }
            credentials = renewed
        }

        do {
            try await record(AnthropicUsageAPI.fetch(token: credentials.accessToken))
        } catch AnthropicUsageAPI.Failure.unauthorized {
            // Revoked or expired ahead of its stamp. One renewal, one retry.
            guard let renewed = await renew() else {
                problem = .signInExpired
                return
            }
            do {
                try await record(AnthropicUsageAPI.fetch(token: renewed.accessToken))
            } catch {
                note(error)
            }
        } catch {
            note(error)
        }
    }

    private func record(_ fresh: RateLimits) {
        let now = Date()
        limits = fresh
        fetchedAt = now
        problem = nil
        onReading?(fresh, now)
    }

    private func note(_ error: Error) {
        switch error {
        case AnthropicUsageAPI.Failure.unauthorized:
            problem = .signInExpired
        case AnthropicUsageAPI.Failure.rateLimited(let retryAfter):
            let until = Date().addingTimeInterval(max(retryAfter ?? 0, Self.minimumBackoff))
            blockedUntil = until
            problem = .rateLimited(until: until)
        case AnthropicUsageAPI.Failure.http(let status):
            problem = .rejected(status: status)
        case AnthropicUsageAPI.Failure.malformed:
            problem = .unreadableResponse
        default:
            problem = .unreachable
        }
        Log.usage.notice("anthropic usage: \(String(describing: self.problem), privacy: .public)")
    }

    /// Get Claude Code to renew its own sign-in, then read the result.
    ///
    /// AndonCord never refreshes the token itself. Refresh tokens rotate, and
    /// a refresh Claude Code did not perform leaves it holding a spent one —
    /// signed out, on the strength of a menu-bar app wanting a percentage.
    private func renew() async -> ClaudeCodeCredentials? {
        if let lastRenewal, Date().timeIntervalSince(lastRenewal) < Self.renewalCooldown {
            return nil
        }
        lastRenewal = Date()
        guard await ClaudeCodeSignInRenewal.renew() else { return nil }
        guard let renewed = await Self.readCredentials(), !renewed.isExpired() else { return nil }
        return renewed
    }

    private nonisolated static func readCredentials() async -> ClaudeCodeCredentials? {
        await offTheCooperativePool { ClaudeCodeCredentials.read() }
    }
}

/// Runs blocking work — a subprocess, a sleep while a terminal session spins
/// up — on a plain dispatch thread. Swift's cooperative pool has one thread
/// per core, and parking one of them for half a minute is how an unrelated
/// `await` elsewhere in the app ends up waiting on it.
func offTheCooperativePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
    }
}

// MARK: - Credentials

/// Claude Code's sign-in, as far as reading usage needs it.
public struct ClaudeCodeCredentials: Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date?
    public var scopes: [String]

    public init(accessToken: String, expiresAt: Date?, scopes: [String]) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    /// A minute early, so a token is never sent with seconds left on it.
    public func isExpired(asOf now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < 60
    }

    /// The usage endpoint wants `user:profile`. A token without a scope list
    /// is given the benefit of the doubt; the endpoint will say if it minds.
    public var canReadUsage: Bool { scopes.isEmpty || scopes.contains("user:profile") }

    static let keychainService = "Claude Code-credentials"

    /// `{"claudeAiOauth":{"accessToken":…,"expiresAt":<epoch ms>,"scopes":[…]}}`,
    /// the same in the Keychain item and in `~/.claude/.credentials.json`. The
    /// item carries other things too — MCP servers' OAuth state — none of which
    /// is touched.
    public static func parse(_ data: Data) -> ClaudeCodeCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expiry = (oauth["expiresAt"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return ClaudeCodeCredentials(
            accessToken: token, expiresAt: expiry,
            scopes: oauth["scopes"] as? [String] ?? [])
    }

    /// The Keychain first, where Claude Code keeps it on a Mac; the file is
    /// where it lives when the Keychain was unavailable at sign-in.
    public static func read() -> ClaudeCodeCredentials? {
        if let data = readKeychain(), let credentials = parse(data) { return credentials }
        let file = Paths.claudeDir.appendingPathComponent(".credentials.json")
        return (try? Data(contentsOf: file)).flatMap(parse)
    }

    /// Through `/usr/bin/security` rather than Security.framework.
    ///
    /// Claude Code writes the item with that tool, so the item's access list
    /// already trusts it and the read goes through without a prompt. A direct
    /// framework read from AndonCord would ask the user to allow it — and ask
    /// again each time Claude Code rewrites the item, which it does whenever it
    /// renews the token. The timeout covers a Mac where it prompts anyway: an
    /// unanswered dialog must not wedge the poll.
    static func readKeychain(timeout: TimeInterval = 5) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Data(trimmed.utf8)
    }
}

// MARK: - The endpoint

public enum AnthropicUsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public enum Failure: Error, Equatable {
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case http(Int)
        case malformed
    }

    public static func fetch(token: String, session: URLSession = .shared) async throws -> RateLimits {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The endpoint is gated behind this beta flag.
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(ClaudeCodeSignInRenewal.installedVersion ?? "2.1.0")",
                         forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            guard let limits = parse(data) else { throw Failure.malformed }
            return limits
        case 401:
            throw Failure.unauthorized
        case 429:
            let retryAfter = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw Failure.rateLimited(retryAfter: retryAfter)
        default:
            throw Failure.http(status)
        }
    }

    /// The response, mapped onto the same windows the statusline reports.
    ///
    /// `five_hour` and `seven_day` are `{utilization: <percent>, resets_at:
    /// <ISO 8601>}`. Model-scoped weekly limits come two ways — older flat keys
    /// such as `seven_day_opus`, and a newer `limits` array whose entries name
    /// their model (`scope.model.display_name`, "Fable" for one) — and both
    /// land in `others` as `seven_day_<model>`, which is where the statusline
    /// path keeps windows it has no typed field for.
    public static func parse(_ data: Data) -> RateLimits? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var limits = RateLimits()
        limits.fiveHour = window(root["five_hour"])
        limits.sevenDay = window(root["seven_day"])

        for (key, value) in root where key.hasPrefix("seven_day_") {
            if let window = window(value) { limits.others[key] = window }
        }
        for entry in root["limits"] as? [[String: Any]] ?? [] {
            guard entry["kind"] as? String == "weekly_scoped",
                  let scope = entry["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = (model["display_name"] as? String) ?? (model["id"] as? String),
                  let percent = (entry["percent"] as? NSNumber)?.doubleValue
            else { continue }
            let key = "seven_day_" + name.lowercased().replacingOccurrences(of: " ", with: "_")
            limits.others[key] = RateLimitWindow(
                usedPercentage: percent, resetsAt: date(entry["resets_at"]))
        }
        return limits.isEmpty ? nil : limits
    }

    private static func window(_ value: Any?) -> RateLimitWindow? {
        guard let object = value as? [String: Any],
              let utilization = (object["utilization"] as? NSNumber)?.doubleValue
        else { return nil }
        return RateLimitWindow(usedPercentage: utilization, resetsAt: date(object["resets_at"]))
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

// MARK: - Renewal

/// Has Claude Code renew its own sign-in.
///
/// Access tokens last hours, and Claude Code only renews one when it next
/// runs. On a Mac worked through the desktop app — whose sessions carry their
/// own credentials — the terminal sign-in can sit expired for days. So when
/// the token has lapsed, this starts `claude` on a pseudo-terminal, asks for
/// `/status`, and closes it again once the Keychain shows a fresh token. That
/// is Claude Code doing its own refresh against its own credentials, the only
/// way the stored refresh token stays valid.
///
/// The session runs in `~/.andoncord/probe` with `ANDON_PROBE=1`, so
/// AndonCord's own hooks know to ignore it, and with the auto-updater off so a
/// usage check never doubles as an install.
public enum ClaudeCodeSignInRenewal {
    public static func renew(timeout: TimeInterval = 25) async -> Bool {
        guard let executable = executable else {
            Log.usage.notice("renewal: claude not found")
            return false
        }
        return await offTheCooperativePool { run(executable: executable, timeout: timeout) }
    }

    /// Where `claude` is installed. A GUI app inherits almost no `PATH`, so
    /// the usual install locations are checked directly.
    public static var executable: URL? {
        let home = Paths.home.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// The native installer links `claude` to `…/versions/<version>`, which
    /// gives the version without starting the binary to ask it.
    public static var installedVersion: String? {
        guard let executable else { return nil }
        let resolved = executable.resolvingSymlinksInPath().lastPathComponent
        return resolved.first?.isNumber == true ? resolved : nil
    }

    private static func run(executable: URL, timeout: TimeInterval) -> Bool {
        let before = ClaudeCodeCredentials.read()
        func renewed() -> Bool {
            guard let now = ClaudeCodeCredentials.read() else { return false }
            return !now.isExpired() && now != before
        }

        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
              let name = ptsname(master)
        else {
            if master >= 0 { close(master) }
            return false
        }
        let slave = open(String(cString: name), O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            close(master)
            return false
        }
        // A terminal with no size makes the TUI lay itself out in zero
        // columns. TIOCSWINSZ is a function-like macro Swift does not import:
        // _IOW('t', 103, struct winsize).
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(slave, 0x8008_7467, &size)

        let probe = Paths.root.appendingPathComponent("probe")
        try? FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment[HookInvocation.renewalMarker] = "1"
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["PATH"] = ([
            "\(Paths.home.path)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
        ] + (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init))
            .joined(separator: ":")

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = probe
        process.environment = environment
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal

        let screen = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        // Drained and discarded: the output is never parsed, but a terminal
        // nobody reads fills up and stalls the session writing to it.
        screen.readabilityHandler = { _ = $0.availableData }
        defer {
            screen.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                usleep(500_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        do { try process.run() } catch { return false }
        func type(_ text: String) { try? screen.write(contentsOf: Data(text.utf8)) }

        // Enter first: a folder Claude Code has not seen before opens on the
        // trust prompt, whose default answer is to proceed. On a trusted one
        // it lands on an empty prompt and does nothing.
        Thread.sleep(forTimeInterval: 3)
        type("\r")
        Thread.sleep(forTimeInterval: 1.5)
        type("/status")
        Thread.sleep(forTimeInterval: 0.3)
        type("\r")

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, process.isRunning {
            if renewed() { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return renewed()
    }
}
