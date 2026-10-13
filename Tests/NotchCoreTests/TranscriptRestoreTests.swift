import Foundation
import Testing
@testable import NotchCore
import NotchShared

/// 대화 기록 끝부분으로 세션 되살리기 (가짜 기록만 사용)
@MainActor
@Suite struct TranscriptRestoreTests {
    /// 기록 한 줄 (메인 대화, 가짜 세션 · 경로)
    static func line(_ fields: String, at time: String = "2026-10-13T08:00:00.000Z", sidechain: Bool = false) -> String {
        """
        {"sessionId":"sess-1","cwd":"\(projectCwd)","gitBranch":"main","entrypoint":"cli",\
        "isSidechain":\(sidechain),"timestamp":"\(time)",\(fields)}
        """
    }

    static let prompt = line(#""type":"user","message":{"role":"user","content":"테스트 돌려줘"}"#)
    static func toolUse(_ id: String, _ name: String, at time: String = "2026-10-13T08:00:05.000Z") -> String {
        line(#""type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{"command":"npm test"}}],"stop_reason":"tool_use"}"#, at: time)
    }
    static func toolResult(_ id: String) -> String {
        line(#""type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"ok"}]}"#, at: "2026-10-13T08:00:09.000Z")
    }
    static let stopSummary = line(#""type":"system","subtype":"stop_hook_summary","hookCount":1"#, at: "2026-10-13T08:00:12.000Z")

    @Test func runningToolIsRestored() throws {
        let restored = try #require(TranscriptTail.restore(lines: [Self.prompt, Self.toolUse("t1", "Bash")]))
        #expect(restored.id == "sess-1")
        #expect(restored.cwd == projectCwd)
        #expect(restored.gitBranch == "main")
        #expect(restored.entrypoint == "cli")
        #expect(restored.state == .runningTool(name: "Bash", input: json(#"{"command":"npm test"}"#), toolUseID: "t1"))
        #expect(restored.lastEventAt == TranscriptTail.parseTimestamp("2026-10-13T08:00:05.000Z"))
    }

    @Test func finishedToolMeansThinking() throws {
        let restored = try #require(TranscriptTail.restore(lines: [Self.prompt, Self.toolUse("t1", "Bash"), Self.toolResult("t1")]))
        #expect(restored.state == .thinking)
    }

    @Test func stopHookSummaryEndsTurn() throws {
        let lines = [Self.prompt, Self.toolUse("t1", "Bash"), Self.toolResult("t1"), Self.stopSummary]
        #expect(try #require(TranscriptTail.restore(lines: lines)).state == .finished)
        // 끝난 뒤 새 입력이 오면 다시 응답 중
        #expect(try #require(TranscriptTail.restore(lines: lines + [Self.prompt])).state == .thinking)
    }

    @Test func endTurnAndInterruptEndTurn() throws {
        let endTurn = Self.line(#""type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"끝"}],"stop_reason":"end_turn"}"#)
        #expect(try #require(TranscriptTail.restore(lines: [Self.prompt, endTurn])).state == .finished)

        let interrupted = Self.line(#""type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}"#)
        #expect(try #require(TranscriptTail.restore(lines: [Self.prompt, Self.toolUse("t1", "Bash"), interrupted])).state == .finished)
    }

    @Test func sidechainAndMetaLinesAreIgnored() throws {
        let sidechainTool = Self.line(
            #""type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"s1","name":"Read","input":{}}]}"#,
            sidechain: true
        )
        let meta = Self.line(#""type":"user","isMeta":true,"message":{"role":"user","content":"<system-reminder>"}"#)
        let lines = [Self.prompt, Self.toolUse("t1", "Bash"), Self.toolResult("t1"), Self.stopSummary, sidechainTool, meta]
        #expect(try #require(TranscriptTail.restore(lines: lines)).state == .finished)
    }

    @Test func unknownSessionOrNoTurnIsSkipped() {
        #expect(TranscriptTail.restore(lines: [#"{"type":"user","message":{"content":"x"}}"#]) == nil)
        #expect(TranscriptTail.restore(lines: [Self.line(#""type":"attachment""#)]) == nil)
        #expect(TranscriptTail.restore(lines: ["not json", ""]) == nil)
    }

    @Test func storeRestoresWithoutSignalsAndKeepsKnownSessions() throws {
        let clock = TestClock()
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", session: "known", #"{"prompt":"이미 아는 세션"}"#))
        let signalBefore = store.latestSignal

        let at = clock.now.addingTimeInterval(-60)
        store.restore([
            RestoredSession(
                id: "sess-1", cwd: projectCwd, gitBranch: "main", entrypoint: "claude-desktop",
                state: .runningTool(name: "Bash", input: json(#"{"command":"npm test"}"#), toolUseID: "t1"), lastEventAt: at
            ),
            RestoredSession(id: "sess-2", cwd: otherCwd, state: .runningTool(name: "AskUserQuestion", input: nil, toolUseID: nil), lastEventAt: at),
            RestoredSession(id: "sess-3", cwd: otherCwd, state: .finished, lastEventAt: at),
            RestoredSession(id: "known", cwd: otherCwd, state: .finished, lastEventAt: at),
        ])

        let running = try #require(store.sessions["sess-1"])
        #expect(running.phase == .runningTool)
        #expect(running.projectName == "api-server")
        #expect(running.currentActivity?.id == "t1")
        #expect(running.currentActivity?.label == "Bash")
        #expect(running.lastEventAt == at)
        #expect(running.terminal.isClaudeDesktopApp)
        #expect(try #require(store.sessions["sess-2"]).phase == .waitingInput)
        let finished = try #require(store.sessions["sess-3"])
        #expect(finished.phase == .completed)
        #expect(!finished.hasUnseenCompletion)
        // 이벤트로 이미 아는 세션은 그대로, 알림 신호도 새로 내지 않음
        #expect(try #require(store.sessions["known"]).phase == .thinking)
        #expect(store.latestSignal == signalBefore)

        // 되살린 툴의 PostToolUse 가 오면 그 활동이 끝난다
        store.ingest(hook("PostToolUse", session: "sess-1", #"{"tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"npm test"},"tool_response":{}}"#))
        let after = try #require(store.sessions["sess-1"])
        #expect(after.activities.first { $0.id == "t1" }?.status == .succeeded)
        #expect(after.phase == .thinking)
    }
}
