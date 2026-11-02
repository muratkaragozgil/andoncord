import Darwin
import Foundation

/// Newline-delimited JSON over a Unix domain socket.
///
/// Framing is safe because `JSONEncoder` escapes newlines inside strings, so
/// an encoded object never contains a raw `\n`.
public enum SocketTransport {
    public enum TransportError: Error {
        case pathTooLong
        case socketCreationFailed(Int32)
        case connectFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case writeFailed(Int32)
        case closedByPeer
        case timedOut
    }

    /// `sockaddr_un.sun_path` is a fixed 104-byte buffer on Darwin.
    static func makeAddress(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw TransportError.pathTooLong }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (index, byte) in bytes.enumerated() { dst[index] = CChar(bitPattern: byte) }
                dst[bytes.count] = 0
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func withAddress<T>(
        _ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) rethrows -> T {
        try withUnsafePointer(to: &addr) { ptr in
            try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                try body(sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    // MARK: - Client

    /// Connect to the app. Returns a connected fd the caller must close.
    public static func connect(to path: String, timeout: TimeInterval) throws -> Int32 {
        var addr = try makeAddress(path: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.socketCreationFailed(errno) }

        var timeval = timevalFrom(timeout)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeval, socklen_t(MemoryLayout<timeval>.size))
        // Without this a dead peer raises SIGPIPE and takes the process with
        // it, which for the shim would mean killing a hook mid-turn.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let result = withAddress(&addr) { sa, len in Darwin.connect(fd, sa, len) }
        guard result == 0 else {
            let saved = errno
            close(fd)
            throw TransportError.connectFailed(saved)
        }
        return fd
    }

    // MARK: - Server

    /// Bind and listen, replacing any stale socket file left by a crash.
    public static func listen(at path: String, backlog: Int32 = 64) throws -> Int32 {
        // A leftover socket file makes bind() fail with EADDRINUSE even when
        // nothing is listening, so clear it first. `PidGuard` has already
        // established that no live instance owns it.
        unlink(path)

        var addr = try makeAddress(path: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.socketCreationFailed(errno) }

        let bindResult = withAddress(&addr) { sa, len in Darwin.bind(fd, sa, len) }
        guard bindResult == 0 else {
            let saved = errno
            close(fd)
            throw TransportError.bindFailed(saved)
        }

        // Hook payloads carry prompts and file contents; keep the socket
        // owner-only.
        chmod(path, 0o600)

        guard Darwin.listen(fd, backlog) == 0 else {
            let saved = errno
            close(fd)
            throw TransportError.listenFailed(saved)
        }
        // Non-blocking, so the accept loop can drain the backlog and return.
        // Blocking, its last accept() never came back: one thread parked for
        // the life of the app, and a cancelled source that could not run its
        // cancel handler to close this descriptor.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    /// Put a descriptor back into blocking mode. On Darwin an accepted socket
    /// inherits the listener's O_NONBLOCK, and the client IO relies on
    /// SO_RCVTIMEO-bounded blocking reads.
    static func makeBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0, flags & O_NONBLOCK != 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
    }

    // MARK: - Framed IO

    public static func writeLine(_ data: Data, to fd: Int32) throws {
        var payload = data
        payload.append(0x0A)
        try payload.withUnsafeBytes { buffer in
            var offset = 0
            let base = buffer.bindMemory(to: UInt8.self).baseAddress!
            while offset < buffer.count {
                let written = Darwin.write(fd, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    throw TransportError.writeFailed(errno)
                }
            }
        }
    }

    /// Read one newline-terminated frame. Returns nil on clean EOF.
    ///
    /// `deadline` bounds the whole read, not just each byte: a peer that
    /// dribbles one byte per SO_RCVTIMEO interval would otherwise hold the
    /// reading thread forever. The shim's own reads pass no deadline — a
    /// blocking hook legitimately waits hours for a human.
    public static func readLine(
        from fd: Int32, maxBytes: Int = 8 * 1024 * 1024, deadline: Date? = nil
    ) throws -> Data? {
        var accumulated = Data()
        var byte: UInt8 = 0
        while accumulated.count < maxBytes {
            if let deadline, accumulated.count & 0xFFF == 0, Date() >= deadline {
                throw TransportError.timedOut
            }
            let count = Darwin.read(fd, &byte, 1)
            if count == 1 {
                if byte == 0x0A { return accumulated }
                accumulated.append(byte)
            } else if count == 0 {
                return accumulated.isEmpty ? nil : accumulated
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw TransportError.timedOut
            } else {
                throw TransportError.closedByPeer
            }
        }
        return accumulated
    }

    static func timevalFrom(_ interval: TimeInterval) -> timeval {
        let seconds = Int(interval)
        let microseconds = Int((interval - Double(seconds)) * 1_000_000)
        return timeval(tv_sec: seconds, tv_usec: Int32(microseconds))
    }
}
