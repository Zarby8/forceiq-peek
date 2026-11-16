import Foundation
import PeakCore

/// Peek's side of peek.sock (spec §3): the relay connects, sends one stripped JSON line, and — for
/// ordinary events — disconnects. For a held event (PermissionRequest / AskUserQuestion) the relay
/// waits on the same connection for one reply line; this server hands the connection to the model
/// (AgentWatchModel.receive) and writes back whatever the decision resolves, or nothing at all.
/// A connection whose relay dies, or that outlives the approval's deadline, is dropped and the
/// model forgets the request (dropHeld) — the terminal prompt is always the fallback.
///
/// Threads: one accept thread, one per connection. All model calls hop to the main actor.
final class AgentSocketServer {
    private let model: AgentWatchModel
    private let logLine: @Sendable (String) -> Void
    private let path: String
    private var listenFD: Int32 = -1
    private var running = false
    private let lock = NSLock()

    init(model: AgentWatchModel, path: String, log: @escaping @Sendable (String) -> Void) {
        self.model = model
        self.path = path
        self.logLine = log
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { logLine("agents socket=failed"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); logLine("agents socket=path-too-long"); return }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { q in
                for (i, b) in bytes.enumerated() { q[i] = CChar(bitPattern: b) }
                q[bytes.count] = 0
            }
        }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, listen(fd, 16) == 0 else { close(fd); logLine("agents socket=failed"); return }
        chmod(path, 0o600)
        listenFD = fd
        running = true
        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "peek.agents.accept"
        t.start()
        logLine("agents socket=listening")
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        running = false
        if listenFD >= 0 { shutdown(listenFD, SHUT_RDWR); close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func acceptLoop(_ fd: Int32) {
        while isRunning {
            let c = accept(fd, nil, nil)
            if c < 0 { if isRunning { Thread.sleep(forTimeInterval: 0.05) }; continue }
            let t = Thread { [weak self] in self?.handle(c) }
            t.name = "peek.agents.conn"
            t.start()
        }
    }

    /// Read one line (the relay's whole message) with a timeout; nil on EOF/timeout/oversize.
    private func readLine(_ fd: Int32, timeoutSeconds: Int) -> String? {
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8]()
        var byte: UInt8 = 0
        while buf.count < 65_536 {
            let n = recv(fd, &byte, 1, 0)
            if n <= 0 { return nil }
            if byte == 0x0A { return String(decoding: buf, as: UTF8.self) }
            buf.append(byte)
        }
        return nil
    }

    private func handle(_ fd: Int32) {
        guard let line = readLine(fd, timeoutSeconds: 5),
              let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = AgentHookEvent.parse(obj) else { close(fd); return }
        guard event.held else {
            let m = model
            Task { @MainActor in m.receive(event) }
            close(fd)
            return
        }
        // Held: the model owns the reply. The box writes at most one line, then closes.
        let box = HeldBox(fd: fd)
        let approval = AgentApproval(event: event, receivedAt: event.at)
        let m = model
        Task { @MainActor in m.receive(event, reply: { line in box.answer(line) }) }
        // Watch for the relay dying (EOF) or the deadline passing while the model holds the box.
        let deadline = Date().addingTimeInterval(approval.kind == .question ? 125 : 118)
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while !box.answered && Date() < deadline {
            pollFD.revents = 0
            let r = poll(&pollFD, 1, 250)
            if r > 0 && pollFD.revents & Int16(POLLHUP | POLLERR) != 0 { break }   // relay is gone
            if r > 0 && pollFD.revents & Int16(POLLIN) != 0 {
                var peekByte: UInt8 = 0
                if recv(fd, &peekByte, 1, Int32(MSG_PEEK | MSG_DONTWAIT)) <= 0 { break }   // EOF
            }
        }
        if !box.answered {
            box.answer(nil)
            let id = approval.id
            Task { @MainActor in m.dropHeld(id: id) }
        }
    }
}

/// One held connection's reply slot: the first answer wins, writes its line (if any) and closes.
private final class HeldBox: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var done = false
    init(fd: Int32) { self.fd = fd }
    var answered: Bool { lock.lock(); defer { lock.unlock() }; return done }
    func answer(_ line: String?) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        if let line {
            var bytes = Array((line + "\n").utf8)
            let count = bytes.count
            _ = bytes.withUnsafeMutableBufferPointer { send(fd, $0.baseAddress, count, 0) }
        }
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
}
