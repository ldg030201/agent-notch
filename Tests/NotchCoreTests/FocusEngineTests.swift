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

    @Test func emptySessions() {
        #expect(decide([]) == FocusEngine.Decision(rankedIDs: [], focusedID: nil))
        // 없는 세션을 현재 포커스로 넘겨도 남은 세션으로 정한다
        let result = decide([session("idle", phase: .idle, at: 10)], current: "gone")
        #expect(result.rankedIDs == ["idle"])
        #expect(result.focusedID == "idle")
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

    // MARK: - 자동 넘기기

    @Test func rotationPoolKeepsActiveSessionsInStartOrder() {
        var background = session("background", phase: .idle, at: 15)
        background.backgroundShells = 1
        let sessions = [
            session("thinking", phase: .thinking, at: 30),
            session("idle", phase: .idle, at: 5),
            session("unseen", phase: .completed, at: 20, unseen: true),
            session("seen", phase: .idle, at: 25),
            session("asking", phase: .waitingInput, at: 10),
            session("failed", phase: .failed, at: 40),
            background,
        ]
        // 쉬는 세션(확인한 완료 포함)은 넘기지 않는다. 순서는 시작한 순서 (이벤트로 바뀌지 않음)
        let pool = FocusEngine.rotationPool(sessions)
        #expect(pool == ["asking", "background", "unseen", "thinking", "failed"])

        #expect(FocusEngine.next(after: "asking", in: pool) == "background")
        #expect(FocusEngine.next(after: "failed", in: pool) == "asking")
        // 지금 보여주는 세션이 대상이 아니면 처음부터
        #expect(FocusEngine.next(after: "idle", in: pool) == "asking")
        #expect(FocusEngine.next(after: nil, in: pool) == "asking")
        #expect(FocusEngine.next(after: "a", in: []) == nil)
    }

    @Test func rotationPrecedence() {
        let sessions = [
            session("a", phase: .runningTool, at: 10),
            session("b", phase: .thinking, at: 20),
            session("done", phase: .completed, at: 30, unseen: true),
            session("idle", phase: .idle, at: 40),
        ]
        // 넘기기가 고른 세션이 미확인 완료 · 작업 중 유지보다 먼저
        #expect(decide(sessions, current: "a").focusedID == "done")
        #expect(FocusEngine.decide(
            sessions: sessions, pendingPermissions: [], manualFocusID: nil, pinnedID: nil, rotationID: "b", currentFocusID: "a"
        ).focusedID == "b")
        // 넘기기 대상이 아닌 세션은 무시
        #expect(FocusEngine.decide(
            sessions: sessions, pendingPermissions: [], manualFocusID: nil, pinnedID: nil, rotationID: "idle", currentFocusID: "a"
        ).focusedID == "done")
        // 직접 선택 · 고정이 넘기기보다 먼저
        #expect(FocusEngine.decide(
            sessions: sessions, pendingPermissions: [], manualFocusID: nil, pinnedID: "idle", rotationID: "b", currentFocusID: "a"
        ).focusedID == "idle")
        #expect(FocusEngine.decide(
            sessions: sessions, pendingPermissions: [], manualFocusID: "a", pinnedID: "idle", rotationID: "b", currentFocusID: nil
        ).focusedID == "a")
        // 승인 대기는 무엇보다 먼저
        let asking = sessions + [session("asking", phase: .waitingPermission, at: 50)]
        #expect(FocusEngine.decide(
            sessions: asking, pendingPermissions: [], manualFocusID: "a", pinnedID: "idle", rotationID: "b", currentFocusID: nil
        ).focusedID == "asking")
        // 고정 세션은 미확인 완료보다 먼저 (완료는 카드로 알린다)
        #expect(decide(sessions, pinned: "idle").focusedID == "idle")
    }

    /// 작업 중인 세션 셋(a · b · c 순서로 시작)과 쉬는 세션 하나
    @MainActor
    private func rotatingStore(_ clock: TestClock) -> SessionStore {
        let store = makeStore(clock)
        for (id, cwd) in [("a", projectCwd), ("b", otherCwd), ("c", "/Users/dev/projects/docs-site")] {
            store.ingest(hook("UserPromptSubmit", session: id, cwd: cwd, #"{"prompt":"go"}"#))
            clock.advance()
        }
        store.ingest(hook("SessionStart", session: "idle", cwd: "/Users/dev/projects/blog", "{}"))
        clock.advance()
        return store
    }

    @MainActor
    @Test func rotateFocusCyclesActiveSessions() {
        let clock = TestClock()
        let store = rotatingStore(clock)
        #expect(store.focusedSessionID == "a")
        var shown: [String?] = []
        for _ in 0..<4 {
            store.rotateFocus()
            shown.append(store.focusedSessionID)
        }
        // 쉬는 세션은 건너뛰고 시작한 순서로 돈다. 이벤트가 와도 순서는 그대로
        #expect(shown == ["b", "c", "a", "b"])
        store.ingest(hook("PostToolUse", session: "a", #"{"tool_name":"Read","tool_input":{"file_path":"x"}}"#))
        store.rotateFocus()
        #expect(store.focusedSessionID == "c")

        // 활동 중인 세션이 하나뿐이면 넘기지 않는다
        store.ingest(hook("SessionEnd", session: "a", "{}"))
        store.ingest(hook("SessionEnd", session: "b", cwd: otherCwd, "{}"))
        store.rotateFocus()
        #expect(store.focusedSessionID == "c")
    }

    @MainActor
    @Test func pinStopsRotation() {
        let clock = TestClock()
        let store = rotatingStore(clock)
        store.togglePin(sessionID: "b")
        #expect(store.focusedSessionID == "b")
        store.rotateFocus()
        store.rotateFocus()
        #expect(store.focusedSessionID == "b")
        // 쉬는 세션도 고정하면 그 세션을 보여준다
        store.togglePin(sessionID: "idle")
        store.rotateFocus()
        #expect(store.focusedSessionID == "idle")
        // 풀면 다시 넘긴다 (작업 중인 세션 중에서)
        store.togglePin(sessionID: "idle")
        #expect(store.pinnedSessionID == nil)
        store.rotateFocus()
        #expect(["a", "b", "c"].contains(store.focusedSessionID ?? ""))
        let first = store.focusedSessionID
        store.rotateFocus()
        #expect(store.focusedSessionID != first)
    }

    @MainActor
    @Test func pinPrecedesManualPick() {
        let clock = TestClock()
        let store = rotatingStore(clock)
        store.focus(sessionID: "c")
        #expect(store.focusedSessionID == "c")
        // 고정하면 바로 그 세션 (고른 세션을 놓는다)
        store.togglePin(sessionID: "a")
        #expect(store.focusedSessionID == "a")
        // 고정한 동안 고른 세션은 한 번만 보여주고 고정 세션으로 돌아간다
        store.focus(sessionID: "b")
        #expect(store.focusedSessionID == "b")
        store.rotateFocus()
        #expect(store.focusedSessionID == "a")
    }

    @MainActor
    @Test func manualPickContinuesRotationFromIt() {
        let clock = TestClock()
        let store = rotatingStore(clock)
        store.focus(sessionID: "c")
        #expect(store.focusedSessionID == "c")
        store.rotateFocus()
        #expect(store.focusedSessionID == "a")
        // 쉬는 세션을 고르면 한 번 보여준 뒤 넘기기 대상의 처음부터
        store.focus(sessionID: "idle")
        #expect(store.focusedSessionID == "idle")
        store.rotateFocus()
        #expect(store.focusedSessionID == "a")
    }

    @MainActor
    @Test func alertsJumpRotation() {
        let clock = TestClock()
        let store = rotatingStore(clock)
        #expect(store.focusedSessionID == "a")
        // 완료 알림이 온 세션으로 바로 넘어가고, 다음 넘기기는 그 세션 다음부터
        store.ingest(hook("Stop", session: "c", cwd: "/Users/dev/projects/docs-site", "{}"))
        #expect(store.focusedSessionID == "c")
        store.rotateFocus()
        #expect(store.focusedSessionID == "a")
        // 확인하지 않은 완료도 넘기기 대상이다
        store.rotateFocus()
        store.rotateFocus()
        #expect(store.focusedSessionID == "c")

        // 승인 대기 중이면 넘기지 않는다
        let id = store.ingest(hook("PermissionRequest", session: "b", cwd: otherCwd, #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#))
        #expect(store.focusedSessionID == "b")
        store.rotateFocus()
        #expect(store.focusedSessionID == "b")
        store.resolvePermission(id: id!, decision: .allow)

        // 고정한 세션이 있으면 알림이 와도 고정 세션 (알림은 카드로 보여준다)
        store.togglePin(sessionID: "a")
        store.ingest(hook("StopFailure", session: "b", cwd: otherCwd, #"{"error":"rate_limit"}"#))
        #expect(store.focusedSessionID == "a")
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
