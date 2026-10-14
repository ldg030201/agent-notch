import Foundation
import NotchCore

/// 세션을 띄운 앱 종류 (카드의 "터미널로" 버튼이 데려가는 곳 · 버튼 이름).
/// 점프 대상과 같은 규칙으로 정한다 (`TerminalContext.hostBundleIdentifier` · `isClaudeDesktopApp`)
enum SessionHost: Equatable {
    case terminal
    /// Claude 데스크톱 앱
    case claudeDesktop

    init(_ context: TerminalContext?) {
        self = context?.isClaudeDesktopApp == true ? .claudeDesktop : .terminal
    }

    /// 버튼 이름 ("터미널로" · "Claude로")
    var jumpLabel: String {
        switch self {
        case .terminal: return "터미널로"
        case .claudeDesktop: return "Claude로"
        }
    }

    /// 버튼 아이콘 (SF Symbols)
    var symbolName: String {
        switch self {
        case .terminal: return "terminal"
        case .claudeDesktop: return "macwindow"
        }
    }

    /// 문장 안에서 부르는 이름 ("터미널에서 직접 결정")
    var placeName: String {
        switch self {
        case .terminal: return "터미널"
        case .claudeDesktop: return "Claude 앱"
        }
    }
}
