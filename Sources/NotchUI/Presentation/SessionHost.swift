import Foundation
import NotchCore

/// 세션을 띄운 앱 종류 (카드의 "터미널로" 버튼이 데려가는 곳 · 버튼 이름).
/// 점프 대상 결정(`TerminalJumper.resolveBundleIdentifier`)과 같은 순서로 본다:
/// 번들 ID → 터미널 프로그램(`TERM_PROGRAM`) → 진입점(`CLAUDE_CODE_ENTRYPOINT`)
enum SessionHost: Equatable {
    case terminal
    /// Claude 데스크톱 앱
    case claudeDesktop

    static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    init(_ context: TerminalContext?) {
        self = Self.isClaudeDesktop(context) ? .claudeDesktop : .terminal
    }

    static func isClaudeDesktop(_ context: TerminalContext?) -> Bool {
        guard let context else { return false }
        if let bundleID = context.bundleIdentifier?.trimmingCharacters(in: .whitespaces), !bundleID.isEmpty {
            return bundleID == claudeDesktopBundleID
        }
        // 터미널에서 돌면 진입점과 관계없이 터미널로 간다
        if let program = context.termProgram, !program.isEmpty { return false }
        return context.entrypoint?.lowercased().contains("desktop") ?? false
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
