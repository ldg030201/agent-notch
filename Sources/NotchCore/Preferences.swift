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

/// 노치 화면(맥북 내장)에서 접힌 아일랜드를 그리는 방식
public enum NotchStyle: String, CaseIterable, Codable, Sendable {
    /// 카메라(노치)를 가운데 두고 양옆 메뉴바 자리를 검은 날개로 사용.
    /// 날개는 메뉴바 아이콘을 덮고, 마우스를 가져가면 그쪽 날개가 노치 안으로 들어가 비켜준다.
    case wings
    /// 노치 바로 아래로 띠를 내려 표시 (메뉴바를 전혀 가리지 않음)
    case belowNotch
}

/// 노치 아래 방식(또는 다른 노치 앱이 노치를 쓸 때)에서 접힌 아일랜드를 노치 아래에 보여주는 모양
public enum CompactOverlapStyle: String, CaseIterable, Codable, Sendable {
    /// 노치 바로 아래로 띠를 내려 표시
    case belowNotch
    /// 노치 아래 가장자리에 상태 색 선만 표시
    case minimal
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
        static let externalDisplayStyle = "externalDisplayStyle"
        static let compactOverlapStyle = "compactOverlapStyle"
        static let checksForUpdates = "checksForUpdates"
        static let notchStyle = "notchStyle"
        static let restoresRecentSessions = "restoresRecentSessions"

        /// 설정 초기화가 지우는 키 (설정을 더하면 여기와 `resetToDefaults` 에도 넣는다)
        static let all = [
            displayPolicy, fullscreenBehavior, peekOnEdit, peekDuration, completionDisplayDuration, showStreamingText,
            permissionTimeout, staleSessionTimeout, passthroughWhenTerminalFrontmost, externalDisplayStyle,
            compactOverlapStyle, checksForUpdates, notchStyle, restoresRecentSessions,
        ]
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

    /// 권한 요청이 왔을 때 해당 세션의 터미널이 이미 앞에 있으면 노치에서 기다리지 않고 바로 터미널 프롬프트로 넘긴다.
    /// (훅이 대기하는 동안 터미널 다이얼로그가 보류될 수 있어서, 터미널을 보고 있는 사용자를 막지 않기 위함)
    public var passthroughWhenTerminalFrontmost: Bool {
        didSet { defaults.set(passthroughWhenTerminalFrontmost, forKey: Key.passthroughWhenTerminalFrontmost) }
    }

    public var externalDisplayStyle: ExternalDisplayStyle {
        didSet { defaults.set(externalDisplayStyle.rawValue, forKey: Key.externalDisplayStyle) }
    }

    /// 노치 화면 표시 방식 (날개 / 노치 아래)
    public var notchStyle: NotchStyle {
        didSet { defaults.set(notchStyle.rawValue, forKey: Key.notchStyle) }
    }

    public var compactOverlapStyle: CompactOverlapStyle {
        didSet { defaults.set(compactOverlapStyle.rawValue, forKey: Key.compactOverlapStyle) }
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
        externalDisplayStyle = defaults.string(forKey: Key.externalDisplayStyle).flatMap(ExternalDisplayStyle.init(rawValue:)) ?? .inMenuBar
        notchStyle = defaults.string(forKey: Key.notchStyle).flatMap(NotchStyle.init(rawValue:)) ?? .wings
        compactOverlapStyle = defaults.string(forKey: Key.compactOverlapStyle).flatMap(CompactOverlapStyle.init(rawValue:)) ?? .belowNotch
        checksForUpdates = defaults.object(forKey: Key.checksForUpdates) as? Bool ?? true
        restoresRecentSessions = defaults.object(forKey: Key.restoresRecentSessions) as? Bool ?? true
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
        externalDisplayStyle = fresh.externalDisplayStyle
        notchStyle = fresh.notchStyle
        compactOverlapStyle = fresh.compactOverlapStyle
        restoresRecentSessions = fresh.restoresRecentSessions
        checksForUpdates = fresh.checksForUpdates
        // 위 대입의 didSet 이 처음 값을 다시 적었으므로 한 번 더 지운다
        for key in Key.all { defaults.removeObject(forKey: key) }
    }
}
