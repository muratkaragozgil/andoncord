import Darwin
import Foundation

/// Follows the end of a live transcript for the one thing no hook reports:
/// an interrupted turn.
///
/// Esc fires nothing. `Stop` does not run for an interrupted turn, and
/// `PostToolUseFailure`'s `is_interrupt` only covers a tool caught mid-call,
/// so a session stopped while Claude was thinking went on showing a working
/// lamp until its next prompt. Claude Code does record the interrupt — as a
/// user line whose text is `[Request interrupted by user]` — and this is what
/// watches for it.
///
/// Only bytes appended after the watch starts are read, and only while the
/// session is working, so the cost is the size of what Claude writes.
public final class TranscriptTail {
    /// The exact texts Claude Code writes for an interrupt. Matched whole, so
    /// a prompt that merely quotes one does not count.
    static let interruptTexts: Set<String> = [
        "[Request interrupted by user]",
        "[Request interrupted by user for tool use]",
    ]

    private let url: URL
    private let queue = DispatchQueue(label: "app.andoncord.tail", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64
    private var carry = Data()
    private let onInterrupt: @Sendable () -> Void

    /// Starts at the current end of `url`. Nil when the file cannot be
    /// opened — the board simply goes without interrupt detection then.
    public init?(url: URL, onInterrupt: @escaping @Sendable () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        self.url = url
        self.onInterrupt = onInterrupt
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .uint64Value ?? 0
        self.offset = size

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                // Replaced or gone; the next event from the session starts a
                // fresh watch on whatever is there now.
                source.cancel()
                return
            }
            self.readAppended()
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    deinit { source?.cancel() }

    public func cancel() { source?.cancel() }

    private func readAppended() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return }
        offset += UInt64(data.count)
        carry.append(data)

        var interrupted = false
        while let newline = carry.firstIndex(of: 0x0A) {
            let line = carry[carry.startIndex..<newline]
            if !interrupted, Self.isInterrupt(Data(line)) { interrupted = true }
            carry.removeSubrange(carry.startIndex...newline)
        }
        // A line longer than this is a tool result, never an interrupt.
        if carry.count > 1 << 20 { carry.removeAll() }
        if interrupted { onInterrupt() }
    }

    /// A user line whose only text is one of Claude Code's interrupt markers.
    static func isInterrupt(_ line: Data) -> Bool {
        guard line.contains(subsequence: Array("[Request interrupted by user".utf8)),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "user",
              let message = object["message"] as? [String: Any]
        else { return false }
        if let text = message["content"] as? String {
            return interruptTexts.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return false }
        return blocks.contains {
            $0["type"] as? String == "text"
                && interruptTexts.contains(
                    ($0["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
