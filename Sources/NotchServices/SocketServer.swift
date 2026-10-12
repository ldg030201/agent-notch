import Darwin
import Foundation
import NotchShared
import os

public enum SocketServerError: Error, Equatable, LocalizedError {
    /// 소켓 경로가 `sun_path` 한도(104바이트)를 넘음
    case pathTooLong
    /// 같은 소켓에서 다른 AgentNotch 가 이미 연결을 받고 있음 (단일 인스턴스)
    case alreadyRunning
    /// 소켓 경로에 소켓이 아닌 파일이 있음 (지우지 않는다)
    case pathOccupied
    /// 시스템 호출 실패
    case systemCall(name: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong: return "소켓 경로가 너무 김"
        case .alreadyRunning: return "AgentNotch 가 이미 실행 중"
        case .pathOccupied: return "소켓 경로에 다른 파일이 있음"
        case .systemCall(let name, let code): return "소켓 준비 실패 (\(name): \(String(cString: strerror(code))))"
        }
    }
}

/// 훅 헬퍼(`notch-hook`)가 붙는 Unix 도메인 소켓 서버.
///
/// - 연결마다 `HookEnvelope` 한 줄을 읽어 메인 액터에서 `onEnvelope` 를 호출한다.
/// - `expectsReply` 인 연결(PermissionRequest)은 `onEnvelope` 가 돌려준 ID 로 보관해 두었다가
///   `reply(to:output:)` 로 `HookReply` 한 줄을 보내고 닫는다.
/// - 응답 전에 클라이언트가 끊기거나 `replyTimeout` 이 지나면 `onPendingCancelled` 를 호출한다
///   (시간 초과 시에는 `output: null` 로 응답해 Claude Code 기본 권한 흐름으로 넘긴다).
///
/// 소켓 관련 상태는 전부 내부 직렬 큐에서만 다룬다. 콜백은 항상 메인 액터에서 호출된다.
public final class SocketServer: @unchecked Sendable {
    /// 한 줄(envelope)의 최대 크기. 넘으면 연결을 끊는다.
    public static let maxLineBytes = NotchWire.maxEnvelopeBytes + 64 * 1024
    /// 헬퍼의 `--reply-timeout 590` 보다 먼저 응답하도록 대기 시간을 이 값으로 자른다
    public static let maxReplyTimeout: TimeInterval = 585
    /// 연결 후 envelope 한 줄을 다 받을 때까지 기다리는 최대 시간
    static let lineReadTimeout: TimeInterval = 15
    /// 응답 한 줄을 쓰는 최대 시간
    static let writeTimeout: TimeInterval = 2
    /// 동시에 열어 둘 수 있는 연결 수 (같은 사용자의 오작동 프로세스로부터 fd 고갈 방지)
    static let maxConnections = 128

    public let socketPath: String

    // MARK: - 콜백 (설정은 아무 스레드에서나, 호출은 항상 메인 액터)

    private let callbackLock = NSLock()
    private var storedOnEnvelope: (@MainActor (HookEnvelope) -> UUID?)?
    private var storedOnPendingCancelled: (@MainActor (UUID) -> Void)?
    private var storedReplyTimeout: @MainActor () -> TimeInterval = { 120 }

    /// envelope 수신. 응답이 필요한 이벤트면 대기시킬 요청 ID 를 돌려준다 (nil 이면 즉시 `output: null` 응답).
    public var onEnvelope: (@MainActor (HookEnvelope) -> UUID?)? {
        get { withCallbackLock { storedOnEnvelope } }
        set { withCallbackLock { storedOnEnvelope = newValue } }
    }

    /// 대기 중이던 요청이 응답 없이 끝남 (클라이언트 끊김, 시간 초과, 서버 정지)
    public var onPendingCancelled: (@MainActor (UUID) -> Void)? {
        get { withCallbackLock { storedOnPendingCancelled } }
        set { withCallbackLock { storedOnPendingCancelled = newValue } }
    }

    /// 응답을 기다리는 최대 시간(초). 요청마다 메인 액터에서 읽는다.
    public var replyTimeout: @MainActor () -> TimeInterval {
        get { withCallbackLock { storedReplyTimeout } }
        set { withCallbackLock { storedReplyTimeout = newValue } }
    }

    // MARK: - 큐 전용 상태

    private let queue = DispatchQueue(label: "com.ldg.agent-notch.socket-server")
    private let log = NotchServices.logger("socket")
    private var listenSource: DispatchSourceRead?
    private var listenFD: Int32 = -1
    /// 우리가 bind 한 소켓 파일 (stop 시 다른 인스턴스의 소켓을 지우지 않도록 확인)
    private var socketIdentity: (device: dev_t, inode: ino_t)?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var pending: [UUID: Connection] = [:]
    /// `onEnvelope` 안에서 바로 결정된 응답 (연결에 ID 를 붙이기 전이라 잠시 보관)
    private var earlyReplies: [UUID: HookReply] = [:]
    private var awaitingIDCount = 0
    private let readChunk = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 1)

    public init(socketPath: String = NotchWire.socketPath()) {
        self.socketPath = socketPath
    }

    deinit {
        // deinit 시점엔 다른 참조가 없으므로 큐를 거치지 않고 정리한다 (큐 스레드에서 deinit 될 수 있어 sync 금지)
        shutdown(notify: false)
        readChunk.deallocate()
    }

    /// 연결을 받고 있는지
    public var isRunning: Bool {
        queue.sync { listenSource != nil }
    }

    // MARK: - 시작 / 정지

    public func start() throws {
        try queue.sync { try startOnQueue() }
    }

    public func stop() {
        queue.sync { shutdown(notify: true) }
    }

    /// 대기 중인 요청에 응답한다. 모르는 ID 면 아무것도 하지 않는다. 아무 스레드에서나 호출 가능.
    public func reply(to id: UUID, output: JSONValue?) {
        let reply = HookReply(output: output)
        queue.async { [weak self] in
            self?.deliver(reply, to: id)
        }
    }

    private func startOnQueue() throws {
        guard listenSource == nil else { return }

        var address = sockaddr_un()
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        // NUL 종료 문자 자리를 남겨야 한다
        guard !pathBytes.isEmpty, pathBytes.count < capacity else {
            throw SocketServerError.pathTooLong
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        try prepareDirectory()
        try removeStaleSocket(address: address)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketServerError.systemCall(name: "socket", code: errno) }
        var started = false
        defer { if !started { _ = Darwin.close(fd) } }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            if code == EADDRINUSE { throw SocketServerError.alreadyRunning }
            throw SocketServerError.systemCall(name: "bind", code: code)
        }
        // 디렉터리가 0700 이라 bind ~ chmod 사이에도 다른 사용자는 소켓에 접근할 수 없다
        guard chmod(socketPath, 0o600) == 0 else {
            let code = errno
            unlink(socketPath)
            throw SocketServerError.systemCall(name: "chmod", code: code)
        }
        guard listen(fd, 64) == 0, Self.setNonBlocking(fd) else {
            let code = errno
            unlink(socketPath)
            throw SocketServerError.systemCall(name: "listen", code: code)
        }

        var info = stat()
        if lstat(socketPath, &info) == 0 {
            socketIdentity = (info.st_dev, info.st_ino)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        source.setCancelHandler {
            _ = Darwin.close(fd)
        }
        listenFD = fd
        listenSource = source
        started = true
        source.resume()
        log.info("소켓 서버 시작")
    }

    /// 소켓 디렉터리를 0700 으로 준비한다.
    /// 이미 있는 디렉터리는 앱 전용 폴더(AgentNotch)일 때만 권한을 조인다 (/tmp 같은 공용 폴더는 건드리지 않음).
    private func prepareDirectory() throws {
        let directory = (socketPath as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { return }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw SocketServerError.systemCall(name: "mkdir", code: ENOTDIR)
            }
            if (directory as NSString).lastPathComponent == NotchWire.appFolderName, chmod(directory, 0o700) != 0 {
                throw SocketServerError.systemCall(name: "chmod", code: errno)
            }
        } else {
            do {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw SocketServerError.systemCall(name: "mkdir", code: Self.posixCode(of: error))
            }
        }
    }

    /// 남아 있는 소켓 파일 처리: 누군가 연결을 받으면 이미 실행 중, 아니면 지난 실행의 찌꺼기라 지운다.
    private func removeStaleSocket(address: sockaddr_un) throws {
        var info = stat()
        guard lstat(socketPath, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw SocketServerError.pathOccupied
        }
        if Self.canConnect(to: address) {
            throw SocketServerError.alreadyRunning
        }
        if unlink(socketPath) != 0, errno != ENOENT {
            throw SocketServerError.systemCall(name: "unlink", code: errno)
        }
    }

    private func shutdown(notify: Bool) {
        if let source = listenSource {
            source.cancel()
            listenSource = nil
            listenFD = -1
            removeOwnSocketFile()
            log.info("소켓 서버 정지")
        }
        for (id, connection) in pending {
            send(HookReply(output: nil), to: connection)
            finish(connection)
            if notify { notifyCancelled(id) }
        }
        pending.removeAll()
        // ID 를 기다리던 연결은 닫기만 한다 (attach 에서 취소를 알린다)
        for connection in Array(connections.values) {
            finish(connection)
        }
        earlyReplies.removeAll()
    }

    private func removeOwnSocketFile() {
        defer { socketIdentity = nil }
        guard let identity = socketIdentity else { return }
        var info = stat()
        guard lstat(socketPath, &info) == 0,
              info.st_dev == identity.device,
              info.st_ino == identity.inode else { return }
        unlink(socketPath)
    }

    // MARK: - 연결 수락

    private func acceptConnections() {
        while listenFD >= 0 {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                switch errno {
                case EINTR, ECONNABORTED: continue
                default: return  // EAGAIN: 더 받을 연결 없음
                }
            }
            setUpConnection(fd)
        }
    }

    private func setUpConnection(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        guard Self.peerIsCurrentUser(fd) else {
            log.error("다른 사용자의 연결 거부")
            _ = Darwin.close(fd)
            return
        }
        guard connections.count < Self.maxConnections, Self.setNonBlocking(fd) else {
            log.error("연결 수 초과 또는 소켓 설정 실패 → 거부")
            _ = Darwin.close(fd)
            return
        }

        let connection = Connection(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.readAvailable(connection)
        }
        // fd 는 소스 취소가 끝난 뒤에만 닫는다 (fd 재사용 경쟁 방지)
        source.setCancelHandler {
            _ = Darwin.close(fd)
        }
        connection.source = source
        connections[ObjectIdentifier(connection)] = connection
        armTimer(for: connection, after: Self.lineReadTimeout) { [weak self, weak connection] in
            guard let self, let connection, case .reading = connection.state else { return }
            self.log.error("envelope 수신 시간 초과 → 연결 종료")
            self.finish(connection)
        }
        source.resume()
    }

    // MARK: - 읽기

    private func readAvailable(_ connection: Connection) {
        while connection.isOpen {
            let count = Darwin.read(connection.fd, readChunk.baseAddress, readChunk.count)
            if count > 0 {
                consume(connection, bytes: UnsafeRawBufferPointer(start: readChunk.baseAddress, count: count))
            } else if count == 0 {
                peerClosed(connection)
                return
            } else {
                switch errno {
                case EINTR: continue
                case EAGAIN, EWOULDBLOCK: return
                default:
                    peerClosed(connection)
                    return
                }
            }
        }
    }

    private func consume(_ connection: Connection, bytes: UnsafeRawBufferPointer) {
        // 한 줄을 받은 뒤 들어오는 데이터는 버린다 (끊김 감지용으로만 계속 읽음)
        guard case .reading = connection.state, let base = bytes.baseAddress else { return }
        let searchStart = connection.buffer.count
        connection.buffer.append(base.assumingMemoryBound(to: UInt8.self), count: bytes.count)

        if let newline = connection.buffer[searchStart...].firstIndex(of: 0x0A) {
            guard newline <= Self.maxLineBytes else {
                log.error("envelope 크기 초과 → 연결 종료")
                finish(connection)
                return
            }
            let line = connection.buffer.subdata(in: connection.buffer.startIndex..<newline)
            connection.buffer = Data()
            handleLine(line, from: connection, peerHasClosed: false)
        } else if connection.buffer.count > Self.maxLineBytes {
            log.error("envelope 크기 초과 → 연결 종료")
            finish(connection)
        }
    }

    private func handleLine(_ line: Data, from connection: Connection, peerHasClosed: Bool) {
        connection.cancelTimer()
        let envelope: HookEnvelope
        do {
            envelope = try JSONDecoder().decode(HookEnvelope.self, from: line)
        } catch {
            log.error("envelope 해석 실패 → 연결 종료")
            finish(connection)
            return
        }
        log.debug("이벤트 수신: \(envelope.event, privacy: .public)")

        let waitsForReply = envelope.expectsReply && !peerHasClosed
        if waitsForReply {
            connection.state = .awaitingID
            awaitingIDCount += 1
        } else {
            finish(connection)
            // 응답을 기다리던 클라이언트가 이미 끊겼으면 요청 자체를 만들지 않는다
            if envelope.expectsReply { return }
        }

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let id = self.onEnvelope?(envelope)
                guard waitsForReply else { return }
                let timeout = Self.clampedReplyTimeout(self.replyTimeout())
                self.queue.async {
                    self.attach(connection, id: id, timeout: timeout)
                }
            }
        }
    }

    /// 메인 액터에서 받은 요청 ID 를 연결에 붙이고 응답 대기 타이머를 건다.
    private func attach(_ connection: Connection, id: UUID?, timeout: TimeInterval) {
        awaitingIDCount -= 1
        defer {
            if awaitingIDCount == 0 { earlyReplies.removeAll() }
        }
        let earlyReply = id.flatMap { earlyReplies.removeValue(forKey: $0) }

        guard case .awaitingID = connection.state else {
            // ID 를 받기 전에 클라이언트가 끊겼거나 서버가 멈춤
            if let id, earlyReply == nil { notifyCancelled(id) }
            return
        }
        guard let id, pending[id] == nil else {
            // 대기시킬 요청이 없음 → 결정 위임
            send(HookReply(output: nil), to: connection)
            finish(connection)
            return
        }
        if let earlyReply {
            send(earlyReply, to: connection)
            finish(connection)
            return
        }

        connection.state = .pending(id)
        pending[id] = connection
        armTimer(for: connection, after: timeout) { [weak self, weak connection] in
            guard let self, let connection, case .pending(let id) = connection.state else { return }
            self.log.info("권한 응답 시간 초과 → 결정 위임")
            self.pending[id] = nil
            self.send(HookReply(output: nil), to: connection)
            self.finish(connection)
            self.notifyCancelled(id)
        }
    }

    private func peerClosed(_ connection: Connection) {
        switch connection.state {
        case .reading:
            // 줄바꿈 없이 끝난 마지막 줄도 응답이 필요 없는 이벤트면 받아 준다 (빈 연결 = --ping)
            let leftover = connection.buffer
            connection.buffer = Data()
            if leftover.isEmpty {
                finish(connection)
            } else {
                handleLine(leftover, from: connection, peerHasClosed: true)
            }
        case .awaitingID:
            finish(connection)  // attach 에서 취소를 알린다
        case .pending(let id):
            log.info("권한 대기 중 클라이언트 연결 끊김")
            pending[id] = nil
            finish(connection)
            notifyCancelled(id)
        case .closed:
            break
        }
    }

    // MARK: - 응답

    private func deliver(_ reply: HookReply, to id: UUID) {
        if let connection = pending.removeValue(forKey: id) {
            send(reply, to: connection)
            finish(connection)
        } else if awaitingIDCount > 0 {
            earlyReplies[id] = reply
        }
    }

    private func send(_ reply: HookReply, to connection: Connection) {
        guard connection.isOpen else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(reply) else { return }
        data.append(0x0A)
        let sent = data.withUnsafeBytes { Self.writeAll($0, to: connection.fd, timeout: Self.writeTimeout) }
        if !sent {
            log.error("응답 전송 실패")
        }
    }

    private func finish(_ connection: Connection) {
        guard connection.isOpen else { return }
        connection.state = .closed
        connection.cancelTimer()
        connection.source?.cancel()  // 취소 핸들러가 fd 를 닫는다
        connection.source = nil
        connections[ObjectIdentifier(connection)] = nil
    }

    private func notifyCancelled(_ id: UUID) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.onPendingCancelled?(id)
            }
        }
    }

    private func armTimer(for connection: Connection, after seconds: TimeInterval, handler: @escaping () -> Void) {
        connection.cancelTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: handler)
        connection.timer = timer
        timer.resume()
    }

    private func withCallbackLock<T>(_ body: () -> T) -> T {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return body()
    }

    // MARK: - POSIX 헬퍼

    static func clampedReplyTimeout(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 120 }
        return min(max(value, 0.05), maxReplyTimeout)
    }

    private static func setNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return false }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == getuid()
    }

    /// 논블로킹 소켓에 끝까지 쓴다 (부분 쓰기·EINTR·EAGAIN 처리, 전체 시간 제한)
    private static func writeAll(_ bytes: UnsafeRawBufferPointer, to fd: Int32, timeout: TimeInterval) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(fd, base + offset, bytes.count - offset)
            if written > 0 {
                offset += written
                continue
            }
            guard written < 0 else { return false }
            switch errno {
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK:
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return false }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptor, 1, Int32((remaining * 1000).rounded(.up)))
                if ready < 0, errno != EINTR { return false }
            default:
                return false
            }
        }
        return true
    }

    /// 소켓 파일에 연결을 받는 프로세스가 있는지 확인
    private static func canConnect(to address: sockaddr_un) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { _ = Darwin.close(fd) }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = address
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private static func posixCode(of error: Error) -> Int32 {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return Int32(nsError.code) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return EIO
    }
}

// MARK: - 연결

/// 연결 하나의 상태. 서버의 직렬 큐에서만 다룬다.
private final class Connection: @unchecked Sendable {
    enum State {
        /// envelope 한 줄을 읽는 중
        case reading
        /// 메인 액터가 요청 ID 를 정하길 기다리는 중
        case awaitingID
        /// 사용자 결정을 기다리는 중
        case pending(UUID)
        case closed
    }

    let fd: Int32
    var state: State = .reading
    var buffer = Data()
    var source: DispatchSourceRead?
    var timer: DispatchSourceTimer?

    init(fd: Int32) {
        self.fd = fd
    }

    var isOpen: Bool {
        if case .closed = state { return false }
        return true
    }

    func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}
