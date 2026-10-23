import Foundation

/// 훅 이벤트를 보낸 코딩 에이전트.
///
/// 두 에이전트의 훅은 이벤트 이름 · payload 모양이 거의 같아서(`hook_event_name` · `session_id` · `tool_name` …) 같은 헬퍼 · 같은 소켓을 쓰고,
/// 헬퍼는 훅 명령의 `--agent` 로 받은 이름을 `HookEnvelope.agent` 에 담는다.
/// Claude Code 훅 명령에는 `--agent` 를 붙이지 않는다 (예전에 설치한 훅 · 예전 헬퍼와 같은 모양 → 이름이 없으면 Claude Code).
public enum AgentKind: String, Codable, Hashable, Sendable, CaseIterable {
    case claude
    case codex

    /// 화면에 쓰는 이름 ("Claude Code" · "Codex")
    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// 헬퍼 명령줄 옵션 (`notch-hook --agent codex PreToolUse`)
    public static let commandLineFlag = "--agent"

    /// 이름 → 종류. 모르는 이름 · 빈 값은 nil
    public init?(name: String?) {
        guard let name = name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return nil }
        self.init(rawValue: name)
    }
}
