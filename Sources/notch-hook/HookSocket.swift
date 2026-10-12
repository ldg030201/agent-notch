import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 앱 소켓에 붙는 최소한의 POSIX Unix 도메인 소켓 클라이언트.
/// 실패는 모두 nil/false 로만 알린다 (호출부는 조용히 종료).
final class HookSocket {
    private let fd: Int32
    private var isClosed = false

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close()
    }

    /// 연결 실패(소켓 없음, 앱 꺼짐, 경로 너무 김, 다른 사용자 소유 등) 시 nil.
    static func connect(path: String, sendTimeout: TimeInterval, debug: HookDebug) -> HookSocket? {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        // sun_path 는 NUL 포함 104바이트 제한
        guard !pathBytes.isEmpty, pathBytes.count < capacity else {
            debug.log("소켓 경로가 너무 김 (\(pathBytes.count)바이트)")
            return nil
        }

        let fd = socket(AF_UNIX, Int32(SOCK_STREAM), 0)
        guard fd >= 0 else {
            debug.log("socket() 실패 errno=\(errno)")
            return nil
        }
        let client = HookSocket(fd: fd)

        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        #if canImport(Darwin)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var timeout = timeval(seconds: sendTimeout)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        address.sun_family = sa_family_t(AF_UNIX)
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                posixConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            debug.log("connect() 실패 errno=\(errno)")
            return nil
        }

        // 같은 사용자의 프로세스가 연 소켓인지 확인 (권한 결정을 위조당하지 않게)
        guard client.peerIsCurrentUser() else {
            debug.log("소켓 소유자가 현재 사용자가 아님")
            return nil
        }
        return client
    }

    private func peerIsCurrentUser() -> Bool {
        #if canImport(Darwin)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == geteuid()
        #else
        return true
        #endif
    }

    /// 전부 보내면 true. 송신 타임아웃(SO_SNDTIMEO)·끊김 시 false.
    func sendAll(_ data: Data) -> Bool {
        guard !isClosed else { return false }
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let sent = send(fd, base + offset, raw.count - offset, flags)
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

    /// 줄바꿈으로 끝나는 한 줄을 기다린다 (줄바꿈 제외).
    /// 타임아웃·EOF·크기 초과·부모 프로세스 종료 시 nil.
    func readLine(timeout: TimeInterval, maxBytes: Int, shouldAbort: () -> Bool) -> Data? {
        guard !isClosed else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return nil }
            if shouldAbort() { return nil }

            // 부모 종료를 확인할 수 있게 최대 1초씩 나눠서 기다린다
            let slice = min(remaining, 1.0)
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32((slice * 1000).rounded(.up)))
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if ready == 0 { continue }

            let received = chunk.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress, raw.count, 0)
            }
            if received > 0 {
                let bytes = chunk[0..<received]
                if let newline = bytes.firstIndex(of: 0x0A) {
                    buffer.append(contentsOf: bytes[bytes.startIndex..<newline])
                    return buffer
                }
                buffer.append(contentsOf: bytes)
                if buffer.count > maxBytes { return nil }
            } else if received == 0 {
                return nil  // 앱이 응답 없이 연결을 닫음
            } else if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            } else {
                return nil
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #else
        _ = Glibc.close(fd)
        #endif
    }
}

/// `HookSocket.connect` 와 이름이 겹치지 않게 감싼 POSIX connect
private func posixConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    Darwin.connect(fd, address, length)
    #else
    Glibc.connect(fd, address, length)
    #endif
}

private extension timeval {
    init(seconds: TimeInterval) {
        let whole = max(0, seconds.rounded(.down))
        self.init()
        tv_sec = numericCast(Int(whole))
        tv_usec = numericCast(Int((seconds - whole) * 1_000_000))
    }
}
