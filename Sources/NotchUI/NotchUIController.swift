import AppKit
import SwiftUI
import NotchCore

/// 설정 화면이 App 에서 가져오는 정보와 동작 (훅 설치, 로그인 시 실행 등).
/// NotchUI 가 NotchServices 에 직접 의존하지 않도록 App 이 구현해 주입한다.
@MainActor
public protocol SettingsProvider: AnyObject {
    var appVersion: String { get }
    var hookStatusText: String { get }
    var hooksInstalled: Bool { get }
    func installHooks() throws
    func uninstallHooks() throws
    var launchAtLoginEnabled: Bool { get }
    var launchAtLoginManagedByHomebrew: Bool { get }
    func setLaunchAtLogin(_ enabled: Bool) throws
}

/// 노치 UI 진입점. 화면별 패널 생성, 표시 모드 계산, 설정 창을 묶는다.
@MainActor
public final class NotchUIController {
    private let store: SessionStore
    private let preferences: AppPreferences
    private let actions: IslandActions
    private let settings: SettingsProvider

    private let presentation: PresentationController
    private let screenManager: ScreenManager
    private var settingsWindow: SettingsWindowController?
    private var started = false

    public init(store: SessionStore, preferences: AppPreferences, actions: IslandActions, settings: SettingsProvider) {
        self.store = store
        self.preferences = preferences
        self.actions = actions
        self.settings = settings

        let presentation = PresentationController(store: store, preferences: preferences, actions: actions)
        self.presentation = presentation
        self.screenManager = ScreenManager(presentation: presentation) { screenID in
            AnyView(IslandRootView(screenID: screenID, presentation: presentation, viewState: IslandViewState()))
        }
        presentation.onOpenSettings = { [weak self] in self?.showSettings() }
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
        let controller = settingsWindow ?? SettingsWindowController(preferences: preferences, provider: settings)
        settingsWindow = controller
        controller.show()
    }

    /// 마우스가 있는 화면에서 펼침/접기
    public func toggleExpanded() {
        guard started else { return }
        screenManager.toggleExpandedOnPreferredScreen()
    }
}
