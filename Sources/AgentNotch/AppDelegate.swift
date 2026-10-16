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
    /// Claude 앱 확인 카드 추정 주기 (훅이 오지 않아 직접 살핀다)
    private static let stallCheckInterval: TimeInterval = 1
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
    private var globalShortcut: GlobalShortcutController?
    private var pruneTimer: Timer?
    private var stallTimer: Timer?
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
        // 버전 탭 · 아일랜드 헤더가 처음 그려질 때부터 업데이트 상태가 있어야 한다
        uiController.updateProvider = updates
    }

    // MARK: - 생명주기

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        installTerminationSignalHandlers()
        wireSocketServer()
        guard startSocketServer() else { return }
        restoreRecentSessions()

        uiController.start()
        // 하루 한 번 새 버전 확인 (설정에서 끄면 멈춤, 테스트판은 확인하지 않음)
        updates.start()
        statusMenu = StatusMenuController(store: store, settings: settings, actions: actions, host: self)
        // 어디서든 펼치기 · 접기 (설정 → 단축키, 처음엔 꺼짐)
        let shortcut = GlobalShortcutController(preferences: preferences) { [weak self] in self?.toggleIsland() }
        settings.globalShortcut = shortcut
        shortcut.start()
        globalShortcut = shortcut

        pruneTimer = Timer.scheduledTimer(withTimeInterval: Self.pruneInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneStaleSessions() }
        }
        startStallTimer()
        settings.refreshHelperIfNeeded()

        if options.demo {
            demo.start()
        } else {
            // 아일랜드가 먼저 자리잡은 뒤에 묻는다 (모달이라 GCD 메인 큐가 아닌 런루프에서 띄운다: `presentModal`)
            Self.presentModal { [weak self] in self?.offerFirstLaunchSetupIfNeeded() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updates.stop()
        demo.stop()
        pruneTimer?.invalidate()
        stallTimer?.invalidate()
        globalShortcut?.stop()
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
        socketServer.onPendingCancelled = { [weak self] id, reason in
            switch reason {
            case .timedOut:
                // 노치에서 기다리는 시간이 지남: 질문 · 계획 승인은 이어서 뜨는 다이얼로그로 안내한다
                self?.store.expirePermission(id: id)
            case .clientClosed, .serverStopped:
                self?.store.cancelPermission(id: id)
            }
        }
        socketServer.replyTimeout = { [weak self] in
            self?.preferences.permissionTimeout ?? 120
        }
        store.onPermissionResolved = { [weak self] info, decision in
            self?.socketServer.reply(to: info.id, output: PermissionReplyBuilder.output(for: info, decision: decision))
        }
    }

    /// 훅 이벤트 반영. 세션 앱(터미널 · Claude 앱)을 보고 있으면 권한 요청 · 질문 · 계획 승인은 노치에 보여만 주고
    /// 바로 그 앱의 프롬프트로 넘긴다. Claude 앱의 권한 요청은 (설정이 켜져 있으면) 넘기지 않고 노치에서 받는다
    /// (`AppPreferences.passesThroughToFrontmostHost`)
    private func receive(_ envelope: HookEnvelope) -> UUID? {
        guard let requestID = store.ingest(envelope) else { return nil }
        let host = TerminalContext(environment: envelope.env)
        let isInteraction = store.pendingPermissions.first { $0.id == requestID }?.isInteraction ?? false
        if frontmost.isFrontmost(host),
           preferences.passesThroughToFrontmostHost(isClaudeApp: host.isClaudeDesktopApp, isInteraction: isInteraction) {
            store.resolvePermission(id: requestID, decision: .passthrough)
        }
        return requestID
    }

    /// 앱이 꺼져 있던 사이 이미 돌고 있던 세션을 대화 기록 끝부분으로 되살린다 (설정에서 끌 수 있음, 데모에서는 안 함).
    /// 파일 읽기는 백그라운드에서 하고, 그사이 이벤트로 먼저 알게 된 세션은 `SessionStore.restore` 가 건드리지 않는다
    private func restoreRecentSessions() {
        guard preferences.restoresRecentSessions, !options.demo else { return }
        let restorer = SessionRestorer()
        let store = store
        Task.detached(priority: .utility) {
            let restored = restorer.scan()
            guard !restored.isEmpty else { return }
            await store.restore(restored)
        }
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

    /// Claude 데스크톱 앱이 띄우는 확인 카드(화면 제어 · 사이트 접근 등)는 훅이 오지 않아 1초마다 멈춘 툴을 살핀다.
    /// 메뉴가 열려 있어도 돌도록 common 모드에 건다.
    private func startStallTimer() {
        let timer = Timer(timeInterval: Self.stallCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.checkStalledTools() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        stallTimer = timer
    }

    // MARK: - 훅 설치

    /// 첫 실행 때 한 번만 훅 설치 · 로그인 시 실행을 한 창에서 묻는다 (둘 다 처음부터 켜 둔 체크박스).
    /// 이미 된 것은 빼고, 할 게 없으면 묻지 않는다
    private func offerFirstLaunchSetupIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: AppInfo.didOfferHookInstallKey) else { return }
        defaults.set(true, forKey: AppInfo.didOfferHookInstallKey)

        let offersHooks = settings.hookStatus == .notInstalled
        let offersLogin = settings.launchAtLoginAvailable && !settings.launchAtLoginEnabled
            && !settings.launchAtLoginManagedByHomebrew
        guard offersHooks || offersLogin else { return }

        let hooksBox = NSButton(checkboxWithTitle: "Claude Code 훅 설치", target: nil, action: nil)
        let loginBox = NSButton(checkboxWithTitle: "로그인할 때 자동으로 켜기", target: nil, action: nil)
        hooksBox.state = .on
        loginBox.state = .on
        let stack = NSStackView(views: (offersHooks ? [hooksBox] : []) + (offersLogin ? [loginBox] : []))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setFrameSize(stack.fittingSize)

        var lines: [String] = []
        if offersHooks {
            lines.append("세션을 노치에 보여주려면 Claude Code 훅이 필요해요. ~/.claude/settings.json 을 백업한 뒤 AgentNotch 항목만 더하고 다른 훅은 그대로 둬요.")
        }
        lines.append("나중에 메뉴바 아이콘이나 설정에서도 바꿀 수 있어요.")

        let alert = NSAlert()
        alert.messageText = "AgentNotch 시작하기"
        alert.informativeText = lines.joined(separator: "\n")
        alert.accessoryView = stack
        alert.addButton(withTitle: "시작하기")
        alert.addButton(withTitle: "나중에")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var failures: [String] = []
        if offersHooks, hooksBox.state == .on {
            do { try settings.installHooks() } catch { failures.append("훅 설치: \(error.localizedDescription)") }
        }
        if offersLogin, loginBox.state == .on {
            do { try settings.setLaunchAtLogin(true) } catch { failures.append("로그인 시 실행: \(error.localizedDescription)") }
        }
        if !failures.isEmpty {
            showAlert(title: "일부 설정을 마치지 못했어요", message: failures.joined(separator: "\n"))
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

    /// 모달 창(`runModal`)을 띄울 코드를 런루프 블록으로 미뤄 실행한다.
    ///
    /// `DispatchQueue.main.async` · `Task { @MainActor in }` 안에서 `runModal()` 을 부르면, 모달 런루프가 도는 동안
    /// GCD 메인 큐가 비워지지 않는다(이미 그 큐의 블록 안이라). 그러면 소켓 서버의 `DispatchQueue.main.async` 전달 ·
    /// `@MainActor` Task · 종료 신호(SIGTERM) 처리가 창이 닫힐 때까지 멈추고, 권한 훅은 응답 없이 시간 제한까지 기다린다.
    /// 런루프 블록(`RunLoop.perform`)이나 메뉴 동작 · `applicationDidFinishLaunching` 에서 띄운 모달은 메인 큐를 계속 비운다.
    static func presentModal(_ body: @escaping @MainActor () -> Void) {
        RunLoop.main.perform {
            MainActor.assumeIsolated { body() }
        }
    }

    /// 모달 경고창. GCD 메인 큐 블록 · `@MainActor` Task 에서 바로 부르지 말 것 (`presentModal` 참고)
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "확인")
        NSApp.activate()
        alert.runModal()
    }
}
