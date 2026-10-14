import Foundation

/// 아일랜드 목록 부제 · 메뉴바 메뉴가 함께 쓰는 세션 상태 문구 규칙.
///
/// 메인 답변이 끝나 쉬고 있어도(유휴, 이미 확인한 완료) 서브에이전트 · 백그라운드 셸 등이 돌고 있으면
/// "완료" · "대기 중" 대신 백그라운드 작업 문구를 보여준다. 요약 칩(`SessionStatusSummary`)도 이런 세션을 진행 중으로 센다.
/// 확인하지 않은 완료는 "완료" 를 먼저 알린다.
extension AgentSession {
    /// 쉬는 중(유휴 · 확인한 완료)인데 백그라운드 작업이 돌고 있는지
    public var isSettledWithBackgroundWork: Bool {
        guard backgroundTaskCount > 0 else { return false }
        switch phase {
        case .idle: return true
        case .completed: return !hasUnseenCompletion
        default: return false
        }
    }

    /// "백그라운드 N개 작업 중". 쉬는 중이 아니거나 백그라운드 작업이 없으면 nil
    public var backgroundStatusText: String? {
        isSettledWithBackgroundWork ? Self.backgroundStatusText(count: backgroundTaskCount) : nil
    }

    /// 백그라운드 작업 수 문구 (단계와 상관없이)
    public static func backgroundStatusText(count: Int) -> String {
        "백그라운드 \(count)개 작업 중"
    }
}
