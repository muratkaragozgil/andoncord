import AndonKit
import Darwin
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
//  andon-hook — the shim Claude Code executes.
//
//  Two rules govern everything in this file:
//
//  1. FAIL OPEN. This process sits on the user's critical path. If the app is
//     not running, is mid-update, or is wedged, Claude Code must carry on
//     exactly as if AndonCord were not installed. Every failure path exits 0
//     with no stdout, which Claude Code reads as "the hook had no opinion".
//
//  2. STAY CHEAP. This runs twice per tool call. No parsing beyond what is
//     needed, no network, no disk writes on the hot path.
//
//  It also exists as a real process, rather than the app registering an HTTP
//  hook, for one reason that cannot be worked around: Claude Code spawns it as
//  a child of the user's shell, so it inherits the controlling TTY and the
//  terminal's environment. That is the only reliable way to learn which tab a
//  session is in — the hook payload carries no terminal information at all.
// ─────────────────────────────────────────────────────────────────────────────

/// Exit without emitting a decision. Claude Code proceeds normally.
func failOpen(_ note: @autoclosure () -> String = "") -> Never {
    let message = note()
    if !message.isEmpty { Log.debugFile("hook fail-open: \(message)") }
    exit(0)
}

/// Best-effort controlling-terminal path.
///
/// stdin is the hook payload pipe, so it is never the tty. stderr is usually
/// still wired to the terminal; `/dev/tty` is the fallback when Claude Code
/// has captured both streams.
func currentTTYPath() -> String? {
    for fd in [Int32(2), Int32(1), Int32(0)] {
        if isatty(fd) == 1, let name = ttyname(fd) {
            return String(cString: name)
        }
    }
    let fd = open("/dev/tty", O_RDONLY | O_NONBLOCK)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    guard let name = ttyname(fd) else { return nil }
    return String(cString: name)
}

// MARK: - Argument parsing

let invocation = HookInvocation(arguments: Array(CommandLine.arguments.dropFirst()))

// MARK: - Read stdin

let stdinData = FileHandle.standardInput.readDataToEndOfFile()

// A hook 0.1.x installed into another agent: do nothing, successfully, and
// never reach the app. Checked only once stdin is drained. Exiting first would
// leave a writer whose payload outgrows the pipe buffer to meet a closed pipe,
// and how another tool handles that is not ours to find out on its users'
// critical path.
guard invocation.isClaudeCode else { failOpen("not a Claude Code hook") }
guard !stdinData.isEmpty else { failOpen("empty stdin") }

// MARK: - Statusline mode

if invocation.isStatusline {
    // Claude Code exposes `rate_limits` on the statusline payload and nowhere
    // else, which is the entire reason AndonCord installs a statusline at
    // all. Cache it, then hand control to whatever statusline the user had
    // before us so their own output is untouched.
    // Every failure here is silent by design — a statusline that printed an
    // error would put it in the user's prompt — but silent must not also mean
    // invisible. This path stopped writing for eight days once and the only
    // symptom was a readout that had quietly stopped moving, so each way it can
    // decline to write says so in the log.
    if let snapshot = try? JSONDecoder().decode(StatusSnapshot.self, from: stdinData) {
        let names = snapshot.rateLimits?.unrecognisedWindowNames ?? []
        if !names.isEmpty {
            // Kept and cached, not dropped — but worth saying, because it is
            // the first sign that the payload has grown a window this build
            // has no opinion about.
            Log.hook.notice(
                "statusline: unrecognised rate-limit windows \(names.joined(separator: ", "), privacy: .public)")
        }
        if snapshot.rateLimits?.isEmpty == false || snapshot.contextWindow != nil {
            try? Paths.ensureDirectories()
            if let encoded = try? JSONEncoder().encode(snapshot) {
                do {
                    try encoded.write(to: Paths.rateLimitsCache, options: .atomic)
                } catch {
                    Log.hook.error(
                        "statusline: cache write failed: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                Log.hook.error("statusline: could not encode snapshot")
            }
        } else {
            // The shape parsed but carried nothing we could use, which is what
            // a renamed or restructured `rate_limits` looks like from here.
            Log.hook.notice("statusline: payload had no usable rate limits or context window")
        }
    } else {
        Log.hook.error("statusline: payload did not decode as a StatusSnapshot")
    }

    // Chain to the previous statusline command, passing the identical payload.
    if let chainData = try? Data(contentsOf: Paths.statuslineChain),
       let chain = try? JSONDecoder().decode(StatuslineChain.self, from: chainData),
       let command = chain.command, !command.isEmpty {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        let inputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        if (try? process.run()) != nil {
            inputPipe.fileHandleForWriting.write(stdinData)
            try? inputPipe.fileHandleForWriting.close()
            process.waitUntilExit()
        }
    }
    exit(0)
}

// MARK: - Hook mode

guard let raw = try? JSONDecoder().decode(JSONValue.self, from: stdinData) else {
    failOpen("stdin was not JSON")
}
// Cursor running the hooks we wrote for Claude. Not a Claude Code session, so
// the same treatment as a stale hook: it never reaches the board, and nothing
// it runs ever waits on one.
guard HookInvocation.isFromClaudeCode(raw) else { failOpen("Cursor payload on a Claude hook") }
// The session AndonCord starts so Claude Code renews its sign-in. Its
// statusline was worth caching above; its events are nobody's work.
guard !HookInvocation.isRenewalSession(ProcessInfo.processInfo.environment) else {
    failOpen("sign-in renewal session")
}
// A payload we cannot model is still worth forwarding — `raw` is intact and
// the app can display it — so an empty decode is not fatal.
let payload = (try? JSONDecoder().decode(HookPayload.self, from: stdinData)) ?? HookPayload()

let terminal = TerminalContext.capture(
    environment: ProcessInfo.processInfo.environment,
    ttyPath: currentTTYPath(),
    parentPid: getppid()
)

let envelope = HookEnvelope(
    blocking: invocation.isBlocking,
    payload: payload,
    raw: raw,
    terminal: terminal,
    shimPid: getpid()
)

guard let encoded = try? JSONEncoder().encode(envelope) else { failOpen("encode failed") }

// Connect. A refused connection means the app is not running — the normal,
// expected case for anyone who has the hooks installed but the app closed.
let socketPath = Paths.socket.path
guard let fd = try? SocketTransport.connect(
    to: socketPath,
    // Blocking hooks are configured with a 24h timeout in settings.json so a
    // permission prompt can sit on the board as long as a terminal prompt
    // would. Non-blocking hooks must never delay a tool call.
    timeout: invocation.isBlocking ? 86_400 : 2
) else {
    failOpen("no listener at \(socketPath)")
}
defer { close(fd) }

guard (try? SocketTransport.writeLine(encoded, to: fd)) != nil else {
    failOpen("write failed")
}

guard invocation.isBlocking else {
    // Fire and forget. close() flushes the stream socket.
    exit(0)
}

// Hold the hook open until a human answers on the board.
guard let responseData = try? SocketTransport.readLine(from: fd),
      !responseData.isEmpty else {
    // The app went away mid-decision. Falling through with no output hands the
    // prompt back to Claude Code's own terminal UI, which is the right
    // degradation: the user still gets asked, just not in the notch.
    failOpen("no decision returned")
}

FileHandle.standardOutput.write(responseData)
exit(0)
