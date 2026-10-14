import Foundation
import Testing
@testable import NotchCore

/// 아일랜드 · 메뉴바가 같이 쓰는 백그라운드 작업 문구 규칙
@Suite struct SessionStatusTextTests {
    private func session(
        _ phase: SessionPhase,
        unseen: Bool = false,
        subagents: Int = 0,
        shells: Int = 0,
        others: Int = 0
    ) -> AgentSession {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        return AgentSession(
            id: "s1", cwd: projectCwd, projectName: "api-server", phase: phase, startedAt: at, lastEventAt: at,
            hasUnseenCompletion: unseen, activeSubagents: subagents, backgroundShells: shells, backgroundOthers: others
        )
    }

    @Test func settledSessionsWithBackgroundWorkShowCount() {
        #expect(session(.idle, subagents: 1).backgroundStatusText == "백그라운드 1개 작업 중")
        #expect(session(.completed, subagents: 1, shells: 2, others: 1).backgroundStatusText == "백그라운드 4개 작업 중")
        #expect(session(.idle, shells: 1).isSettledWithBackgroundWork)
    }

    @Test func unseenCompletionWinsOverBackgroundWork() {
        // 확인하지 않은 완료는 "완료" 를 먼저 알린다
        let done = session(.completed, unseen: true, subagents: 2)
        #expect(done.backgroundStatusText == nil)
        #expect(!done.isSettledWithBackgroundWork)
    }

    @Test func noTextWithoutBackgroundWorkOrWhileBusy() {
        #expect(session(.idle).backgroundStatusText == nil)
        #expect(session(.completed).backgroundStatusText == nil)
        // 일하는 중 · 기다리는 중 · 실패 · 종료는 각자 문구가 있다
        for phase in SessionPhase.allCases where phase != .idle && phase != .completed {
            #expect(session(phase, subagents: 1).backgroundStatusText == nil, "\(phase)")
        }
    }

    @Test func settledWithBackgroundWorkCountsAsWorkingInSummary() {
        // 문구가 백그라운드 작업을 말하는 세션은 요약 칩에서도 진행 중이다
        for candidate in [session(.idle, others: 1), session(.completed, shells: 1)] {
            #expect(candidate.isSettledWithBackgroundWork)
            #expect(SessionStatusSummary.group(for: candidate) == .working)
        }
    }
}
