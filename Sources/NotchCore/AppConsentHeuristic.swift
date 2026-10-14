import Foundation
import NotchShared

/// Claude 데스크톱 앱이 자체적으로 띄우는 확인 카드(예: "화면을 전체 제어할까요?")를 추정하는 규칙.
///
/// 이 카드는 Claude Code 권한 시스템 밖에서 떠서 PermissionRequest 훅이 오지 않는다.
/// 그래서 카드를 띄우곤 하는 툴이 PostToolUse 없이 `delay` 이상 실행 중이면 사용자 확인을 기다리는 것으로 본다.
/// 추정이므로 문구도 "필요할 수 있어요" 로 둔다 (`SessionStore.checkStalledTools()`).
public struct AppConsentHeuristic: Hashable, Sendable {
    /// 이 접두사로 시작하는 툴은 앱 확인 카드를 띄울 수 있다 (앱 · 화면 제어, 사이트 접근 승인 등)
    public var toolPrefixes: [String]
    /// 이름이 정확히 일치하면 확인 카드를 띄울 수 있는 툴 (폴더 접근 요청 등)
    public var toolNames: Set<String>
    /// 위 목록에 걸리지만 원래 오래 걸리는 툴. 지연만으로는 확인 대기와 구분할 수 없어 제외한다
    public var longRunningToolNames: Set<String>
    /// `tool_input.action` 이 이 값이면 원래 오래 걸리는 호출로 보고 제외한다 (예: 몇 초 기다리기)
    public var longRunningActions: Set<String>
    /// 이만큼 끝나지 않으면 확인 대기로 본다 (초)
    public var delay: TimeInterval

    public init(
        toolPrefixes: [String],
        toolNames: Set<String>,
        longRunningToolNames: Set<String>,
        longRunningActions: Set<String>,
        delay: TimeInterval
    ) {
        self.toolPrefixes = toolPrefixes
        self.toolNames = toolNames
        self.longRunningToolNames = longRunningToolNames
        self.longRunningActions = longRunningActions
        self.delay = delay
    }

    public static let `default` = AppConsentHeuristic(
        toolPrefixes: [
            "mcp__computer-use__",      // 앱 접근 · 화면 전체 제어 확인
            "mcp__Claude_Browser__",    // 앱 내 브라우저 사이트 접근 승인
            "mcp__claude-in-chrome__",  // Chrome 사이트 권한 · 브라우저 선택
        ],
        toolNames: [
            "mcp__ccd_directory__request_directory",
            "mcp__ccd_directory__change_directory",
        ],
        longRunningToolNames: [
            // 여러 동작을 이어서 실행 (스크린샷 · 클릭 · 대기 묶음)
            "mcp__computer-use__computer_batch",
            "mcp__computer-use__app_batch",
            "mcp__Claude_Browser__browser_batch",
            "mcp__claude-in-chrome__browser_batch",
            // 사용자가 가르치기 오버레이를 직접 넘기는 동안 실행 중 (이미 화면을 보고 있다)
            "mcp__computer-use__teach_step",
            "mcp__computer-use__teach_batch",
            // 개발 서버 시작 · 녹화 · 저장된 단축 작업 실행
            "mcp__Claude_Browser__preview_start",
            "mcp__claude-in-chrome__gif_creator",
            "mcp__claude-in-chrome__shortcuts_execute",
        ],
        longRunningActions: ["wait"],
        delay: 2.5
    )

    /// 이 툴 호출이 앱 확인 카드를 띄울 수 있어 지켜볼 대상인지
    public func watches(toolName: String, toolInput: JSONValue?) -> Bool {
        guard !longRunningToolNames.contains(toolName) else { return false }
        guard toolNames.contains(toolName) || toolPrefixes.contains(where: { toolName.hasPrefix($0) }) else {
            return false
        }
        if let action = toolInput?["action"]?.stringValue, longRunningActions.contains(action) {
            return false
        }
        return true
    }

    /// 확인 대기로 추정될 때 보여줄 문구
    static func message(toolTitle: String) -> String {
        "Claude 앱에서 확인이 필요할 수 있어요 · \(toolTitle)"
    }
}

extension TerminalContext {
    public static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    /// 알려진 `TERM_PROGRAM` → 번들 ID (소문자 키)
    public static let termProgramBundleIDs: [String: String] = [
        "iterm.app": "com.googlecode.iterm2",
        "apple_terminal": "com.apple.Terminal",
        "vscode": "com.microsoft.VSCode",
        "warpterminal": "dev.warp.Warp-Stable",
        "ghostty": "com.mitchellh.ghostty",
        "wezterm": "com.github.wez.wezterm",
        "zed": "dev.zed.Zed",
    ]

    /// 세션을 띄운 앱의 번들 ID (터미널 점프 · 앞에 있는 앱 감지 · 카드의 "터미널로/Claude로" 가 함께 쓴다).
    /// 번들 ID(`__CFBundleIdentifier`) → 알려진 터미널 프로그램(`TERM_PROGRAM`) → 진입점(`CLAUDE_CODE_ENTRYPOINT` 에 "desktop") 순서로 본다
    public var hostBundleIdentifier: String? {
        if let bundleID = bundleIdentifier?.trimmingCharacters(in: .whitespaces), !bundleID.isEmpty {
            return bundleID
        }
        if let program = termProgram?.lowercased(), let bundleID = Self.termProgramBundleIDs[program] {
            return bundleID
        }
        if entrypoint?.lowercased().contains("desktop") == true {
            return Self.claudeDesktopBundleID
        }
        return nil
    }

    /// Claude 데스크톱 앱 안에서 실행된 세션인지 (`hostBundleIdentifier` 와 같은 규칙)
    public var isClaudeDesktopApp: Bool {
        hostBundleIdentifier == Self.claudeDesktopBundleID
    }
}
