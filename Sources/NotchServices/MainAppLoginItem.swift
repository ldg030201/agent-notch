import Foundation
import ServiceManagement

/// 로그인 시 실행 (`SMAppService.mainApp`). 등록 상태는 시스템이 들고 있어서 시스템 설정 > 로그인 항목과 항상 일치한다.
///
/// 앱 번들로 실행할 때만 동작한다 (`swift run` 처럼 번들이 아니면 `isAvailable == false`).
@MainActor
public final class MainAppLoginItem {
    /// 예전 formula 의 `brew services start agent-notch` 가 만든 LaunchAgent
    public nonisolated static let legacyHomebrewPlistName = "homebrew.mxcl.agent-notch.plist"

    public enum LoginItemError: LocalizedError {
        case notBundled
        case requiresApproval

        public var errorDescription: String? {
            switch self {
            case .notBundled:
                return "앱 번들로 실행할 때만 쓸 수 있어요."
            case .requiresApproval:
                return "시스템 설정 > 일반 > 로그인 항목에서 AgentNotch 를 허용해 주세요."
            }
        }
    }

    private let launchAgentsDirectory: URL
    private let fileManager: FileManager

    public init(
        launchAgentsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.launchAgentsDirectory = launchAgentsDirectory
        self.fileManager = fileManager
    }

    private var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    public var isEnabled: Bool {
        status == .enabled
    }

    /// 등록은 됐지만 사용자가 시스템 설정에서 허용해야 하는 상태
    public var requiresApproval: Bool {
        status == .requiresApproval
    }

    /// 앱 번들로 실행 중이라 로그인 항목을 등록할 수 있는지
    public var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// `brew services` 로 로그인 실행을 걸어 둔 흔적이 있는지 (읽기만 한다).
    /// 있으면 두 번 뜨지 않게 설정 화면의 스위치를 잠근다.
    public var isManagedByHomebrewServices: Bool {
        fileManager.fileExists(atPath: launchAgentsDirectory.appendingPathComponent(Self.legacyHomebrewPlistName).path)
    }

    public func setEnabled(_ enabled: Bool) throws {
        guard isAvailable else { throw LoginItemError.notBundled }
        if enabled {
            if status != .enabled {
                try SMAppService.mainApp.register()
            }
            if status == .requiresApproval {
                openSystemSettings()
                throw LoginItemError.requiresApproval
            }
        } else {
            guard status == .enabled || status == .requiresApproval else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    /// 시스템 설정의 로그인 항목 화면 열기 (승인이 필요할 때)
    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
