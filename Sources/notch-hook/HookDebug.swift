import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// `AGENT_NOTCH_DEBUG=1` 일 때만 stderr 로 짧은 진단을 남긴다.
/// payload 내용(프롬프트·코드·응답)은 절대 출력하지 않는다. 이벤트 이름, 크기, errno 정도만.
struct HookDebug {
    let enabled: Bool

    func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "notch-hook: " + message() + "\n"
        StandardStream.write(Data(line.utf8), to: STDERR_FILENO)
    }
}

/// FileHandle 은 쓰기 실패 시 Objective-C 예외로 죽을 수 있어서 POSIX write 를 쓴다.
enum StandardStream {
    @discardableResult
    static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                #if canImport(Darwin)
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                #else
                let written = Glibc.write(fd, base + offset, raw.count - offset)
                #endif
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// stdin 을 끝까지 읽는다. limit 를 넘는 부분은 읽어서 버린다
    /// (중간에 그만 읽으면 Claude Code 쪽 파이프 쓰기가 막힐 수 있음).
    /// - Returns: (읽은 데이터, limit 초과 여부)
    static func readAll(from fd: Int32, limit: Int) -> (data: Data, overflowed: Bool) {
        if isatty(fd) != 0 { return (Data(), false) }  // 손으로 실행했을 때 입력 대기로 멈추지 않게
        var data = Data()
        var overflowed = false
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            if count > 0 {
                if overflowed || data.count + count > limit {
                    overflowed = true
                } else {
                    data.append(contentsOf: chunk[0..<count])
                }
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        return (overflowed ? Data() : data, overflowed)
    }
}
