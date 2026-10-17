import Foundation
import Observation

/// 노치를 어느 화면에 띄울지
public enum DisplayPolicy: String, CaseIterable, Codable, Sendable {
    /// 모든 화면 (접힌 상태는 전부, 펼침/알림은 마우스가 있는 화면)
    case allScreens
    /// 마우스가 있는 화면만
    case activeScreen
    /// 내장(노치) 화면만
    case builtInOnly
}

/// 풀스크린 앱 위에서의 동작
public enum FullscreenBehavior: String, CaseIterable, Codable, Sendable {
    /// 평소처럼 표시
    case showAll
    /// 권한 요청 등 주의가 필요한 알림만 표시
    case alertsOnly
    /// 숨김
    case hide
}

/// 노치 없는 화면(외부 모니터)에서 접힌 아일랜드를 어디에 둘지
public enum ExternalDisplayStyle: String, CaseIterable, Codable, Sendable {
    /// 메뉴바 안의 빈 구간 (아래 내용을 가리지 않음)
    case inMenuBar
    /// 메뉴바 바로 아래
    case belowMenuBar
    /// 표시하지 않음 (알림 카드만)
    case hidden
}

/// 키 조합: 가상 키 코드(Carbon `kVK_*`) + 수식키 + 표시 글자 (전역 단축키 녹화 · 등록 · 표시가 함께 쓴다)
public struct KeyCombo: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var keyCode: Int
    public var modifiers: Modifiers
    /// 키 이름 ("N", "Space", "F5", "←")
    public var key: String

    public init(keyCode: Int, modifiers: Modifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// ⌃⌥⌘N (`kVK_ANSI_N` = 45)
    public static let defaultToggle = KeyCombo(keyCode: 45, modifiers: [.control, .option, .command], key: "N")

    /// 메뉴와 같은 순서로 쓴 이름 (⌃ ⌥ ⇧ ⌘ + 키). 예: "⌃⌥⌘N"
    public var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }
}

/// 사용자 설정 (UserDefaults 에 저장, 비밀 정보 없음)
@MainActor
@Observable
public final class AppPreferences {
    private enum Key {
        static let displayPolicy = "displayPolicy"
        static let fullscreenBehavior = "fullscreenBehavior"
        static let peekOnEdit = "peekOnEdit"
        static let peekDuration = "peekDuration"
        static let completionDisplayDuration = "completionDisplayDuration"
        static let showStreamingText = "showStreamingText"
        static let permissionTimeout = "permissionTimeout"
        static let staleSessionTimeout = "staleSessionTimeout"
        static let passthroughWhenTerminalFrontmost = "passthroughWhenTerminalFrontmost"
        /// 권한 요청만 받던 때의 이름 그대로 (저장된 설정을 이어 쓴다)
        static let claudeAppRequestsInNotch = "claudeAppPermissionsInNotch"
        static let externalDisplayStyle = "externalDisplayStyle"
        static let checksForUpdates = "checksForUpdates"
        static let restoresRecentSessions = "restoresRecentSessions"
        static let rotatesSessions = "rotatesSessions"
        static let sessionRotationInterval = "sessionRotationInterval"
        static let globalShortcutEnabled = "globalShortcutEnabled"
        static let globalShortcut = "globalShortcut"
        static let permissionShortcutsEnabled = "permissionShortcutsEnabled"
        static let interactionShortcutsEnabled = "interactionShortcutsEnabled"
        static let collapseShortcutEnabled = "collapseShortcutEnabled"

        /// 설정 초기화가 지우는 키 (설정을 더하면 여기와 `resetToDefaults` 에도 넣는다)
        static let all = [
            displayPolicy, fullscreenBehavior, peekOnEdit, peekDuration, completionDisplayDuration, showStreamingText,
            permissionTimeout, staleSessionTimeout, passthroughWhenTerminalFrontmost, claudeAppRequestsInNotch, externalDisplayStyle,
            checksForUpdates, restoresRecentSessions, rotatesSessions, sessionRotationInterval,
            globalShortcutEnabled, globalShortcut, permissionShortcutsEnabled, interactionShortcutsEnabled, collapseShortcutEnabled,
        ]
        /// 없앤 설정 (노치 화면 표시 방식 · 노치 아래 표시 모양). 노치 화면은 늘 노치 아래 띠라 저장된 값을 지운다
        static let removed = ["notchStyle", "compactOverlapStyle"]
    }

    @ObservationIgnored private let defaults: UserDefaults

    public var displayPolicy: DisplayPolicy {
        didSet { defaults.set(displayPolicy.rawValue, forKey: Key.displayPolicy) }
    }

    public var fullscreenBehavior: FullscreenBehavior {
        didSet { defaults.set(fullscreenBehavior.rawValue, forKey: Key.fullscreenBehavior) }
    }

    /// 파일 수정 시 미니 diff 를 잠깐 펼쳐 보여줄지
    public var peekOnEdit: Bool {
        didSet { defaults.set(peekOnEdit, forKey: Key.peekOnEdit) }
    }

    /// 피크 유지 시간(초)
    public var peekDuration: Double {
        didSet { defaults.set(peekDuration, forKey: Key.peekDuration) }
    }

    /// 완료 요약 유지 시간(초)
    public var completionDisplayDuration: Double {
        didSet { defaults.set(completionDisplayDuration, forKey: Key.completionDisplayDuration) }
    }

    /// 여러 세션이 활동 중이면 접힌 아일랜드가 보여주는 세션을 주기적으로 넘길지 (고정한 세션이 있으면 넘기지 않는다)
    public var rotatesSessions: Bool {
        didSet { defaults.set(rotatesSessions, forKey: Key.rotatesSessions) }
    }

    /// 세션을 넘기는 간격(초)
    public var sessionRotationInterval: Double {
        didSet { defaults.set(sessionRotationInterval, forKey: Key.sessionRotationInterval) }
    }

    // MARK: 단축키 (모두 처음엔 꺼짐)

    /// 어디서든 아일랜드를 펼치고 접는 전역 단축키를 쓸지
    public var globalShortcutEnabled: Bool {
        didSet { defaults.set(globalShortcutEnabled, forKey: Key.globalShortcutEnabled) }
    }

    /// 어디서든 펼치기 · 접기 키 조합
    public var globalShortcut: KeyCombo {
        didSet { defaults.set(try? JSONEncoder().encode(globalShortcut), forKey: Key.globalShortcut) }
    }

    /// 권한 카드 단축키: ⌘↩ 허용 · ⌥⌘↩ 항상 허용 · ⌘⌫ 거부 (아일랜드를 눌러 키 윈도우일 때만)
    public var permissionShortcutsEnabled: Bool {
        didSet { defaults.set(permissionShortcutsEnabled, forKey: Key.permissionShortcutsEnabled) }
    }

    /// 질문 · 계획 승인 카드 단축키: 1–4 선택지 · ↩ 다음 · 보내기 · 승인 ("기타" 입력란의 ↩ 보내기 포함)
    public var interactionShortcutsEnabled: Bool {
        didSet { defaults.set(interactionShortcutsEnabled, forKey: Key.interactionShortcutsEnabled) }
    }

    /// ⎋ 로 카드 접기
    public var collapseShortcutEnabled: Bool {
        didSet { defaults.set(collapseShortcutEnabled, forKey: Key.collapseShortcutEnabled) }
    }

    /// 응답 스트리밍 텍스트 표시 여부
    public var showStreamingText: Bool {
        didSet { defaults.set(showStreamingText, forKey: Key.showStreamingText) }
    }

    /// 권한 요청을 노치에서 기다리는 최대 시간(초). 지나면 결정을 Claude Code 기본 프롬프트로 넘긴다.
    public var permissionTimeout: Double {
        didSet { defaults.set(permissionTimeout, forKey: Key.permissionTimeout) }
    }

    /// 이 시간(초) 동안 이벤트가 없는 세션은 목록에서 정리
    public var staleSessionTimeout: Double {
        didSet { defaults.set(staleSessionTimeout, forKey: Key.staleSessionTimeout) }
    }

    /// 권한 요청 · 질문 · 계획 승인이 왔을 때 그 세션의 앱(터미널 · Claude 앱)이 이미 앞에 있으면 노치에서 기다리지 않고
    /// 바로 그 앱의 프롬프트로 넘긴다 (훅이 대기하는 동안 터미널 다이얼로그가 보류될 수 있어서, 터미널을 보고 있는 사용자를 막지 않기 위함).
    /// Claude 앱 세션은 `claudeAppRequestsInNotch` 가 켜져 있으면 넘기지 않는다 (`passesThroughToFrontmostHost`)
    public var passthroughWhenTerminalFrontmost: Bool {
        didSet { defaults.set(passthroughWhenTerminalFrontmost, forKey: Key.passthroughWhenTerminalFrontmost) }
    }

    /// Claude 앱 세션의 권한 요청 · 질문 · 계획 승인은 Claude 앱이 앞에 있어도 넘기지 않고 노치에서 받는다.
    /// - 권한 요청: Claude 앱은 훅이 기다리는 동안에도 자기 승인 창을 함께 띄우고 먼저 결정한 쪽을 따른다
    /// - 질문 · 계획 승인: 노치가 기다리는 동안엔 툴이 아직 실행 전이라 앱에 질문이 뜨지 않는다.
    ///   앱에서 답하려면 노치의 "Claude로"(결정 없이 넘기고 앱 안의 그 세션을 연다)
    public var claudeAppRequestsInNotch: Bool {
        didSet { defaults.set(claudeAppRequestsInNotch, forKey: Key.claudeAppRequestsInNotch) }
    }

    /// 세션 앱이 앞에 있을 때 노치에서 기다리지 않고 그 앱으로 바로 넘길지
    /// - isClaudeApp: Claude 데스크톱 앱 세션 (`TerminalContext.isClaudeDesktopApp`)
    public func passesThroughToFrontmostHost(isClaudeApp: Bool) -> Bool {
        guard passthroughWhenTerminalFrontmost else { return false }
        return !(isClaudeApp && claudeAppRequestsInNotch)
    }

    public var externalDisplayStyle: ExternalDisplayStyle {
        didSet { defaults.set(externalDisplayStyle.rawValue, forKey: Key.externalDisplayStyle) }
    }

    /// 앱을 켤 때 최근 Claude Code 대화 기록 끝부분을 읽어 이미 돌고 있던 세션을 바로 보여줄지 (읽기만 하고 아무것도 쓰지 않음)
    public var restoresRecentSessions: Bool {
        didSet { defaults.set(restoresRecentSessions, forKey: Key.restoresRecentSessions) }
    }

    /// 하루 한 번 GitHub 의 변경 내역으로 새 버전 확인 (앱의 유일한 네트워크 통신)
    public var checksForUpdates: Bool {
        didSet { defaults.set(checksForUpdates, forKey: Key.checksForUpdates) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayPolicy = defaults.string(forKey: Key.displayPolicy).flatMap(DisplayPolicy.init(rawValue:)) ?? .allScreens
        fullscreenBehavior = defaults.string(forKey: Key.fullscreenBehavior).flatMap(FullscreenBehavior.init(rawValue:)) ?? .alertsOnly
        peekOnEdit = defaults.object(forKey: Key.peekOnEdit) as? Bool ?? true
        peekDuration = defaults.object(forKey: Key.peekDuration) as? Double ?? 2.5
        completionDisplayDuration = defaults.object(forKey: Key.completionDisplayDuration) as? Double ?? 4
        showStreamingText = defaults.object(forKey: Key.showStreamingText) as? Bool ?? true
        permissionTimeout = defaults.object(forKey: Key.permissionTimeout) as? Double ?? 120
        staleSessionTimeout = defaults.object(forKey: Key.staleSessionTimeout) as? Double ?? 2 * 60 * 60
        passthroughWhenTerminalFrontmost = defaults.object(forKey: Key.passthroughWhenTerminalFrontmost) as? Bool ?? true
        claudeAppRequestsInNotch = defaults.object(forKey: Key.claudeAppRequestsInNotch) as? Bool ?? true
        externalDisplayStyle = defaults.string(forKey: Key.externalDisplayStyle).flatMap(ExternalDisplayStyle.init(rawValue:)) ?? .inMenuBar
        checksForUpdates = defaults.object(forKey: Key.checksForUpdates) as? Bool ?? true
        restoresRecentSessions = defaults.object(forKey: Key.restoresRecentSessions) as? Bool ?? true
        rotatesSessions = defaults.object(forKey: Key.rotatesSessions) as? Bool ?? true
        sessionRotationInterval = defaults.object(forKey: Key.sessionRotationInterval) as? Double ?? 5
        globalShortcutEnabled = defaults.object(forKey: Key.globalShortcutEnabled) as? Bool ?? false
        globalShortcut = defaults.data(forKey: Key.globalShortcut).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
            ?? .defaultToggle
        permissionShortcutsEnabled = defaults.object(forKey: Key.permissionShortcutsEnabled) as? Bool ?? false
        interactionShortcutsEnabled = defaults.object(forKey: Key.interactionShortcutsEnabled) as? Bool ?? false
        collapseShortcutEnabled = defaults.object(forKey: Key.collapseShortcutEnabled) as? Bool ?? false
        for key in Key.removed { defaults.removeObject(forKey: key) }
    }

    /// 모든 설정을 처음 값으로 되돌린다. 훅 설치 · 로그인 시 실행은 이 설정 밖(settings.json · 시스템)이라 그대로 둔다.
    /// 저장된 값은 지워 둔다: 나중 버전에서 처음 값이 바뀌면 그 값을 따른다
    public func resetToDefaults() {
        for key in Key.all { defaults.removeObject(forKey: key) }
        // 키를 지운 뒤 읽으면 처음 값이다
        let fresh = AppPreferences(defaults: defaults)
        displayPolicy = fresh.displayPolicy
        fullscreenBehavior = fresh.fullscreenBehavior
        peekOnEdit = fresh.peekOnEdit
        peekDuration = fresh.peekDuration
        completionDisplayDuration = fresh.completionDisplayDuration
        showStreamingText = fresh.showStreamingText
        permissionTimeout = fresh.permissionTimeout
        staleSessionTimeout = fresh.staleSessionTimeout
        passthroughWhenTerminalFrontmost = fresh.passthroughWhenTerminalFrontmost
        claudeAppRequestsInNotch = fresh.claudeAppRequestsInNotch
        externalDisplayStyle = fresh.externalDisplayStyle
        restoresRecentSessions = fresh.restoresRecentSessions
        rotatesSessions = fresh.rotatesSessions
        sessionRotationInterval = fresh.sessionRotationInterval
        globalShortcutEnabled = fresh.globalShortcutEnabled
        globalShortcut = fresh.globalShortcut
        permissionShortcutsEnabled = fresh.permissionShortcutsEnabled
        interactionShortcutsEnabled = fresh.interactionShortcutsEnabled
        collapseShortcutEnabled = fresh.collapseShortcutEnabled
        checksForUpdates = fresh.checksForUpdates
        // 위 대입의 didSet 이 처음 값을 다시 적었으므로 한 번 더 지운다
        for key in Key.all { defaults.removeObject(forKey: key) }
    }
}
