import os

/// 시스템 연동 서비스 모듈 (소켓 서버, 훅 설치기, 터미널 점프, 사운드 등)
public enum NotchServices {
    /// os.Logger 서브시스템. 동적인 값은 항상 `privacy: .private` 로 남긴다.
    static let logSubsystem = "dev.agentnotch.AgentNotch"

    static func logger(_ category: String) -> Logger {
        Logger(subsystem: logSubsystem, category: category)
    }
}
