import Foundation
import Observation
import NotchShared

/// 모든 세션 상태의 단일 진실 공급원.
///
/// - 훅 이벤트(`HookEnvelope`)를 받아 세션 상태를 갱신한다.
/// - 포커스(주로 볼 세션)를 계산한다.
/// - UI 가 일시적으로 반응할 신호(`latestSignal`)를 내보낸다.
/// - 권한 요청 대기열을 관리하고, 사용자 결정을 `onPermissionResolved` 로 알린다.
///
/// NOTE: 공개 API 시그니처는 다른 모듈(UI, Services, App)이 의존하는 계약이므로 변경하지 않는다.
@MainActor
@Observable
public final class SessionStore {
    /// session_id → 세션
    public private(set) var sessions: [String: AgentSession] = [:]
    /// 포커스 우선순위 순으로 정렬된 세션 목록 (UI 목록용, 종료된 세션 제외)
    public private(set) var rankedSessions: [AgentSession] = []
    /// 지금 노치가 주로 보여줄 세션
    public private(set) var focusedSessionID: String?
    /// 사용자가 고정한 세션
    public private(set) var pinnedSessionID: String?
    /// 응답 대기 중인 권한 요청 (오래된 순)
    public private(set) var pendingPermissions: [PermissionRequestInfo] = []
    /// UI 일시 반응용 최신 신호
    public private(set) var latestSignal: SignalEvent?

    /// 권한 요청에 대한 사용자 결정이 나면 호출된다 (SocketServer 가 훅 프로세스에 응답을 전달).
    public var onPermissionResolved: (@MainActor (PermissionRequestInfo, PermissionDecision) -> Void)?

    private let clock: () -> Date

    public init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    public var focusedSession: AgentSession? {
        focusedSessionID.flatMap { sessions[$0] }
    }

    /// 훅 이벤트를 반영한다. 응답을 기다려야 하는 이벤트(PermissionRequest)면 권한 요청 ID 를 반환한다.
    @discardableResult
    public func ingest(_ envelope: HookEnvelope) -> UUID? {
        // TODO: NotchCore 구현 단계에서 채움
        nil
    }

    /// 사용자가 권한 요청에 대해 결정함 → 대기열에서 제거하고 `onPermissionResolved` 호출
    public func resolvePermission(id: UUID, decision: PermissionDecision) {
        // TODO: NotchCore 구현 단계에서 채움
    }

    /// 훅 연결이 끊기거나 타임아웃 → 대기열에서만 제거 (`onPermissionResolved` 호출 안 함)
    public func cancelPermission(id: UUID) {
        // TODO: NotchCore 구현 단계에서 채움
    }

    /// 고정 토글 (이미 고정된 세션이면 해제)
    public func togglePin(sessionID: String) {
        // TODO: NotchCore 구현 단계에서 채움
    }

    /// 사용자가 명시적으로 세션을 선택함
    public func focus(sessionID: String) {
        // TODO: NotchCore 구현 단계에서 채움
    }

    /// 완료 알림 확인 처리
    public func markSeen(sessionID: String) {
        // TODO: NotchCore 구현 단계에서 채움
    }

    /// 목록에서 세션 제거
    public func dismiss(sessionID: String) {
        // TODO: NotchCore 구현 단계에서 채움
    }

    /// 오래 이벤트가 없는 세션 정리
    public func pruneStaleSessions(olderThan interval: TimeInterval) {
        // TODO: NotchCore 구현 단계에서 채움
    }
}
