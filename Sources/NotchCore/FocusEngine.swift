import Foundation

/// 주로 볼 세션(포커스)과 목록 순서를 계산하는 순수 함수 모음 (architecture.md §5)
///
/// 1. 끼어들기: 권한 대기(오래된 요청 먼저) → 대기열 없는 권한 대기 → 입력 대기 → 실패 → 미확인 완료
/// 2. 사용자가 직접 선택한 세션 → 고정 세션
/// 3. 현재 포커스가 아직 작업 중이면 유지, 아니면 작업 중인 세션 중 가장 최근
/// 4. 가장 최근 이벤트가 있었던 세션
public enum FocusEngine {
    public struct Decision: Hashable, Sendable {
        /// 우선순위 순 세션 ID
        public var rankedIDs: [String]
        public var focusedID: String?

        public init(rankedIDs: [String], focusedID: String?) {
            self.rankedIDs = rankedIDs
            self.focusedID = focusedID
        }
    }

    public static func decide(
        sessions: [AgentSession],
        pendingPermissions: [PermissionRequestInfo],
        manualFocusID: String?,
        pinnedID: String?,
        currentFocusID: String?
    ) -> Decision {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // 세션별 가장 오래된 권한 요청 시각
        var oldestPending: [String: Date] = [:]
        for request in pendingPermissions where byID[request.sessionID] != nil {
            if let existing = oldestPending[request.sessionID], existing <= request.receivedAt { continue }
            oldestPending[request.sessionID] = request.receivedAt
        }

        let attention = attentionOrder(sessions, oldestPending: oldestPending)
        let recent = sessions.sorted(by: mostRecentFirst)

        // 목록 순서: 끼어들기 → 고정 → 작업 중(최근순) → 나머지(최근순)
        var ranked: [String] = []
        var seen = Set<String>()
        func add(_ id: String) {
            if seen.insert(id).inserted { ranked.append(id) }
        }
        attention.forEach(add)
        if let pinnedID, byID[pinnedID] != nil { add(pinnedID) }
        recent.filter { $0.phase.isWorking }.forEach { add($0.id) }
        recent.forEach { add($0.id) }

        // 포커스
        let focused: String?
        if let first = attention.first {
            focused = first
        } else if let manualFocusID, byID[manualFocusID] != nil {
            focused = manualFocusID
        } else if let pinnedID, byID[pinnedID] != nil {
            focused = pinnedID
        } else if let currentFocusID, let current = byID[currentFocusID], current.phase.isWorking {
            // 작업 중인 세션끼리는 자동 전환하지 않음 (깜빡임 방지)
            focused = current.id
        } else if let working = recent.first(where: { $0.phase.isWorking }) {
            focused = working.id
        } else {
            focused = recent.first?.id
        }
        return Decision(rankedIDs: ranked, focusedID: focused)
    }

    /// 끼어들기 대상 세션 ID (우선순위 순)
    static func attentionOrder(_ sessions: [AgentSession], oldestPending: [String: Date]) -> [String] {
        // 1) 권한 대기열이 있는 세션: 오래된 요청 먼저
        var pendingPairs: [(id: String, at: Date)] = []
        for session in sessions {
            if let at = oldestPending[session.id] { pendingPairs.append((session.id, at)) }
        }
        pendingPairs.sort { lhs, rhs in
            if lhs.at != rhs.at { return lhs.at < rhs.at }
            return lhs.id < rhs.id
        }
        let withPending: [String] = pendingPairs.map(\.id)
        let rest = sessions.filter { oldestPending[$0.id] == nil }

        // 2) 대기열 없이 권한 대기 (터미널 프롬프트) · 3) 입력 대기: 오래 기다린 순
        let waitingPermission = rest.filter { $0.phase == .waitingPermission }.sorted(by: oldestFirst)
        let waitingInput = rest.filter { $0.phase == .waitingInput }.sorted(by: oldestFirst)
        // 4) 실패 · 5) 미확인 완료: 최근순
        let failed = rest.filter { $0.phase == .failed }.sorted(by: mostRecentFirst)
        let completed = rest.filter { $0.phase == .completed && $0.hasUnseenCompletion }.sorted(by: mostRecentFirst)

        var ordered = withPending
        for group in [waitingPermission, waitingInput, failed, completed] {
            ordered.append(contentsOf: group.map(\.id))
        }
        return ordered
    }

    private static func mostRecentFirst(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        lhs.lastEventAt != rhs.lastEventAt ? lhs.lastEventAt > rhs.lastEventAt : lhs.id < rhs.id
    }

    private static func oldestFirst(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        lhs.lastEventAt != rhs.lastEventAt ? lhs.lastEventAt < rhs.lastEventAt : lhs.id < rhs.id
    }
}
