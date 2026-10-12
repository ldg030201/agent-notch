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
        static let soundsEnabled = "soundsEnabled"
        static let muteWhenTerminalFrontmost = "muteWhenTerminalFrontmost"
        static let permissionTimeout = "permissionTimeout"
        static let staleSessionTimeout = "staleSessionTimeout"
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

    public var soundsEnabled: Bool {
        didSet { defaults.set(soundsEnabled, forKey: Key.soundsEnabled) }
    }

    /// 해당 세션의 터미널이 이미 앞에 있으면 소리 생략
    public var muteWhenTerminalFrontmost: Bool {
        didSet { defaults.set(muteWhenTerminalFrontmost, forKey: Key.muteWhenTerminalFrontmost) }
    }

    /// 권한 요청을 노치에서 기다리는 최대 시간(초). 지나면 결정을 Claude Code 기본 프롬프트로 넘긴다.
    public var permissionTimeout: Double {
        didSet { defaults.set(permissionTimeout, forKey: Key.permissionTimeout) }
    }

    /// 이 시간(초) 동안 이벤트가 없는 세션은 목록에서 정리
    public var staleSessionTimeout: Double {
        didSet { defaults.set(staleSessionTimeout, forKey: Key.staleSessionTimeout) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayPolicy = defaults.string(forKey: Key.displayPolicy).flatMap(DisplayPolicy.init(rawValue:)) ?? .allScreens
        fullscreenBehavior = defaults.string(forKey: Key.fullscreenBehavior).flatMap(FullscreenBehavior.init(rawValue:)) ?? .alertsOnly
        peekOnEdit = defaults.object(forKey: Key.peekOnEdit) as? Bool ?? true
        peekDuration = defaults.object(forKey: Key.peekDuration) as? Double ?? 2.5
        completionDisplayDuration = defaults.object(forKey: Key.completionDisplayDuration) as? Double ?? 4
        showStreamingText = defaults.object(forKey: Key.showStreamingText) as? Bool ?? true
        soundsEnabled = defaults.object(forKey: Key.soundsEnabled) as? Bool ?? true
        muteWhenTerminalFrontmost = defaults.object(forKey: Key.muteWhenTerminalFrontmost) as? Bool ?? true
        permissionTimeout = defaults.object(forKey: Key.permissionTimeout) as? Double ?? 120
        staleSessionTimeout = defaults.object(forKey: Key.staleSessionTimeout) as? Double ?? 2 * 60 * 60
    }
}
