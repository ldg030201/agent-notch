import AppKit
import NotchCore
import NotchServices
import NotchShared
import NotchUI
import os

/// 모듈 조립: 소켓 서버 → 세션 스토어 → 노치 UI, 메뉴바, 데모
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, StatusMenuHost {
    /// 오래된 세션 정리 주기
    private static let pruneInterval: TimeInterval = 5 * 60
    private static let log = Logger(subsystem: NotchServices.logSubsystem, category: "app")

    private let options: LaunchOptions
    private let preferences: AppPreferences
    private let store: SessionStore
    private let socketServer: SocketServer
    private let frontmost: FrontmostAppMonitor
    private let hookInstaller: HookInstaller
    private let settings: AppSettingsProvider
    private let actions: AppActions
    private let uiController: NotchUIController
    private let updates: AppUpdateProvider
    private let demo: DemoScenario

    private var statusMenu: StatusMenuController?
    private var hotKey: GlobalHotKey?
    private var pruneTimer: Timer?
    /// SIGTERM(launchd, 업데이트 교체 스크립트) · SIGINT 에도 정상 종료 경로를 타게 한다 (소켓 파일 정리)
    private var signalSources: [DispatchSourceSignal] = []

    init(options: LaunchOptions) {
        self.options = options
        preferences = AppPreferences()
        store = SessionStore()
        socketServer = SocketServer()
        frontmost = FrontmostAppMonitor()
        hookInstaller = HookInstaller()
        settings = AppSettingsProvider(
            installer: hookInstaller,
            loginItem: MainAppLoginItem(),
            preferences: preferences
        )
        actions = AppActions(store: store, terminalJumper: TerminalJumper(), fileOpener: FileOpener())
        uiController = NotchUIController(store: store, preferences: preferences, actions: actions, settings: settings)
        updates = AppUpdateProvider(preferences: preferences)
        demo = DemoScenario(store: store)
        super.init()
        actions.uiController = uiController
        // 버전 탭 · 아일랜드 헤더가 처음 그려질 때부터 업데이트 상태가 있어야 한다
        uiController.updateProvider = updates
    }

    // MARK: - 생명주기

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        installTerminationSignalHandlers()
        wireSocketServer()
        guard startSocketServer() else { return }

        uiController.start()
        // 하루 한 번 새 버전 확인 (설정에서 끄면 멈춤, 테스트판은 확인하지 않음)
        updates.start()
        statusMenu = StatusMenuController(store: store, settings: settings, actions: actions, host: self)
        hotKey = GlobalHotKey(keyCode: GlobalHotKey.toggleKeyCode, modifiers: GlobalHotKey.toggleModifiers) { [weak self] in
            self?.toggleIsland()
        }
        if hotKey == nil { Self.log.info("전역 단축키 등록 실패 (다른 앱이 사용 중)") }

        pruneTimer = Timer.scheduledTimer(withTimeInterval: Self.pruneInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneStaleSessions() }
        }
        settings.refreshHelperIfNeeded()

        if options.demo {
            demo.start()
        } else {
            // 아일랜드가 먼저 자리잡은 뒤에 묻는다
            DispatchQueue.main.async { [weak self] in self?.offerHookInstallIfNeeded() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updates.stop()
        demo.stop()
        pruneTimer?.invalidate()
        hotKey?.invalidate()
        uiController.stop()
        // 대기 중인 훅은 연결이 끊기면 결정 없이 종료된다 (Claude Code 기본 프롬프트로 넘어감)
        socketServer.stop()
    }

    private func installTerminationSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// 이미 실행 중일 때 Finder/`open` 으로 다시 열면 설정 창을 보여준다
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        uiController.showSettings()
        return false
    }

    // MARK: - 소켓 서버

    private func wireSocketServer() {
        socketServer.onEnvelope = { [weak self] envelope in
            self?.receive(envelope)
        }
        socketServer.onPendingCancelled = { [weak self] id in
            self?.store.cancelPermission(id: id)
        }
        socketServer.replyTimeout = { [weak self] in
            self?.preferences.permissionTimeout ?? 120
        }
        store.onPermissionResolved = { [weak self] info, decision in
            self?.socketServer.reply(to: info.id, output: PermissionReplyBuilder.output(for: info, decision: decision))
        }
    }

    /// 훅 이벤트 반영. 터미널을 보고 있으면 권한 요청은 노치에 보여만 주고 바로 터미널 프롬프트로 넘긴다.
    private func receive(_ envelope: HookEnvelope) -> UUID? {
        guard let requestID = store.ingest(envelope) else { return nil }
        if preferences.passthroughWhenTerminalFrontmost,
           frontmost.isFrontmost(TerminalContext(environment: envelope.env)) {
            store.resolvePermission(id: requestID, decision: .passthrough)
        }
        return requestID
    }

    /// 시작에 실패해 앱을 끝내야 하면 false
    private func startSocketServer() -> Bool {
        do {
            try socketServer.start()
            return true
        } catch SocketServerError.alreadyRunning {
            showAlert(title: "AgentNotch 가 이미 실행 중이에요", message: "메뉴바의 AgentNotch 아이콘을 확인해 주세요.")
            NSApp.terminate(nil)
            return false
        } catch {
            Self.log.error("소켓 서버 시작 실패: \(error.localizedDescription, privacy: .public)")
            showAlert(
                title: "Claude Code 이벤트를 받을 수 없어요",
                message: "\(error.localizedDescription)\n\n노치 UI 와 데모는 그대로 쓸 수 있어요."
            )
            return true
        }
    }

    // MARK: - 정리

    private func pruneStaleSessions() {
        store.pruneStaleSessions(olderThan: preferences.staleSessionTimeout)
    }

    // MARK: - 훅 설치

    /// 첫 실행 때 한 번만 훅 설치를 제안한다
    private func offerHookInstallIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: AppInfo.didOfferHookInstallKey) else { return }
        defaults.set(true, forKey: AppInfo.didOfferHookInstallKey)
        guard settings.hookStatus == .notInstalled else { return }

        let alert = NSAlert()
        alert.messageText = "Claude Code 훅을 설치할까요?"
        alert.informativeText = """
        세션 상태를 노치에 보여주려면 ~/.claude/settings.json 에 AgentNotch 훅을 추가해야 해요.
        기존 파일은 백업하고 다른 훅은 그대로 둬요. 나중에 메뉴바 아이콘에서도 설치할 수 있어요.
        """
        alert.addButton(withTitle: "훅 설치")
        alert.addButton(withTitle: "나중에")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            installHooksFromMenu()
        }
    }

    func installHooksFromMenu() {
        do {
            try settings.installHooks()
            showAlert(
                title: "Claude Code 훅을 설치했어요",
                message: "새로 시작하는 Claude Code 세션부터 노치에 표시돼요. 이미 열려 있는 세션은 다시 시작해야 할 수 있어요."
            )
        } catch {
            showAlert(title: "훅을 설치하지 못했어요", message: error.localizedDescription)
        }
    }

    func uninstallHooksFromMenu() {
        do {
            try settings.uninstallHooks()
            showAlert(title: "Claude Code 훅을 제거했어요", message: "AgentNotch 항목만 지웠고 다른 훅은 그대로예요.")
        } catch {
            showAlert(title: "훅을 제거하지 못했어요", message: error.localizedDescription)
        }
    }

    // MARK: - StatusMenuHost

    var isDemoRunning: Bool { demo.isRunning }

    var hasDemoSessions: Bool { demo.hasSessions }

    func toggleIsland() {
        uiController.toggleExpanded()
    }

    func toggleDemo() {
        if demo.isRunning {
            demo.stop()
        } else {
            demo.start()
        }
    }

    func clearDemoSessions() {
        demo.stop()
        demo.clearSessions()
    }

    @objc func openSettings() {
        uiController.showSettings()
    }

    // MARK: - 메인 메뉴

    /// 메뉴바에는 보이지 않지만 설정 창의 단축키(복사, 닫기 등)를 위해 둔다
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: "AgentNotch")
        appMenu.addItem(withTitle: "설정…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "AgentNotch 종료", action: #selector(quitFromMainMenu(_:)), keyEquivalent: "q").target = self
        mainMenu.addItem(Self.submenuItem(appMenu))

        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(Self.submenuItem(editMenu))

        let windowMenu = NSMenu(title: "윈도우")
        windowMenu.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        mainMenu.addItem(Self.submenuItem(windowMenu))

        NSApp.mainMenu = mainMenu
    }

    /// 아일랜드 패널은 앱을 활성화하지 않고 키 윈도우가 되므로, 그때 누른 ⌘Q 로 앱이 꺼지지 않게 한다.
    @objc private func quitFromMainMenu(_ sender: Any?) {
        guard NSApp.isActive else { return }
        NSApp.terminate(sender)
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // MARK: - 알림 창

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "확인")
        NSApp.activate()
        alert.runModal()
    }
}
