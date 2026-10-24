import Foundation
import NotchShared

/// 세션과 상관없는 앱 안내 카드 (예: Codex 훅 허용 필요). App 이 `NotchUIController.setNotice` 로 넣는다.
/// 입력 필요 카드와 같은 자리 · 모양 · 우선순위로 띄운다 (`IslandMode.needsInput` 의 세션 ID 자리에 `id` 를 넣는다):
/// 권한 요청 · 세션의 입력 대기가 먼저고, 그것들이 없을 때 보인다. 접기(⎋ 포함) · 버튼을 누르면 App 에 알리고 내린다
public struct IslandNotice: Equatable, Sendable {
    /// 안내 ID. 세션 ID 와 겹치지 않게 `notice:` 로 시작한다
    public var id: String
    /// 머리의 아이콘 (없으면 아이콘 없이)
    public var agent: AgentKind?
    /// 머리 제목 (예: "Codex 훅")
    public var title: String
    /// 머리 오른쪽 주황 글자 (예: "허용 필요")
    public var badge: String
    /// 본문 (두 줄까지)
    public var message: String
    /// 오른쪽 버튼 (없으면 접기만)
    public var actionTitle: String?

    public init(id: String, agent: AgentKind? = nil, title: String, badge: String, message: String, actionTitle: String? = nil) {
        self.id = id.hasPrefix(Self.idPrefix) ? id : Self.idPrefix + id
        self.agent = agent
        self.title = title
        self.badge = badge
        self.message = message
        self.actionTitle = actionTitle
    }

    public static let idPrefix = "notice:"

    /// Codex 훅을 설치했는데 Codex 가 아직 실행하지 않는 것 같음 (`CodexHookMonitor`). 단정하지 않는다:
    /// 훅을 통째로 끈 경우에도 이벤트가 안 온다
    public static func codexHooksAwaitingTrust(canOpenApp: Bool) -> IslandNotice {
        IslandNotice(
            id: codexHooksID,
            agent: .codex,
            title: "Codex 훅",
            badge: "허용 필요",
            message: "Codex 훅 이벤트가 오지 않아요. Codex 앱 훅 검토(CLI 는 /hooks)에서 허용해 주세요",
            actionTitle: canOpenApp ? "Codex로" : nil
        )
    }

    public static let codexHooksID = idPrefix + "codex-hooks"

    /// 사용자가 안내 카드에서 한 일
    public enum Response: Equatable, Sendable {
        /// 오른쪽 버튼
        case action(id: String)
        /// 접기 (⎋ 포함)
        case dismissed(id: String)
    }
}
