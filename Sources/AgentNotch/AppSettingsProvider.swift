import AppKit
import Foundation
import NotchCore
import NotchServices
import NotchShared
import NotchUI
import os

/// 설정 화면·메뉴가 쓰는 훅 설치 / 로그인 시 실행 / 버전 정보.
/// 훅은 에이전트마다 설치기가 따로 있고(Claude Code `~/.claude/settings.json` · Codex `~/.codex/hooks.json`) 헬퍼는 하나를 같이 쓴다
@MainActor
final class AppSettingsProvider: SettingsProvider {
    private let installers: [AgentKind: HookInstaller]
    private let loginItem: MainAppLoginItem
    let preferences: AppPreferences
    /// 전역 단축키 등록 상태 (AppDelegate 가 켤 때 넣는다)
    var globalShortcut: GlobalShortcutState?

    /// 훅을 설치 · 제거 · 고쳤을 때 (Codex 훅 허용 확인을 다시 본다)
    var onHooksChanged: (() -> Void)?

    init(installers: [AgentKind: HookInstaller], loginItem: MainAppLoginItem, preferences: AppPreferences) {
        self.installers = installers
        self.loginItem = loginItem
        self.preferences = preferences
        reloadCodexFingerprint()
    }

    var appVersion: String { AppInfo.displayVersion }

    private func installer(_ agent: AgentKind) -> HookInstaller {
        installers[agent] ?? HookInstaller(agent: agent)
    }

    /// 읽을 때마다 설정 파일을 다시 읽는다. 상태와 문구가 둘 다 필요하면 한 번 읽고 `hookStatusText(for:)` 를 쓴다
    func hookStatus(for agent: AgentKind) -> HookInstallStatus { installer(agent).status() }

    /// Codex 를 쓰는 맥인지 (`~/.codex` 폴더나 Codex 앱이 있음). 첫 실행 안내가 Codex 훅도 물어볼지 정한다
    var codexAvailable: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path) { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalContext.codexDesktopBundleID) != nil
    }

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

    /// 설정 화면용: 설정 파일을 한 번 읽어 문구와 설치 여부(우리 훅 항목이 하나라도 있으면 true, 제거 버튼 활성화 기준)를 함께 만든다
    func hookState(for agent: AgentKind) -> (text: String, installed: Bool) {
        let status = hookStatus(for: agent)
        var text = Self.hookStatusText(for: status)
        if agent == .codex, status != .notInstalled, codexHooksAwaitingTrust {
            text += " · Codex 에서 허용 필요"
        }
        return (text, status != .notInstalled)
    }

    // MARK: - Codex 훅 허용 확인

    /// Codex 는 사용자가 검토해 믿은 훅만 돌린다. 그 믿음을 직접 읽지 않고(문서에 없는 내부 형식), Codex 훅 이벤트가 실제로 왔을 때의
    /// 우리 훅 지문(`HookInstaller.managedFingerprint`)을 기억한다. 지금 설치된 지문과 같으면 이 훅 내용으로 돌고 있는 것이다
    static let codexConfirmedKey = "codexHooksConfirmedFingerprint"

    /// 지금 설치된 Codex 훅 지문 (설치 안 됐으면 nil). 설치 · 제거 · 고치기 뒤와 허용을 기다리는 동안 다시 읽는다
    private(set) var codexFingerprint: String?

    func reloadCodexFingerprint() {
        codexFingerprint = installer(.codex).managedFingerprint()
    }

    /// Codex 훅 설정 파일을 마지막으로 바꾼 시각 (설치 · 고친 때)
    var codexHooksModifiedAt: Date? { installer(.codex).settingsModifiedAt() }

    /// Codex 훅이 설치돼 있는데 그 내용으로 Codex 이벤트를 아직 받아 보지 못함 (Codex 에서 허용이 필요할 수 있다)
    var codexHooksAwaitingTrust: Bool {
        guard let fingerprint = codexFingerprint else { return false }
        return UserDefaults.standard.string(forKey: Self.codexConfirmedKey) != fingerprint
    }

    /// Codex 훅 이벤트가 왔다: 지금 훅 내용을 Codex 가 믿고 돌리는 중이라고 기억한다. 새로 기억했으면 true
    @discardableResult
    func confirmCodexHooks() -> Bool {
        guard codexHooksAwaitingTrust, let fingerprint = codexFingerprint else { return false }
        UserDefaults.standard.set(fingerprint, forKey: Self.codexConfirmedKey)
        return true
    }

    /// 헬퍼를 복사하고 그 에이전트의 훅 설정에 AgentNotch 항목을 등록한다 (기존 파일은 백업)
    func installHooks(for agent: AgentKind) throws {
        guard let helper = AppInfo.helperURL() else { throw HookInstallerError.helperSourceMissing }
        defer { hooksChanged() }
        try installer(agent).install(helperSource: helper, includeMessageDisplay: preferences.showStreamingText)
    }

    private func hooksChanged() {
        reloadCodexFingerprint()
        onHooksChanged?()
    }

    /// 그 에이전트의 AgentNotch 훅만 제거하고, 어느 에이전트에도 남은 항목이 없으면 복사해 둔 헬퍼도 지운다
    func uninstallHooks(for agent: AgentKind) throws {
        defer { hooksChanged() }
        try installer(agent).uninstall()
        if AgentKind.allCases.allSatisfy({ installer($0).status() == .notInstalled }) {
            try? installer(agent).removeHelper()
        }
    }

    /// 앱 업데이트 후 헬퍼가 바뀌었으면 다시 복사하고, 예전 버전이 설치한 훅 항목을 지금 형태로 고친다
    /// (예: 질문 · 계획 승인을 노치에서 답하도록 PreToolUse 에 응답 대기 시간 · timeout 600).
    /// 설치한 적 없으면 아무것도 안 한다. 설정은 우리 항목만 고치고 바꾸기 전에 백업을 남긴다
    func refreshHelperIfNeeded() {
        guard let helper = AppInfo.helperURL() else { return }
        defer { hooksChanged() }
        for agent in AgentKind.allCases {
            let installer = installer(agent)
            _ = try? installer.refreshHelperIfInstalled(helperSource: helper)
            do {
                if try installer.updateInstalledHooks() != nil {
                    Self.log.info("예전 훅 설정을 고침 (\(agent.rawValue, privacy: .public), 백업 남김)")
                }
            } catch {
                Self.log.error("훅 설정을 고치지 못함 (\(agent.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static let log = Logger(subsystem: NotchServices.logSubsystem, category: "hooks")

    /// 시스템 설정 > 로그인 항목의 실제 상태 (`SMAppService.mainApp`)
    var launchAtLoginEnabled: Bool { loginItem.isEnabled }

    /// 앱 번들로 실행 중이라 로그인 항목을 등록할 수 있는지 (첫 실행 안내가 물어볼지 정한다)
    var launchAtLoginAvailable: Bool { loginItem.isAvailable }

    /// 예전 `brew services` LaunchAgent 가 남아 있으면 true (설정 스위치를 잠가 두 번 뜨지 않게 한다)
    var launchAtLoginManagedByHomebrew: Bool { loginItem.isManagedByHomebrewServices }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        try loginItem.setEnabled(enabled)
    }
}
