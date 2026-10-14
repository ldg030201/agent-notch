import Foundation
import NotchCore
import NotchServices
import NotchUI
import os

/// 설정 화면·메뉴가 쓰는 훅 설치 / 로그인 시 실행 / 버전 정보
@MainActor
final class AppSettingsProvider: SettingsProvider {
    private let installer: HookInstaller
    private let loginItem: MainAppLoginItem
    private let preferences: AppPreferences

    init(installer: HookInstaller, loginItem: MainAppLoginItem, preferences: AppPreferences) {
        self.installer = installer
        self.loginItem = loginItem
        self.preferences = preferences
    }

    var appVersion: String { AppInfo.displayVersion }

    /// 읽을 때마다 settings.json 을 다시 읽는다. 상태와 문구가 둘 다 필요하면 한 번 읽고 `hookStatusText(for:)` 를 쓴다
    var hookStatus: HookInstallStatus { installer.status() }

    static func hookStatusText(for status: HookInstallStatus) -> String {
        switch status {
        case .partial(let missing):
            return "일부만 설치됨 (빠진 이벤트: \(missing.joined(separator: ", ")))"
        case .helperMissing:
            return "헬퍼 없음 (다시 설치 필요)"
        case let status:
            return status.description
        }
    }

    /// 설정 화면용: settings.json 을 한 번 읽어 문구와 설치 여부(우리 훅 항목이 하나라도 있으면 true, 제거 버튼 활성화 기준)를 함께 만든다
    var hookState: (text: String, installed: Bool) {
        let status = hookStatus
        return (Self.hookStatusText(for: status), status != .notInstalled)
    }

    /// 헬퍼를 복사하고 `~/.claude/settings.json` 에 훅을 등록한다 (기존 파일은 백업)
    func installHooks() throws {
        guard let helper = AppInfo.helperURL() else { throw HookInstallerError.helperSourceMissing }
        try installer.install(helperSource: helper, includeMessageDisplay: preferences.showStreamingText)
    }

    /// AgentNotch 훅만 제거하고, 남은 항목이 없으면 복사해 둔 헬퍼도 지운다
    func uninstallHooks() throws {
        try installer.uninstall()
        if installer.status() == .notInstalled {
            try? installer.removeHelper()
        }
    }

    /// 앱 업데이트 후 헬퍼가 바뀌었으면 다시 복사하고, 예전 버전이 설치한 훅 항목을 지금 형태로 고친다
    /// (예: 질문 · 계획 승인을 노치에서 답하도록 PreToolUse 에 응답 대기 시간 · timeout 600).
    /// 설치한 적 없으면 아무것도 안 한다. 설정은 우리 항목만 고치고 바꾸기 전에 백업을 남긴다
    func refreshHelperIfNeeded() {
        guard let helper = AppInfo.helperURL() else { return }
        _ = try? installer.refreshHelperIfInstalled(helperSource: helper)
        do {
            if try installer.updateInstalledHooks() != nil {
                Self.log.info("예전 훅 설정을 고침 (백업 남김)")
            }
        } catch {
            Self.log.error("훅 설정을 고치지 못함: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let log = Logger(subsystem: NotchServices.logSubsystem, category: "hooks")

    /// 시스템 설정 > 로그인 항목의 실제 상태 (`SMAppService.mainApp`)
    var launchAtLoginEnabled: Bool { loginItem.isEnabled }

    /// 예전 `brew services` LaunchAgent 가 남아 있으면 true (설정 스위치를 잠가 두 번 뜨지 않게 한다)
    var launchAtLoginManagedByHomebrew: Bool { loginItem.isManagedByHomebrewServices }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        try loginItem.setEnabled(enabled)
    }
}
