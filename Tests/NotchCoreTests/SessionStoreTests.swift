import Foundation
import Testing
@testable import NotchCore
import NotchShared

@MainActor
@Suite struct SessionStoreTests {
    let clock = TestClock()

    @Test func basicTurnFlow() throws {
        let store = makeStore(clock)

        store.ingest(hook("SessionStart", #"{"source":"startup","model":"claude-opus-5"}"#, env: ["TERM_PROGRAM": "iTerm.app"]))
        var s = try #require(store.sessions["s1"])
        #expect(s.phase == .idle)
        #expect(s.projectName == "api-server")
        #expect(s.model == "claude-opus-5")
        #expect(s.terminal.termProgram == "iTerm.app")
        #expect(store.latestSignal?.signal == .sessionStarted(sessionID: "s1"))
        #expect(store.focusedSessionID == "s1")

        clock.advance()
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"  세션 만료   시간을\n환경변수로 빼줘 "}"#))
        s = try #require(store.sessions["s1"])
        #expect(s.phase == .thinking)
        #expect(s.lastPrompt == "세션 만료 시간을 환경변수로 빼줘")
        #expect(s.turnStartedAt == clock.now)
        #expect(s.turn.startedAt == clock.now)
        #expect(s.activities.last?.kind == .prompt)

        clock.advance()
        let editInput = #""tool_input":{"file_path":"/Users/dev/projects/api-server/src/auth/session.ts","old_string":"const ttl = 3600","new_string":"const ttl = env.SESSION_TTL ?? 3600\nif (!token) return null"}"#
        store.ingest(hook("PreToolUse", #"{"tool_name":"Edit","tool_use_id":"toolu_1","#  + editInput + "}"))
        s = try #require(store.sessions["s1"])
        #expect(s.phase == .runningTool)
        #expect(s.currentActivity?.id == "toolu_1")
        #expect(s.currentActivity?.title == "Edit session.ts")
        #expect(s.currentActivity?.detail == "src/auth/session.ts")
        #expect(s.currentActivity?.label == "Edit")
        #expect(s.currentActivity?.status == .running)
        #expect(s.turn.toolCount == 1)

        clock.advance()
        store.ingest(hook("PostToolUse", #"{"tool_name":"Edit","tool_use_id":"toolu_1","tool_response":{},"# + editInput + "}"))
        s = try #require(store.sessions["s1"])
        #expect(s.phase == .thinking)
        #expect(s.currentActivity == nil)
        let activity = try #require(s.activities.first { $0.id == "toolu_1" })
        #expect(activity.status == .succeeded)
        #expect(activity.endedAt == clock.now)
        #expect(activity.diff?.added == 2)
        #expect(activity.diff?.removed == 1)
        #expect(s.lastDiff?.fileName == "session.ts")
        #expect(s.turn.changedFiles == ["/Users/dev/projects/api-server/src/auth/session.ts"])
        #expect(s.turn.added == 2)
        #expect(s.turn.removed == 1)
        guard case .edited(let sessionID, let diff)? = store.latestSignal?.signal else {
            Issue.record("edited 신호가 없음")
            return
        }
        #expect(sessionID == "s1")
        #expect(diff.lines.map(\.kind) == [.removed, .added, .added])

        clock.advance()
        store.ingest(hook("Stop", #"{"last_assistant_message":"세션 TTL 분리했어.\n테스트 통과."}"#))
        s = try #require(store.sessions["s1"])
        #expect(s.phase == .completed)
        #expect(s.hasUnseenCompletion)
        #expect(s.lastAssistantMessage == "세션 TTL 분리했어.\n테스트 통과.")
        #expect(s.latestTextLine == "테스트 통과.")
        #expect(store.latestSignal?.signal == .completed(sessionID: "s1"))
    }

    @Test func lazySessionCreation() throws {
        let store = makeStore(clock)
        store.ingest(hook("PreToolUse", session: "late", cwd: "/Users/dev/projects/blog/", #"{"tool_name":"Read","tool_use_id":"t1","tool_input":{"file_path":"/Users/dev/projects/blog/README.md"}}"#))
        let s = try #require(store.sessions["late"])
        #expect(s.projectName == "blog")
        #expect(s.phase == .runningTool)
        #expect(s.currentActivity?.title == "Read README.md")

        store.ingest(hook("Notification", session: "nocwd", cwd: nil, #"{"notification_type":"idle_prompt","message":"waiting"}"#))
        let unknown = try #require(store.sessions["nocwd"])
        #expect(unknown.projectName == "unknown")
        #expect(unknown.lastNotification == "waiting")

        // session_id 가 없으면 무시
        let noID = HookEnvelope(event: "Stop", sentAt: 0, env: [:], expectsReply: false, payload: json(#"{"hook_event_name":"Stop"}"#))
        #expect(store.ingest(noID) == nil)
        #expect(store.sessions.count == 2)
    }

    @Test func lastEventAtAndCommonFields() throws {
        let store = makeStore(clock)
        store.ingest(hook("SessionStart"))
        clock.advance(30)
        store.ingest(hook("Notification", #"{"notification_type":"auth_success","permission_mode":"plan","transcript_path":"/Users/dev/.claude/projects/x.jsonl"}"#))
        let s = try #require(store.sessions["s1"])
        #expect(s.lastEventAt == clock.now)
        #expect(s.permissionMode == "plan")
        #expect(s.transcriptPath == "/Users/dev/.claude/projects/x.jsonl")
        #expect(s.phase == .idle)
    }

    @Test func askUserQuestionNeedsInput() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        store.ingest(hook("PreToolUse", #"{"tool_name":"AskUserQuestion","tool_use_id":"q1","tool_input":{"questions":[{"question":"어떤 DB 를 쓸까?","header":"DB"}]}}"#))
        #expect(store.sessions["s1"]?.phase == .waitingInput)
        #expect(store.latestSignal?.signal == .needsInput(sessionID: "s1", message: "어떤 DB 를 쓸까?"))

        store.ingest(hook("PostToolUse", #"{"tool_name":"AskUserQuestion","tool_use_id":"q1","tool_response":{}}"#))
        #expect(store.sessions["s1"]?.phase == .thinking)

        store.ingest(hook("PreToolUse", #"{"tool_name":"AskUserQuestion","tool_use_id":"q2","tool_input":{}}"#))
        #expect(store.latestSignal?.signal == .needsInput(sessionID: "s1", message: "질문에 답변 필요"))

        store.ingest(hook("PreToolUse", ##"{"tool_name":"ExitPlanMode","tool_use_id":"p1","tool_input":{"plan":"# 계획\n1. 테스트"}}"##))
        #expect(store.sessions["s1"]?.phase == .waitingInput)
        #expect(store.latestSignal?.signal == .needsInput(sessionID: "s1", message: "계획 승인 필요"))
    }

    @Test func postToolUseWithoutPreCreatesActivity() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        let before = store.latestSignal?.seq
        store.ingest(hook("PostToolUse", #"{"tool_name":"Read","tool_use_id":"r1","tool_input":{"file_path":"/Users/dev/projects/api-server/a.ts"},"tool_response":{}}"#))
        let s = try #require(store.sessions["s1"])
        let item = try #require(s.activities.last)
        #expect(item.id == "r1")
        #expect(item.status == .succeeded)
        #expect(item.title == "Read a.ts")
        #expect(s.turn.toolCount == 1)
        // diff 가 없으면 edited 신호 없음
        #expect(store.latestSignal?.seq == before)
        #expect(s.phase == .thinking)
    }

    @Test func parallelToolKeepsRunningActivity() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        clock.advance()
        store.ingest(hook("PreToolUse", #"{"tool_name":"Agent","tool_use_id":"a1","tool_input":{"description":"코드 탐색","subagent_type":"Explore"}}"#))
        clock.advance()
        store.ingest(hook("PreToolUse", #"{"tool_name":"Grep","tool_use_id":"g1","agent_id":"sub1","tool_input":{"pattern":"TODO"}}"#))
        clock.advance()
        store.ingest(hook("PostToolUse", #"{"tool_name":"Grep","tool_use_id":"g1","agent_id":"sub1","tool_response":{}}"#))
        let s = try #require(store.sessions["s1"])
        #expect(s.phase == .runningTool)
        #expect(s.currentActivity?.id == "a1")
        #expect(s.currentActivity?.title == "Agent 코드 탐색")
    }

    @Test func postToolUseFailureAndInterrupt() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        store.ingest(hook("PreToolUse", #"{"tool_name":"Bash","tool_use_id":"b1","tool_input":{"command":"npm test"}}"#))
        store.ingest(hook("PostToolUseFailure", #"{"tool_name":"Bash","tool_use_id":"b1","error":"Exit code 1"}"#))
        var s = try #require(store.sessions["s1"])
        #expect(s.activities.last?.status == .failed)
        #expect(s.phase == .thinking)
        #expect(s.errorMessage == nil)

        store.ingest(hook("PreToolUse", #"{"tool_name":"Bash","tool_use_id":"b2","tool_input":{"command":"sleep 100"}}"#))
        store.ingest(hook("PostToolUseFailure", #"{"tool_name":"Bash","tool_use_id":"b2","error":"Interrupted","is_interrupt":true}"#))
        s = try #require(store.sessions["s1"])
        #expect(s.phase == .idle)
        #expect(s.currentActivity == nil)
        #expect(s.errorMessage == nil)
        #expect(!s.activities.contains { $0.status == .running })
    }

    @Test func notificationHandling() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        store.ingest(hook("Notification", #"{"notification_type":"elicitation_dialog","message":"MCP 서버가 입력을 요청함"}"#))
        #expect(store.sessions["s1"]?.phase == .waitingInput)
        #expect(store.sessions["s1"]?.lastNotification == "MCP 서버가 입력을 요청함")
        #expect(store.latestSignal?.signal == .needsInput(sessionID: "s1", message: "MCP 서버가 입력을 요청함"))

        store.ingest(hook("Notification", #"{"notification_type":"elicitation_complete","message":"done"}"#))
        #expect(store.sessions["s1"]?.phase == .thinking)

        // 훅 대기 요청이 없는 permission_prompt → 터미널 승인 대기
        store.ingest(hook("Notification", #"{"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}"#))
        #expect(store.sessions["s1"]?.phase == .waitingPermission)
        #expect(store.latestSignal?.signal == .needsInput(sessionID: "s1", message: "Claude needs your permission to use Bash"))

        // 완료 후 idle_prompt 는 phase 를 바꾸지 않는다
        store.ingest(hook("Stop", "{}"))
        store.ingest(hook("Notification", #"{"notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#))
        #expect(store.sessions["s1"]?.phase == .completed)

        // 작업 중으로 남아 있는데 idle_prompt 가 오면 놓친 종료로 보고 idle
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"again"}"#))
        store.ingest(hook("Notification", #"{"notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#))
        #expect(store.sessions["s1"]?.phase == .idle)
    }

    @Test func messageDisplayStreaming() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        store.ingest(hook("MessageDisplay", #"{"index":0,"final":false,"delta":"첫 줄\n"}"#))
        store.ingest(hook("MessageDisplay", #"{"index":1,"final":true,"delta":"둘째 줄"}"#))
        #expect(store.sessions["s1"]?.streamingText == "첫 줄\n둘째 줄")
        // 새 메시지(index 0)는 줄바꿈으로 구분
        store.ingest(hook("MessageDisplay", #"{"index":0,"final":true,"delta":"다음 메시지"}"#))
        #expect(store.sessions["s1"]?.streamingText == "첫 줄\n둘째 줄\n다음 메시지")
        #expect(store.sessions["s1"]?.latestTextLine == "다음 메시지")

        // 최근 2000자만 유지
        let long = String(repeating: "가", count: 2_500) + "끝"
        let payload = JSONValue.object(["index": .number(1), "delta": .string(long)])
        store.ingest(hook("MessageDisplay", String(decoding: try payload.serialized(), as: UTF8.self)))
        let text = try #require(store.sessions["s1"]?.streamingText)
        #expect(text.count == AgentSession.maxStreamingCharacters)
        #expect(text.hasSuffix("가끝"))

        // 새 프롬프트에서 초기화
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"next"}"#))
        #expect(store.sessions["s1"]?.streamingText == "")
    }

    @Test func userPromptResetsTurn() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"first"}"#))
        store.ingest(hook("PostToolUse", #"{"tool_name":"Write","tool_use_id":"w1","tool_input":{"file_path":"/Users/dev/projects/api-server/a.txt","content":"x\ny"},"tool_response":{"type":"create"}}"#))
        store.ingest(hook("StopFailure", #"{"error":"rate_limit"}"#))
        var s = try #require(store.sessions["s1"])
        #expect(s.turn.added == 2)
        #expect(s.errorMessage == "사용량 한도 초과")

        clock.advance(5)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"<pasted_content id=\"1\">secret code</pasted_content> 이거 고쳐줘"}"#))
        s = try #require(store.sessions["s1"])
        #expect(s.phase == .thinking)
        #expect(s.turn == TurnSummary(startedAt: clock.now))
        #expect(s.errorMessage == nil)
        #expect(!s.hasUnseenCompletion)
        #expect(s.lastPrompt == "[붙여넣음] 이거 고쳐줘")
        #expect(s.lastDiff != nil)
    }

    @Test func stopFailure() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        store.ingest(hook("PreToolUse", #"{"tool_name":"Bash","tool_use_id":"b1","tool_input":{"command":"ls"}}"#))
        store.ingest(hook("StopFailure", #"{"error":"server_error","error_details":"500 Internal Server Error"}"#))
        let s = try #require(store.sessions["s1"])
        #expect(s.phase == .failed)
        #expect(s.errorMessage == "500 Internal Server Error")
        #expect(s.currentActivity == nil)
        #expect(s.activities.last?.status == .failed)
        #expect(store.latestSignal?.signal == .failed(sessionID: "s1"))
    }

    @Test func subagents() throws {
        let store = makeStore(clock)
        store.ingest(hook("SubagentStart", #"{"agent_id":"a1","agent_type":"Explore"}"#))
        store.ingest(hook("SubagentStart", #"{"agent_id":"a2","agent_type":"Plan"}"#))
        var s = try #require(store.sessions["s1"])
        #expect(s.activeSubagents == 2)
        #expect(s.activities.map(\.title) == ["Agent Explore", "Agent Plan"])
        #expect(s.activities.allSatisfy { $0.kind == .subagent && $0.status == .running })

        store.ingest(hook("SubagentStop", #"{"agent_id":"a1","agent_type":"Explore"}"#))
        store.ingest(hook("SubagentStop", #"{"agent_id":"a2","agent_type":"Plan"}"#))
        store.ingest(hook("SubagentStop", #"{"agent_id":"a3","agent_type":"Other"}"#))
        s = try #require(store.sessions["s1"])
        #expect(s.activeSubagents == 0)
        // 시작을 못 본 a3 의 종료는 무시 (가짜 "Agent" 항목을 붙이지 않음)
        #expect(s.activities.count == 2)
        #expect(s.activities.allSatisfy { $0.status == .succeeded })
    }

    /// Claude 앱이 턴 끝마다 돌리는 내부 보조 작업처럼 시작 없이 오는 SubagentStop 은
    /// 백그라운드 서브에이전트 수 · 셸 수 · 타임라인을 건드리지 않는다
    @Test func unmatchedSubagentStopIsIgnored() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"백그라운드로 돌려줘"}"#))
        store.ingest(hook("SubagentStart", #"{"agent_id":"bg1","agent_type":"general-purpose"}"#))
        store.ingest(hook("PostToolUse", #"{"tool_name":"Bash","tool_use_id":"b1","tool_input":{"command":"log stream","run_in_background":true},"tool_response":{}}"#))
        store.ingest(hook("Stop", #"{"background_tasks":[{"id":"bg1","type":"subagent","status":"running"},{"id":"sh1","type":"shell","status":"running"}]}"#))
        var s = try #require(store.sessions["s1"])
        #expect(s.activeSubagents == 1)
        #expect(s.backgroundShells == 1)
        let activityCount = s.activities.count

        store.ingest(hook("SubagentStop", #"{"background_tasks":[]}"#))
        store.ingest(hook("SubagentStop", #"{"agent_id":"helper","background_tasks":[]}"#))
        s = try #require(store.sessions["s1"])
        #expect(s.activeSubagents == 1)
        #expect(s.backgroundShells == 1)
        #expect(s.backgroundTaskCount == 2)
        #expect(s.activities.count == activityCount)

        // 시작을 본 서브에이전트(턴 끝 목록 ID 와 같음)의 종료는 센다
        store.ingest(hook("SubagentStop", #"{"agent_id":"bg1","background_tasks":[{"id":"sh1","type":"shell","status":"running"}]}"#))
        s = try #require(store.sessions["s1"])
        #expect(s.activeSubagents == 0)
        #expect(s.backgroundShells == 1)
    }

    /// 메인 답변이 끝난 뒤 백그라운드 서브에이전트의 툴 호출은 타임라인에만 쌓이고 세션 단계는 그대로
    @Test func backgroundSubagentToolsKeepSettledPhase() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"백그라운드로 돌려줘"}"#))
        store.ingest(hook("SubagentStart", #"{"agent_id":"bg1","agent_type":"general-purpose"}"#))
        store.ingest(hook("Stop", #"{}"#))
        var s = try #require(store.sessions["s1"])
        #expect(s.phase == .completed)

        store.ingest(hook("PreToolUse", #"{"agent_id":"bg1","tool_name":"Read","tool_use_id":"r1","tool_input":{"file_path":"/Users/dev/projects/api-server/a.swift"}}"#))
        s = try #require(store.sessions["s1"])
        #expect(s.phase == .completed)
        #expect(s.currentActivity == nil)
        #expect(s.activities.last?.id == "r1")
        #expect(s.activities.last?.status == .running)

        store.ingest(hook("PostToolUse", #"{"agent_id":"bg1","tool_name":"Read","tool_use_id":"r1","tool_input":{"file_path":"/Users/dev/projects/api-server/a.swift"},"tool_response":{}}"#))
        s = try #require(store.sessions["s1"])
        #expect(s.phase == .completed)
        #expect(s.activities.last?.status == .succeeded)
        #expect(SessionStatusSummary.group(for: s) == .working)

        // 사용자가 봐야 하는 단계(질문)는 그대로 반영
        store.ingest(hook("PreToolUse", #"{"agent_id":"bg1","tool_name":"AskUserQuestion","tool_use_id":"q1","tool_input":{"questions":[]}}"#))
        #expect(try #require(store.sessions["s1"]).phase == .waitingInput)

        // 메인 에이전트의 툴은 예전처럼 단계를 바꾼다
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"다음"}"#))
        store.ingest(hook("PreToolUse", #"{"tool_name":"Read","tool_use_id":"r2","tool_input":{"file_path":"/Users/dev/projects/api-server/b.swift"}}"#))
        #expect(try #require(store.sessions["s1"]).phase == .runningTool)
    }

    @Test func backgroundTasksCountedAndReconciled() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"테스트 돌려줘"}"#))
        // 백그라운드 셸 2개 (하나는 서브에이전트 안에서) · 일반 Bash · 모니터 · 서브에이전트
        let background = #""tool_input":{"command":"npm run dev","run_in_background":true},"tool_response":{}"#
        store.ingest(hook("PostToolUse", #"{"tool_name":"Bash","tool_use_id":"b1","# + background + "}"))
        store.ingest(hook("PostToolUse", #"{"tool_name":"Bash","tool_use_id":"b2","agent_id":"a1","# + background + "}"))
        store.ingest(hook("PostToolUse", #"{"tool_name":"Bash","tool_use_id":"b3","tool_input":{"command":"ls"},"tool_response":{}}"#))
        store.ingest(hook("PostToolUse", #"{"tool_name":"Monitor","tool_use_id":"m1","tool_input":{},"tool_response":{}}"#))
        store.ingest(hook("SubagentStart", #"{"agent_id":"a1","agent_type":"Explore"}"#))
        var s = try #require(store.sessions["s1"])
        #expect(s.backgroundShells == 2)
        #expect(s.backgroundOthers == 1)
        #expect(s.activeSubagents == 1)
        #expect(s.backgroundTaskCount == 4)

        // SubagentStop: 셸 · 기타만 목록으로 맞추고, 서브에이전트 수는 이벤트로만 줄인다 (목록에 끝나는 자신이 남아 있을 수 있음)
        store.ingest(hook("SubagentStop", #"{"agent_id":"a1","agent_type":"Explore","background_tasks":[{"type":"shell","status":"running"},{"type":"subagent","status":"running"}]}"#))
        s = try #require(store.sessions["s1"])
        #expect(s.backgroundShells == 1)
        #expect(s.backgroundOthers == 0)
        #expect(s.activeSubagents == 0)

        // Stop: 끝난 상태로 남은 항목은 빼고 종류별로 다시 센다
        store.ingest(hook("Stop", #"{"background_tasks":[{"type":"shell","status":"running"},{"type":"shell","status":"completed"},{"type":"subagent","status":"running"},{"type":"monitor","status":"running"},{"type":"MCP task","status":"pending"}]}"#))
        s = try #require(store.sessions["s1"])
        #expect(s.backgroundShells == 1)
        #expect(s.activeSubagents == 1)
        #expect(s.backgroundOthers == 2)
        #expect(s.backgroundTaskCount == 4)

        // 목록이 없으면(작업 목록을 못 읽음) 그대로, 빈 목록이면 모두 0
        store.ingest(hook("Stop", #"{}"#))
        #expect(try #require(store.sessions["s1"]).backgroundTaskCount == 4)
        store.ingest(hook("Stop", #"{"background_tasks":[]}"#))
        #expect(try #require(store.sessions["s1"]).backgroundTaskCount == 0)
    }

    @Test func compaction() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        store.ingest(hook("PreCompact", #"{"trigger":"auto"}"#))
        #expect(store.sessions["s1"]?.phase == .compacting)
        #expect(store.sessions["s1"]?.activities.last?.kind == .compaction)
        // 압축 후 SessionStart(source: compact) 는 진행 중인 턴을 건드리지 않는다
        store.ingest(hook("SessionStart", #"{"source":"compact"}"#))
        #expect(store.sessions["s1"]?.phase == .compacting)
        store.ingest(hook("PostCompact", #"{"trigger":"auto","compact_summary":"..."}"#))
        #expect(store.sessions["s1"]?.phase == .thinking)
        #expect(store.sessions["s1"]?.activities.last?.status == .succeeded)

        store.ingest(hook("Stop", "{}"))
        store.ingest(hook("PreCompact", #"{"trigger":"manual"}"#))
        store.ingest(hook("PostCompact", #"{"trigger":"manual"}"#))
        #expect(store.sessions["s1"]?.phase == .completed)
    }

    @Test func sessionEndRemovesSession() {
        let store = makeStore(clock)
        store.ingest(hook("SessionStart", "{}"))
        store.ingest(hook("SessionStart", session: "s2", cwd: otherCwd, "{}"))
        store.ingest(hook("SessionEnd", #"{"reason":"prompt_input_exit"}"#))
        #expect(store.sessions["s1"] == nil)
        #expect(store.rankedSessions.map(\.id) == ["s2"])
        #expect(store.focusedSessionID == "s2")
        // 모르는 세션의 SessionEnd 로 세션을 만들지 않음
        store.ingest(hook("SessionEnd", session: "ghost", "{}"))
        #expect(store.sessions["ghost"] == nil)
    }

    @Test func activitiesAreCapped() throws {
        let store = makeStore(clock)
        for index in 0..<50 {
            store.ingest(hook("PreToolUse", #"{"tool_name":"Read","tool_use_id":"t\#(index)","tool_input":{"file_path":"/Users/dev/projects/api-server/f\#(index).ts"}}"#))
        }
        let s = try #require(store.sessions["s1"])
        #expect(s.activities.count == AgentSession.maxActivities)
        #expect(s.activities.first?.id == "t10")
        #expect(s.activities.last?.id == "t49")
        #expect(s.turn.toolCount == 50)
    }

    @Test func markSeenDismissPrune() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        store.ingest(hook("Stop", "{}"))
        store.markSeen(sessionID: "s1")
        #expect(store.sessions["s1"]?.hasUnseenCompletion == false)
        #expect(store.sessions["s1"]?.phase == .idle)

        store.ingest(hook("SessionStart", session: "s2", cwd: otherCwd, "{}"))
        store.dismiss(sessionID: "s2")
        #expect(store.sessions["s2"] == nil)

        // 오래된 세션 정리 (권한 대기 중인 세션은 유지)
        store.ingest(hook("SessionStart", session: "s3", cwd: otherCwd, "{}"))
        store.ingest(hook("PermissionRequest", session: "s3", cwd: otherCwd, #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#))
        clock.advance(3_600)
        store.ingest(hook("SessionStart", session: "fresh", cwd: otherCwd, "{}"))
        store.pruneStaleSessions(olderThan: 600)
        #expect(Set(store.sessions.keys) == ["s3", "fresh"])
    }

    @Test func signalSequenceIncreases() throws {
        let store = makeStore(clock)
        store.ingest(hook("SessionStart", "{}"))
        let first = try #require(store.latestSignal)
        clock.advance()
        store.ingest(hook("SessionStart", "{}"))
        let second = try #require(store.latestSignal)
        #expect(second.seq > first.seq)
        #expect(second.signal == first.signal)
        #expect(second.at == clock.now)
    }
}
