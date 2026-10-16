import Foundation
import Testing
@testable import NotchCore

@Suite struct SessionStatusSummaryTests {
    private func session(_ id: String, _ phase: SessionPhase) -> AgentSession {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        return AgentSession(id: id, cwd: projectCwd, projectName: "api-server", phase: phase, startedAt: at, lastEventAt: at)
    }

    @Test func groupsEveryPhase() {
        #expect(SessionStatusSummary.group(for: .waitingPermission) == .waiting)
        #expect(SessionStatusSummary.group(for: .waitingInput) == .waiting)
        #expect(SessionStatusSummary.group(for: .failed) == .waiting)
        #expect(SessionStatusSummary.group(for: .thinking) == .working)
        #expect(SessionStatusSummary.group(for: .runningTool) == .working)
        #expect(SessionStatusSummary.group(for: .compacting) == .working)
        #expect(SessionStatusSummary.group(for: .completed) == .done)
        #expect(SessionStatusSummary.group(for: .idle) == .done)
        // 새 단계가 생기면 여기서 묶음을 정해야 한다
        #expect(SessionPhase.allCases.count == 8)
    }

    @Test func countsEverySession() {
        let sessions = [
            session("shown", .runningTool),
            session("permission", .waitingPermission),
            session("input", .waitingInput),
            session("thinking", .thinking),
            session("done", .completed),
            session("idle", .idle),
        ]
        let summary = SessionStatusSummary(sessions: sessions)
        #expect(summary == SessionStatusSummary(waiting: 2, working: 2, done: 2))
        #expect(summary.total == 6)
        #expect(summary.groups.map(\.group) == [.waiting, .working, .done])
        #expect(summary.spokenText == "기다리는 중 2개, 진행 중 2개, 끝남 2개")
    }

    @Test func skipsEmptyGroups() {
        let summary = SessionStatusSummary(sessions: [session("a", .idle), session("b", .completed)])
        #expect(summary.groups.count == 1)
        #expect(summary.groups.first?.group == .done)
        #expect(summary.groups.first?.count == 2)
        #expect(summary.spokenText == "끝남 2개")
    }

    @Test func emptyWithoutSessions() {
        let summary = SessionStatusSummary(sessions: [AgentSession]())
        #expect(summary.isEmpty)
        #expect(summary.groups.isEmpty)
        #expect(summary.spokenText.isEmpty)
        #expect(SessionStatusSummary.empty.isEmpty)
    }
}
