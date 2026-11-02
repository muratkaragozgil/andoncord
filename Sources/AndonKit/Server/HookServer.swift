import Darwin
import Foundation

/// A hook that is currently parked, waiting for a decision from the board.
///
/// While this object is alive the shim on the other end is blocked inside
/// `read()`, which means Claude Code itself is blocked. Every path out of the
/// UI must therefore end in either `resolve` or `abandon` — dropping one on the
/// floor would hang someone's session until the 24h hook timeout fires.
public final class PendingDecision {
    public let id: UUID
    public let envelope: HookEnvelope

    /// Receives the outcome exactly once. `nil` means "released with no
    /// opinion". Abstracted from the socket so the decision lifecycle can be
    /// tested without a live connection.
    private let sink: (HookResponse?) -> Void
    private let lock = NSLock()
    private var isSettled = false

    public init(
        id: UUID = UUID(),
        envelope: HookEnvelope,
        sink: @escaping (HookResponse?) -> Void
    ) {
        self.id = id
        self.envelope = envelope
        self.sink = sink
    }

    /// Send a decision back to Claude Code and release the hook.
    public func resolve(_ response: HookResponse) { settle(response) }

    /// Release the hook without an opinion. Claude Code falls back to its own
    /// terminal prompt, which is the correct degradation when we cannot
    /// answer — the user is still asked, just not in the notch.
    public func abandon() { settle(nil) }

    public var isResolved: Bool {
        lock.lock(); defer { lock.unlock() }
        return isSettled
    }

    private func settle(_ response: HookResponse?) {
        lock.lock()
        guard !isSettled else { lock.unlock(); return }
        isSettled = true
        lock.unlock()
        sink(response)
    }

    deinit {
        // A decision deallocated without an answer would leave Claude Code
        // blocked until the hook timeout, so treat it as an abandon.
        lock.lock()
        let settled = isSettled
        isSettled = true
        lock.unlock()
        if !settled { sink(nil) }
    }
}

/// Listens on the Unix domain socket and turns incoming shim connections into
/// events (and, where the hook is blocking, parked decisions).
public final class HookServer {
    public typealias EventHandler = (HookEnvelope, PendingDecision?) -> Void

    /// Delivered on the main queue.
    public var onEvent: EventHandler?
    /// Delivered on the main queue when the shim behind a parked decision
    /// hangs up before anyone answered — Claude Code killed the hook. Carries
    /// the decision's id; the decision itself has already been released.
    public var onWithdrawn: ((UUID) -> Void)?

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "app.andoncord.accept", qos: .userInitiated)
    private let ioQueue = DispatchQueue(
        label: "app.andoncord.io", qos: .userInitiated, attributes: .concurrent)
    /// Where parked connections are watched for their shim hanging up.
    private let hangupQueue = DispatchQueue(label: "app.andoncord.hangup", qos: .utility)

    private let pendingLock = NSLock()
    private var pending: [UUID: PendingDecision] = [:]

    /// Ceiling on simultaneously open client fds. Legit load is one fd per
    /// in-flight hook — a few dozen at the very worst — so hitting this means
    /// something hostile or broken is spraying connections. Shedding beats
    /// hanging: a dropped connection makes that one shim fail open, a starved
    /// fd table takes the whole board down.
    private let clientLock = NSLock()
    private var openClients = 0
    private static let maxOpenClients = 256

    /// How long a client gets to deliver its one request line. A real shim
    /// writes immediately after connecting; only a stalled or hostile peer
    /// needs longer. `readTimeout` wakes each blocked read, `readDeadline`
    /// bounds the line as a whole. Overridable so tests don't sit for 30s.
    private let readTimeout: TimeInterval
    private let readDeadline: TimeInterval

    public init(readTimeout: TimeInterval = 10, readDeadline: TimeInterval = 30) {
        self.readTimeout = readTimeout
        self.readDeadline = readDeadline
    }

    public var isRunning: Bool { listenFD >= 0 }

    public func start() throws {
        guard listenFD < 0 else { return }
        try Paths.ensureDirectories()

        guard Paths.socketPathFitsInSunPath else {
            throw SocketTransport.TransportError.pathTooLong
        }

        let fd = try SocketTransport.listen(at: Paths.socket.path)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source

        Log.server.info("Listening on \(Paths.socket.path, privacy: .public)")
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        unlink(Paths.socket.path)

        // Release anything still parked so no session is left hanging.
        pendingLock.lock()
        let inFlight = Array(pending.values)
        pending.removeAll()
        pendingLock.unlock()
        inFlight.forEach { $0.abandon() }
    }

    /// Release every parked decision belonging to a session. Called when a
    /// session ends so its hooks do not sit blocked until the timeout.
    public func abandonDecisions(forSession sessionId: String) {
        pendingLock.lock()
        let matching = pending.values.filter { $0.envelope.payload.sessionId == sessionId }
        pendingLock.unlock()
        matching.forEach { $0.abandon() }
    }

    // MARK: - Accept loop

    private func acceptPending() {
        // The read source fires once per readable event but several
        // connections can be queued, so drain until EAGAIN.
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                return
            }
            SocketTransport.makeBlocking(clientFD)

            // Only talk to our own user. The 0700 run directory is what keeps
            // other users away from the socket; this check holds even if those
            // permissions ever drift (a loosened home, ACLs, a restore).
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(clientFD, &uid, &gid) == 0, uid == getuid() else {
                close(clientFD)
                continue
            }

            clientLock.lock()
            let overBudget = openClients >= Self.maxOpenClients
            if !overBudget { openClients += 1 }
            clientLock.unlock()
            if overBudget {
                close(clientFD)
                continue
            }

            var one: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one,
                       socklen_t(MemoryLayout<Int32>.size))
            // A peer that connects and then stalls must not pin an ioQueue
            // worker: the receive timeout wakes the read loop so readLine's
            // deadline can fire. The send timeout is for a peer that never
            // drains its response — a real shim is blocked in read() by then.
            var window = SocketTransport.timevalFrom(readTimeout)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &window,
                       socklen_t(MemoryLayout<timeval>.size))
            setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &window,
                       socklen_t(MemoryLayout<timeval>.size))
            ioQueue.async { [weak self] in self?.handleConnection(clientFD) }
        }
    }

    /// Every client fd must come back through here so the budget stays true.
    private func closeClient(_ fd: Int32) {
        close(fd)
        clientLock.lock()
        openClients -= 1
        clientLock.unlock()
    }

    private func handleConnection(_ fd: Int32) {
        guard let line = try? SocketTransport.readLine(
            from: fd, deadline: Date().addingTimeInterval(readDeadline)),
            !line.isEmpty
        else {
            closeClient(fd)
            return
        }
        guard let envelope = try? JSONDecoder().decode(HookEnvelope.self, from: line) else {
            Log.server.error("Undecodable envelope, dropping")
            closeClient(fd)
            return
        }

        if envelope.blocking {
            let id = UUID()
            // Once its request line is written, a shim only ever waits. So the
            // connection turning readable again can only mean it hung up:
            // Claude Code killed the hook — the turn was interrupted, the
            // session went away — and nobody is waiting on this answer any
            // more. Left unwatched, its card would sit on the board answering
            // nothing until someone clicked it.
            let hangup = DispatchSource.makeReadSource(fileDescriptor: fd, queue: hangupQueue)
            let decision = PendingDecision(
                id: id, envelope: envelope,
                sink: { [weak self] response in
                    // Writing the reply is what unblocks the shim; closing the
                    // fd is what unblocks it when we have no opinion.
                    if let response, let data = try? JSONEncoder().encode(response) {
                        try? SocketTransport.writeLine(data, to: fd)
                    }
                    // Cancelling is what closes the fd — in the cancel
                    // handler, so it is never closed under a live source or
                    // reused while one still watches it.
                    hangup.cancel()
                    guard let self else { return }
                    self.pendingLock.lock()
                    self.pending.removeValue(forKey: id)
                    self.pendingLock.unlock()
                })
            hangup.setEventHandler { [weak self, weak decision] in
                var byte: UInt8 = 0
                let peeked = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                if peeked < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
                // EOF, an error, or bytes a real shim never sends: in every
                // case the conversation is over.
                guard let decision, !decision.isResolved else { return }
                decision.abandon()
                DispatchQueue.main.async { self?.onWithdrawn?(id) }
            }
            hangup.setCancelHandler { [weak self] in
                if let self { self.closeClient(fd) } else { close(fd) }
            }
            pendingLock.lock()
            pending[id] = decision
            pendingLock.unlock()
            hangup.resume()

            DispatchQueue.main.async { [weak self] in
                guard let self else { decision.abandon(); return }
                guard let handler = self.onEvent else { decision.abandon(); return }
                handler(envelope, decision)
            }
        } else {
            closeClient(fd)
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(envelope, nil)
            }
        }
    }
}
