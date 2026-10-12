import Foundation
import Testing
@testable import NotchCore
import NotchShared

@Suite struct FocusEngineTests {
    private func decide(
        _ sessions: [AgentSession],
        pending: [PermissionRequestInfo] = [],
        manual: String? = nil,
        pinned: String? = nil,
        current: String? = nil
    ) -> FocusEngine.Decision {
        FocusEngine.decide(
            sessions: sessions,
            pendingPermissions: pending,
            manualFocusID: manual,
            pinnedID: pinned,
            currentFocusID: current
        )
    }

    @Test func interruptPriority() {
        let sessions = [
            session("working", phase: .runningTool, at: 100),
            session("done", phase: .completed, at: 90, unseen: true),
            session("seen", phase: .completed, at: 95),
            session("failed", phase: .failed, at: 80),
            session("input", phase: .waitingInput, at: 70),
            session("terminalPrompt", phase: .waitingPermission, at: 60),
            session("hooked", phase: .runningTool, at: 50),
            session("idle", phase: .idle, at: 10),
        ]
        let result = decide(sessions, pending: [pending("hooked", at: 55)], current: "working")
        #expect(result.focusedID == "hooked")
        #expect(result.rankedIDs == ["hooked", "terminalPrompt", "input", "failed", "done", "working", "seen", "idle"])
    }

    @Test func oldestPendingFirst() {
        let sessions = [
            session("a", phase: .waitingPermission, at: 10),
            session("b", phase: .waitingPermission, at: 20),
        ]
        let result = decide(sessions, pending: [pending("b", at: 5), pending("a", at: 8), pending("a", at: 1)])
        #expect(result.rankedIDs == ["a", "b"])
        #expect(result.focusedID == "a")
    }

    @Test func workingHysteresis() {
        let sessions = [
            session("older", phase: .runningTool, at: 10),
            session("newer", phase: .thinking, at: 20),
        ]
        // 현재 포커스가 아직 작업 중이면 유지
        #expect(decide(sessions, current: "older").focusedID == "older")
        // 포커스가 없으면 가장 최근 작업 중 세션
        #expect(decide(sessions).focusedID == "newer")
        // 현재 포커스가 작업을 멈추면 작업 중인 다른 세션으로
        let stopped = [
            session("older", phase: .idle, at: 30),
            session("newer", phase: .thinking, at: 20),
        ]
        #expect(decide(stopped, current: "older").focusedID == "newer")
        #expect(decide(stopped).rankedIDs == ["newer", "older"])
    }

    @Test func mostRecentWhenNothingWorking() {
        let sessions = [
            session("a", phase: .idle, at: 10),
            session("b", phase: .completed, at: 30),
            session("c", phase: .idle, at: 20),
        ]
        let result = decide(sessions, current: "a")
        #expect(result.focusedID == "b")
        #expect(result.rankedIDs == ["b", "c", "a"])
    }

    @Test func manualFocusAndPin() {
        let sessions = [
            session("working", phase: .runningTool, at: 100),
            session("pinned", phase: .idle, at: 10),
            session("chosen", phase: .idle, at: 5),
        ]
        // 고정 세션이 작업 중 세션보다 우선
        let pinnedResult = decide(sessions, pinned: "pinned", current: "working")
        #expect(pinnedResult.focusedID == "pinned")
        #expect(pinnedResult.rankedIDs == ["pinned", "working", "chosen"])
        // 직접 선택한 세션이 고정보다 우선
        #expect(decide(sessions, manual: "chosen", pinned: "pinned").focusedID == "chosen")
        // 끼어들기가 직접 선택보다 우선
        let interrupted = sessions + [session("asking", phase: .waitingInput, at: 50)]
        #expect(decide(interrupted, manual: "chosen", pinned: "pinned").focusedID == "asking")
        // 없는 세션 ID 는 무시
        #expect(decide(sessions, manual: "gone", pinned: "gone2").focusedID == "working")
    }

    @Test func endedExcludedAndEmpty() {
        let sessions = [
            session("ended", phase: .ended, at: 100),
            session("idle", phase: .idle, at: 10),
        ]
        let result = decide(sessions, current: "ended")
        #expect(result.rankedIDs == ["idle"])
        #expect(result.focusedID == "idle")
        #expect(decide([]) == FocusEngine.Decision(rankedIDs: [], focusedID: nil))
    }

    @MainActor
    @Test func storeFocusLifecycle() {
        let clock = TestClock()
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", session: "a", #"{"prompt":"a"}"#))
        clock.advance()
        store.ingest(hook("UserPromptSubmit", session: "b", cwd: otherCwd, #"{"prompt":"b"}"#))
        // a 가 먼저 작업 중이었으므로 유지
        #expect(store.focusedSessionID == "a")

        // 직접 선택
        store.focus(sessionID: "b")
        #expect(store.focusedSessionID == "b")

        // 권한 요청 끼어들기
        clock.advance()
        let id = store.ingest(hook("PermissionRequest", session: "a", #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#))
        #expect(store.focusedSessionID == "a")
        #expect(store.rankedSessions.first?.id == "a")
        store.resolvePermission(id: id!, decision: .allow)
        #expect(store.focusedSessionID == "b")

        // 선택한 세션이 제거되면 선택 해제 → 작업 중 세션
        store.dismiss(sessionID: "b")
        #expect(store.focusedSessionID == "a")

        // 고정 토글
        clock.advance()
        store.ingest(hook("SessionStart", session: "c", cwd: otherCwd, "{}"))
        store.togglePin(sessionID: "c")
        #expect(store.pinnedSessionID == "c")
        #expect(store.focusedSessionID == "c")
        store.togglePin(sessionID: "c")
        #expect(store.pinnedSessionID == nil)
        #expect(store.focusedSessionID == "a")

        // 고정된 세션이 끝나면 고정 해제
        store.togglePin(sessionID: "c")
        store.ingest(hook("SessionEnd", session: "c", "{}"))
        #expect(store.pinnedSessionID == nil)
        #expect(store.rankedSessions.map(\.id) == ["a"])
    }

    @MainActor
    @Test func completionInterruptsUntilSeen() {
        let clock = TestClock()
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", session: "a", #"{"prompt":"a"}"#))
        clock.advance()
        store.ingest(hook("UserPromptSubmit", session: "b", cwd: otherCwd, #"{"prompt":"b"}"#))
        clock.advance()
        store.ingest(hook("Stop", session: "b", cwd: otherCwd, "{}"))
        #expect(store.focusedSessionID == "b")
        store.markSeen(sessionID: "b")
        #expect(store.focusedSessionID == "a")
    }
}
