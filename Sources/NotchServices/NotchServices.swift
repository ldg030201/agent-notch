import Foundation
import NotchShared
import os

/// 시스템 연동 서비스 모듈 (소켓 서버, 훅 설치기, 터미널 점프, 업데이트 확인·업그레이드 등)
public enum NotchServices {
    /// os.Logger 서브시스템 (`NotchWire.logSubsystem`). 동적인 값은 항상 `privacy: .private` 로 남긴다.
    public static let logSubsystem = NotchWire.logSubsystem

    static func logger(_ category: String) -> Logger {
        Logger(subsystem: logSubsystem, category: category)
    }

    /// Claude Code 설정 · 기록 폴더 (`~/.claude`)
    static var claudeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }
}
