import AppKit
import NotchCore

/// 메뉴바 메뉴에서 App 에 요청하는 동작
@MainActor
protocol StatusMenuHost: AnyObject {
    var isDemoRunning: Bool { get }
    var hasDemoSessions: Bool { get }
    func toggleIsland()
    func toggleDemo()
    func clearDemoSessions()
    func installHooksFromMenu()
    func uninstallHooksFromMenu()
    func openSettings()
}

/// 메뉴바 아이콘과 메뉴. 메뉴는 열 때마다(`menuNeedsUpdate`) 현재 상태로 다시 만든다.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    /// 메뉴에 보여줄 최대 세션 수
    private static let maxSessionItems = 12
    private static let maxTitleCharacters = 52

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let store: SessionStore
    private let settings: AppSettingsProvider
    private let actions: AppActions
    private weak var host: StatusMenuHost?

    init(store: SessionStore, settings: AppSettingsProvider, actions: AppActions, host: StatusMenuHost) {
        self.store = store
        self.settings = settings
        self.actions = actions
        self.host = host
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "AgentNotch")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "AgentNotch"
        }
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()
        addSessionItems()
        menu.addItem(.separator())

        // 어디서든 펼치기 단축키를 켰고 글자 하나짜리 키면 메뉴에 키를 보여준다 (설정 → 단축키)
        let preferences = settings.preferences
        let combo = preferences.globalShortcutEnabled ? Self.menuKey(preferences.globalShortcut) : nil
        menu.addItem(ClosureMenuItem(
            title: "노치 펼치기/접기",
            keyEquivalent: combo?.key ?? "",
            modifiers: combo?.modifiers ?? []
        ) { [weak self] in self?.host?.toggleIsland() })

        let demoRunning = host?.isDemoRunning ?? false
        menu.addItem(ClosureMenuItem(title: demoRunning ? "데모 중지" : "데모 재생") { [weak self] in
            self?.host?.toggleDemo()
        })
        if !demoRunning, host?.hasDemoSessions == true {
            menu.addItem(ClosureMenuItem(title: "데모 세션 지우기") { [weak self] in
                self?.host?.clearDemoSessions()
            })
        }
        menu.addItem(.separator())

        addHookItems()
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "설정…", keyEquivalent: ",") { [weak self] in
            self?.host?.openSettings()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "AgentNotch 종료", keyEquivalent: "q") {
            NSApp.terminate(nil)
        })
    }

    /// 메뉴 항목 키 (글자 하나짜리 키만. "Space" · "F5" 같은 이름은 메뉴 키로 못 쓴다)
    static func menuKey(_ combo: KeyCombo) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard combo.key.count == 1 else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if combo.modifiers.contains(.control) { flags.insert(.control) }
        if combo.modifiers.contains(.option) { flags.insert(.option) }
        if combo.modifiers.contains(.shift) { flags.insert(.shift) }
        if combo.modifiers.contains(.command) { flags.insert(.command) }
        return (combo.key.lowercased(), flags)
    }

    private func addSessionItems() {
        let sessions = store.rankedSessions
        guard !sessions.isEmpty else {
            menu.addItem(Self.disabledItem("세션 없음"))
            return
        }
        menu.addItem(Self.disabledItem("Claude Code 세션"))
        for session in sessions.prefix(Self.maxSessionItems) {
            let id = session.id
            let pinned = store.pinnedSessionID == id
            let title = Self.truncate("\(session.projectName) — \(Self.statusText(for: session))")

            let item = ClosureMenuItem(title: title) { [weak self] in self?.actions.focus(sessionID: id) }
            item.state = store.focusedSessionID == id ? .on : .off
            if pinned {
                let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "고정됨")
                pin?.isTemplate = true
                item.image = pin
            }
            item.toolTip = session.cwd.isEmpty ? nil : session.cwd
            menu.addItem(item)

            // ⌥ 를 누르면 고정/고정 해제로 바뀐다
            let pinTitle = pinned ? "\(session.projectName) 고정 해제" : "\(session.projectName) 고정"
            let alternate = ClosureMenuItem(title: Self.truncate(pinTitle), modifiers: [.option]) { [weak self] in
                self?.actions.togglePin(sessionID: id)
            }
            alternate.isAlternate = true
            menu.addItem(alternate)
        }
        if sessions.count > Self.maxSessionItems {
            menu.addItem(Self.disabledItem("외 \(sessions.count - Self.maxSessionItems)개"))
        }
    }

    private func addHookItems() {
        let status = settings.hookStatus
        menu.addItem(Self.disabledItem("Claude Code 훅: \(AppSettingsProvider.hookStatusText(for: status))"))
        if status != .installed {
            let title = status == .notInstalled ? "Claude Code 훅 설치" : "Claude Code 훅 다시 설치"
            menu.addItem(ClosureMenuItem(title: title) { [weak self] in self?.host?.installHooksFromMenu() })
        }
        if status != .notInstalled {
            menu.addItem(ClosureMenuItem(title: "훅 제거") { [weak self] in self?.host?.uninstallHooksFromMenu() })
        }
    }

    // MARK: - 표시 문자열

    /// 단계 이름은 아일랜드 목록과 같다 (`SessionPhase.label`).
    /// 쉬는 중이어도 백그라운드 작업이 돌면 아일랜드와 같이 "백그라운드 N개 작업 중" (`AgentSession.backgroundStatusText`)
    static func statusText(for session: AgentSession) -> String {
        switch session.phase {
        case .idle, .completed: return session.backgroundStatusText ?? session.phase.label
        case .runningTool: return session.currentActivity?.title ?? session.phase.label
        case .thinking, .waitingPermission, .waitingInput, .compacting, .failed: return session.phase.label
        }
    }

    private static func truncate(_ text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        guard singleLine.count > maxTitleCharacters else { return singleLine }
        return String(singleLine.prefix(maxTitleCharacters - 1)) + "…"
    }

    private static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// 클로저로 동작하는 메뉴 항목 (메뉴 동작은 메인 스레드에서 불린다)
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(
        title: String,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        handler: @escaping @MainActor () -> Void
    ) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: keyEquivalent)
        target = self
        keyEquivalentModifierMask = modifiers
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) 는 지원하지 않음")
    }

    @objc private func invoke() {
        handler()
    }
}
