import Foundation
import NotchShared

/// Claude 데스크톱 앱이 자체적으로 띄우는 확인 카드(예: "화면을 전체 제어할까요?")를 추정하는 규칙.
///
/// 이 카드는 Claude Code 권한 시스템 밖에서 떠서 PermissionRequest 훅이 오지 않는다.
/// 그래서 실제로 확인 카드를 띄우는 툴만 골라(허용 목록) PostToolUse 없이 그 툴의 지연 이상 실행 중이면 사용자 확인을 기다리는 것으로 본다.
/// 추정이므로 문구도 "필요할 수 있어요" 로 둔다 (`SessionStore.checkStalledTools()`).
///
/// 예전에는 앱 · 브라우저 MCP 의 모든 툴을 2.5초 동안 지켜보고 오래 걸리는 툴만 빼서, 느린 호출(느린 페이지 찾기 · 앱 첫 실행 ·
/// 스크립트 실행 등)마다 확인 카드가 잘못 떠서 포커스를 가져갔다
public struct AppConsentHeuristic: Hashable, Sendable {
    /// 지켜볼 툴 → 이만큼 끝나지 않으면 확인 대기로 본다 (초). 여기 없는 툴은 지켜보지 않는다
    public var delays: [String: TimeInterval]
    /// `tool_input.action` 이 이 값이면 원래 오래 걸리는 호출로 보고 제외한다 (예: 몇 초 기다리기)
    public var longRunningActions: Set<String>

    public init(delays: [String: TimeInterval], longRunningActions: Set<String>) {
        self.delays = delays
        self.longRunningActions = longRunningActions
    }

    /// 확인 카드를 띄우는 툴의 지연
    public static let consentDelay: TimeInterval = 2.5
    /// 페이지를 다루는 브라우저 툴의 지연. 원래 몇 초 걸리기도 해서 훨씬 길게 기다린다
    public static let pageActionDelay: TimeInterval = 8

    /// 앱 내 브라우저 · Chrome 확장 툴 접두사
    static let browserPrefixes = ["mcp__Claude_Browser__", "mcp__claude-in-chrome__"]

    /// 호출하면 확인 카드를 띄우는 툴
    static let consentTools: [String] = [
        // 앱 접근 · 화면 전체 제어 · 가르치기 승인
        "mcp__computer-use__request_access",
        "mcp__computer-use__request_full_control",
        "mcp__computer-use__request_teach_access",
        // 폴더 접근 승인
        "mcp__ccd_directory__request_directory",
        "mcp__ccd_directory__change_directory",
        // Chrome 브라우저 선택
        "mcp__claude-in-chrome__select_browser",
        "mcp__claude-in-chrome__switch_browser",
    ] + browserPrefixes.map { $0 + "navigate" }  // 처음 가는 사이트의 접근 승인

    /// 처음 보는 사이트의 페이지를 다루면 사이트 접근 승인 카드를 띄울 수 있는 브라우저 툴 (`pageActionDelay`).
    /// 여러 동작을 묶어 실행하는 browser_batch 등 원래 오래 걸리는 툴은 넣지 않는다
    static let pageActionTools: [String] = browserPrefixes.flatMap { prefix in
        ["computer", "find", "form_input", "get_page_text", "javascript_tool", "read_page"].map { prefix + $0 }
    }

    public static let `default` = AppConsentHeuristic(
        delays: Dictionary(
            consentTools.map { ($0, consentDelay) } + pageActionTools.map { ($0, pageActionDelay) },
            uniquingKeysWith: { first, _ in first }
        ),
        longRunningActions: ["wait"]
    )

    /// 이 툴 호출을 확인 카드 대기로 지켜볼 지연 (지켜보지 않으면 nil)
    public func delay(toolName: String, toolInput: JSONValue?) -> TimeInterval? {
        guard let delay = delays[toolName] else { return nil }
        if let action = toolInput?["action"]?.stringValue, longRunningActions.contains(action) {
            return nil
        }
        return delay
    }

    /// 이 툴 호출이 앱 확인 카드를 띄울 수 있어 지켜볼 대상인지
    public func watches(toolName: String, toolInput: JSONValue?) -> Bool {
        delay(toolName: toolName, toolInput: toolInput) != nil
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
