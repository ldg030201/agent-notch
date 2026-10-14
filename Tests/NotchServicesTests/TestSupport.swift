import Darwin
import Foundation
import NotchShared
@testable import NotchServices

/// /tmp 아래 테스트 전용 임시 폴더 (테스트가 끝나면 지운다)
struct TempDirectory {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("agentnotch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// `sun_path` 한도(104바이트)에 걸리지 않는 짧은 소켓 경로
func shortSocketPath() -> String {
    "/tmp/an-\(UUID().uuidString.prefix(8).lowercased()).sock"
}

func posixPermissions(_ path: String) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
}

func makeEnvelope(event: String, expectsReply: Bool = false) -> HookEnvelope {
    HookEnvelope(
        event: event,
        sentAt: 1_760_000_000.25,
        env: ["TERM_PROGRAM": "iTerm.app"],
        expectsReply: expectsReply,
        payload: .object([
            "session_id": .string("test-session"),
            "cwd": .string("/Users/dev/projects/api-server"),
            "hook_event_name": .string(event),
            "tool_name": .string("Bash"),
            "tool_input": .object(["command": .string("npm test")]),
        ])
    )
}

/// 블로킹 POSIX 호출을 메인 스레드 밖에서 실행
func runBlocking<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: body())
        }
    }
}

/// 조건이 참이 될 때까지 메인 액터에서 기다린다 (그동안 메인 큐 콜백이 실행됨)
@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

/// 헬퍼 대신 쓰는 순수 POSIX 소켓 클라이언트
final class TestClient: @unchecked Sendable {
    let fd: Int32
    private var closed = false

    init?(path: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
    }

    deinit { close() }

    func send(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.send(fd, base + offset, raw.count - offset, 0)
                if sent > 0 {
                    offset += sent
                } else if sent < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    func sendLine(_ envelope: HookEnvelope) -> Bool {
        guard var data = try? JSONEncoder().encode(envelope) else { return false }
        data.append(0x0A)
        return send(data)
    }

    /// 줄바꿈까지 읽는다 (줄바꿈 제외). 시간 초과·EOF 면 nil.
    func readLine(timeout: TimeInterval) -> Data? {
        setReceiveTimeout(timeout)
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let count = recv(fd, &byte, 1, 0)
            if count == 1 {
                if byte == 0x0A { return buffer }
                buffer.append(byte)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
    }

    /// EOF 까지 읽은 바이트. 시간 초과면 nil.
    func readUntilEOF(timeout: TimeInterval) -> Data? {
        setReceiveTimeout(timeout)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                return buffer
            } else if errno == EINTR {
                continue
            } else if errno == ECONNRESET {
                return buffer
            } else {
                return nil
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    private func setReceiveTimeout(_ seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// 소켓 파일과 그 옆 인스턴스 잠금 파일(`<소켓>.lock`)을 지운다 (서버는 잠금 파일을 남겨 두므로 테스트가 정리)
func removeSocketFiles(_ path: String) {
    unlink(path)
    unlink(path + ".lock")
}

/// 방금 놓은 인스턴스 잠금을 다시 잡을 때의 시도 횟수 (약 0.2초).
/// 다른 테스트가 자식 프로세스를 띄우는 순간(fork ~ exec 사이) 자식이 잠금 fd 를 잠깐 함께 쥘 수 있어서다
let retryingLockAttempts = 10

/// 다른 프로세스처럼 인스턴스 잠금을 직접 쥔다 (실패하면 -1). 방금 놓은 잠금일 수 있어 잠깐씩 몇 번 다시 시도한다
func holdInstanceLock(_ socketPath: String) -> Int32 {
    for attempt in 1...retryingLockAttempts {
        let fd = open(socketPath + ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0o600)
        if fd >= 0 || errno != EWOULDBLOCK { return fd }
        if attempt < retryingLockAttempts { usleep(SocketServer.lockRetryInterval) }
    }
    return -1
}

/// bind 만 하고 listen 없이 닫은 소켓 파일 (지난 실행의 찌꺼기, 또는 bind~listen 사이의 다른 인스턴스)
func bindUnlistenedSocket(_ path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    return bound == 0
}
