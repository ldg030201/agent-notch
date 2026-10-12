import Foundation

/// 로그인 시 실행 (사용자 LaunchAgent plist).
///
/// plist 를 쓰거나 지우기만 하고 `launchctl` 은 호출하지 않는다 (다음 로그인부터 적용).
/// Homebrew 로 설치해 `brew services` 가 관리 중이면 중복 실행되지 않도록 UI 에서 안내한다.
@MainActor
public final class LoginItemManager {
    public nonisolated static let label = "dev.agentnotch.AgentNotch"
    /// `brew services start agent-notch` 가 만드는 LaunchAgent
    public nonisolated static let homebrewPlistName = "homebrew.mxcl.agent-notch.plist"

    public nonisolated static var defaultLaunchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    public let launchAgentsDirectory: URL
    public let executablePath: String
    private let fileManager: FileManager

    public init(
        launchAgentsDirectory: URL = LoginItemManager.defaultLaunchAgentsDirectory,
        executablePath: String,
        fileManager: FileManager = .default
    ) {
        self.launchAgentsDirectory = launchAgentsDirectory
        self.executablePath = executablePath
        self.fileManager = fileManager
    }

    public var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(Self.label).plist")
    }

    public var isEnabled: Bool {
        fileManager.fileExists(atPath: plistURL.path)
    }

    /// `brew services` 가 로그인 실행을 관리하는지
    public var isManagedByHomebrew: Bool {
        fileManager.fileExists(atPath: launchAgentsDirectory.appendingPathComponent(Self.homebrewPlistName).path)
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try writePlist()
        } else if fileManager.fileExists(atPath: plistURL.path) {
            try fileManager.removeItem(at: plistURL)
        }
    }

    /// LaunchAgent 내용
    public var plistContents: [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
    }

    private func writePlist() throws {
        if !fileManager.fileExists(atPath: launchAgentsDirectory.path) {
            try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plistContents, format: .xml, options: 0)
        // launchd 는 그룹/전체 쓰기 권한이 있는 plist 를 거부하므로 0644 로 만든다
        try AtomicFile.write(data, to: plistURL, permissions: 0o644)
    }
}
