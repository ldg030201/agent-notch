import AppKit
import SwiftUI
import NotchCore
import NotchShared

/// 설정 화면이 App 에서 가져오는 정보와 동작 (훅 설치, 로그인 시 실행 등).
/// NotchUI 가 NotchServices 에 직접 의존하지 않도록 App 이 구현해 주입한다.
@MainActor
public protocol SettingsProvider: AnyObject {
    var appVersion: String { get }
    /// 에이전트의 훅 설치 상태 문구와 설치 여부 (설정 파일을 한 번만 읽어 둘 다 만든다)
    func hookState(for agent: AgentKind) -> (text: String, installed: Bool)
    func installHooks(for agent: AgentKind) throws
    func uninstallHooks(for agent: AgentKind) throws
    var launchAtLoginEnabled: Bool { get }
    var launchAtLoginManagedByHomebrew: Bool { get }
    func setLaunchAtLogin(_ enabled: Bool) throws
    /// 전역 단축키(어디서든 펼치기) 등록 상태. 없으면(스냅숏) 등록 실패 안내를 보여주지 않는다
    var globalShortcut: GlobalShortcutState? { get }
}

/// 전역 단축키 등록 상태 (App 이 `@Observable` 객체로 구현해 설정 화면이 바로 다시 그린다)
@MainActor
public protocol GlobalShortcutState: AnyObject {
    /// 켜 둔 키 조합을 다른 앱이 쓰고 있어 등록하지 못함
    var registrationFailed: Bool { get }
    /// 새 키 조합을 녹화하는 동안 지금 단축키를 잠깐 해제한다 (녹화 중 같은 키를 눌러도 아일랜드가 펼쳐지지 않게)
    var isPaused: Bool { get set }
}

/// 노치 UI 진입점. 화면별 패널 생성, 표시 모드 계산, 설정 창을 묶는다.
@MainActor
public final class NotchUIController {
    private let preferences: AppPreferences
    private let settings: SettingsProvider

    private let presentation: PresentationController
    private let screenManager: ScreenManager
    private var settingsWindow: SettingsWindowController?
    private var started = false

    /// 업데이트 상태 (App 이 주입. 없으면 버전 탭에 업데이트 기능을 숨긴다)
    public var updateProvider: UpdateProvider? {
        didSet {
            presentation.updateProvider = updateProvider
            settingsWindow?.setUpdateProvider(updateProvider)
        }
    }

    public init(store: SessionStore, preferences: AppPreferences, actions: IslandActions, settings: SettingsProvider) {
        self.preferences = preferences
        self.settings = settings

        let presentation = PresentationController(store: store, preferences: preferences, actions: actions)
        self.presentation = presentation
        self.screenManager = ScreenManager(presentation: presentation) { screenID in
            AnyView(IslandRootView(screenID: screenID, presentation: presentation, viewState: IslandViewState()))
        }
        presentation.onOpenSettings = { [weak self] section in self?.showSettings(section: section) }
    }

    /// 모든 화면에 패널을 만들고 스토어 관찰을 시작한다.
    public func start() {
        guard !started else { return }
        started = true
        presentation.start()
        screenManager.start()
    }

    public func stop() {
        guard started else { return }
        started = false
        screenManager.stop()
        presentation.stop()
        settingsWindow?.close()
    }

    /// 설정 창 열기 (이미 열려 있으면 앞으로)
    public func showSettings() {
        showSettings(section: nil)
    }

    func showSettings(section: SettingsSection?) {
        let controller = settingsWindow ?? makeSettingsWindow()
        settingsWindow = controller
        controller.show(section: section)
    }

    private func makeSettingsWindow() -> SettingsWindowController {
        let controller = SettingsWindowController(preferences: preferences, provider: settings)
        controller.setUpdateProvider(updateProvider)
        return controller
    }

    /// 마우스가 있는 화면에서 펼침/접기
    public func toggleExpanded() {
        guard started else { return }
        screenManager.toggleExpandedOnPreferredScreen()
    }
}
