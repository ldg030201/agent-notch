import Foundation

/// 세션 상태 요약: 기다리는 중(주황) · 진행 중(초록) · 끝남(회색) 개수.
/// 접힌 아일랜드는 지금 보여주는 세션을 뺀 나머지를, 펼친 목록 머리는 모든 세션을 요약한다. 종료된 세션은 세지 않는다.
public struct SessionStatusSummary: Hashable, Sendable {
    /// 표시 순서: 기다리는 중 → 진행 중 → 끝남
    public enum Group: Int, CaseIterable, Hashable, Sendable {
        /// 권한 · 입력 대기, 실패 (`SessionPhase.needsAttention`)
        case waiting
        /// 추론 · 툴 실행 · 압축 (`SessionPhase.isWorking`)
        case working
        /// 완료 · 유휴
        case done

        /// 읽어 주는 이름
        public var spokenName: String {
            switch self {
            case .waiting: return "기다리는 중"
            case .working: return "진행 중"
            case .done: return "끝남"
            }
        }
    }

    public var waiting: Int
    public var working: Int
    public var done: Int

    public init(waiting: Int = 0, working: Int = 0, done: Int = 0) {
        self.waiting = waiting
        self.working = working
        self.done = done
    }

    /// `excluding` 세션(지금 보여주는 세션)을 뺀 나머지 요약
    public init<S: Sequence>(sessions: S, excluding excludedID: String? = nil) where S.Element == AgentSession {
        self.init()
        for session in sessions where session.id != excludedID {
            guard let group = Self.group(for: session) else { continue }
            switch group {
            case .waiting: waiting += 1
            case .working: working += 1
            case .done: done += 1
            }
        }
    }

    public static let empty = SessionStatusSummary()

    /// 세션 → 묶음. 메인 답변이 끝났어도 백그라운드 작업이 돌고 있으면 진행 중으로 센다
    public static func group(for session: AgentSession) -> Group? {
        let group = group(for: session.phase)
        return group == .done && session.backgroundTaskCount > 0 ? .working : group
    }

    /// 단계 → 묶음 (종료된 세션은 nil)
    public static func group(for phase: SessionPhase) -> Group? {
        if phase == .ended { return nil }
        if phase.needsAttention { return .waiting }
        if phase.isWorking { return .working }
        return .done
    }

    public func count(_ group: Group) -> Int {
        switch group {
        case .waiting: return waiting
        case .working: return working
        case .done: return done
        }
    }

    public var total: Int { waiting + working + done }
    public var isEmpty: Bool { total == 0 }

    /// 0 이 아닌 묶음 (표시 순서)
    public var groups: [(group: Group, count: Int)] {
        Group.allCases.compactMap { group in
            let value = count(group)
            return value > 0 ? (group, value) : nil
        }
    }

    /// 읽어 주는 문장 (예: "기다리는 중 2개, 진행 중 1개, 끝남 3개"). 비었으면 빈 문자열
    public var spokenText: String {
        groups.map { "\($0.group.spokenName) \($0.count)개" }.joined(separator: ", ")
    }
}
