import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 앱 소켓 서버와 훅 헬퍼(테스트 클라이언트 포함)가 같이 쓰는 Unix 도메인 소켓 도우미.
/// 주소 만들기 · 같은 사용자 확인이 곳곳에 따로 있으면 한쪽만 바뀌어 기준이 어긋난다 (예전엔 서버만 실제 UID 로 비교했다)
public enum UnixSocket {
    /// 경로로 `sockaddr_un` 을 만든다. 비었거나 `sun_path`(NUL 포함 104바이트)에 들어가지 않으면 nil
    public static func address(path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// 주소를 `sockaddr` 포인터 · 길이로 넘긴다 (`connect` · `bind` 용)
    public static func withSockaddr<T>(_ address: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var address = address
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// 연결 상대가 같은 사용자인지 (권한 결정을 위조당하지 않게). `getpeereid` 는 상대의 유효 UID 를 주므로 유효 UID 와 비교한다
    public static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        #if canImport(Darwin)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == geteuid()
        #else
        return true
        #endif
    }
}
