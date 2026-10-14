import Foundation
import Testing
@testable import NotchCore
import NotchShared

/// 세션 상태 머신 회귀 테스트: 훅 없는 대기의 주인 · 메인 턴 끝 · 서브에이전트 요청 정리 · 백그라운드 서브에이전트 수 ·
/// 끊긴 권한 요청 · 새 턴의 답변 줄 · 줄인 payload 의 diff · 턴 끝에서 닫는 활동 · 완료 소요 시간
@MainActor
@Suite struct SessionStateFixTests {
    let clock = TestClock()
    let questionInput = #"{"questions":[{"question":"어느 DB?","options":[{"label":"Postgres"},{"label":"SQLite"}]}]}"#
    let desktopEnv = ["__CFBundleIdentifier": "com.anthropic.claudefordesktop", "CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]

    /// 툴 이벤트 (agent 가 있으면 그 서브에이전트의 호출)
    private func tool(
        _ event: String,
        _ name: String,
        id: String,
        agent: String? = nil,
        input: String = "{}",
        env: [String: String] = [:]
    ) -> HookEnvelope {
        let agentField = agent.map { #""agent_id":"\#($0)","# } ?? ""
        let response = event == "PostToolUse" ? #","tool_response":{}"# : ""
        return hook(event, #"{\#(agentField)"tool_name":"\#(name)","tool_use_id":"\#(id)","tool_input":\#(input)\#(response)}"#, env: env)
    }

    /// Bash 권한 요청 (PermissionRequest 에는 tool_use_id 가 없다)
    private func permission(agent: String? = nil, command: String = "make", env: [String: String] = [:]) -> HookEnvelope {
        let agentField = agent.map { #""agent_id":"\#($0)","# } ?? ""
        return hook("PermissionRequest", #"{\#(agentField)"tool_name":"Bash","tool_input":{"command":"\#(command)"}}"#, env: env)
    }

    /// 헬퍼가 답을 기다리는 질문 (노치 대기열에 들어간다)
    private func question(_ id: String, agent: String? = nil) -> HookEnvelope {
        var envelope = tool("PreToolUse", "AskUserQuestion", id: id, agent: agent, input: questionInput)
        envelope.expectsReply = true
        return envelope
    }

    private func notification(_ type: String, agent: String? = nil) -> HookEnvelope {
        let agentField = agent.map { #","agent_id":"\#($0)""# } ?? ""
        return hook("Notification", #"{"notification_type":"\#(type)","message":"Claude needs your permission"\#(agentField)}"#)
    }

    private func phase(_ store: SessionStore, _ id: String = "s1") -> SessionPhase? {
        store.sessions[id]?.phase
    }

    // MARK: - 1. 훅 없는 승인 · 입력 대기는 기다리는 에이전트만 끝낸다

    @Test func passedThroughWaitSurvivesOtherAgentsTools() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"병렬로 조사해줘"}"#))
        // sub1 이 Read 와 Bash 를 같이 부르고, Bash 만 권한을 묻는다
        store.ingest(tool("PreToolUse", "Read", id: "sr1", agent: "sub1", input: #"{"file_path":"/Users/dev/projects/api-server/a.ts"}"#))
        store.ingest(tool("PreToolUse", "Bash", id: "sb1", agent: "sub1", input: #"{"command":"make"}"#))
        let id = try #require(store.ingest(permission(agent: "sub1")))
        // "터미널로": 훅은 결정 없이 풀리고 터미널 다이얼로그가 계속 막고 있다
        store.resolvePermission(id: id, decision: .passthrough)
        #expect(phase(store) == .waitingPermission)

        // 병렬로 도는 다른 서브에이전트 · 메인의 툴 진행으로는 승인 대기가 지워지지 않는다
        store.ingest(tool("PreToolUse", "Grep", id: "g1", agent: "sub2", input: #"{"pattern":"x"}"#))
        #expect(phase(store) == .waitingPermission)
        store.ingest(tool("PostToolUse", "Grep", id: "g1", agent: "sub2", input: #"{"pattern":"x"}"#))
        #expect(phase(store) == .waitingPermission)
        // sub1 이 같이 부른 다른 호출의 결과도 기다리던 호출과 무관
        store.ingest(tool("PostToolUse", "Read", id: "sr1", agent: "sub1", input: #"{"file_path":"/Users/dev/projects/api-server/a.ts"}"#))
        #expect(phase(store) == .waitingPermission)

        // 터미널에서 승인돼 그 호출이 끝나면 풀린다
        store.ingest(tool("PostToolUse", "Bash", id: "sb1", agent: "sub1", input: #"{"command":"make"}"#))
        #expect(phase(store) == .thinking)
    }

    @Test func expiredRequestWaitEndsOnOwnersNextTool() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        store.ingest(tool("PreToolUse", "Bash", id: "sb1", agent: "sub1", input: #"{"command":"make"}"#))
        let id = try #require(store.ingest(permission(agent: "sub1")))
        // 노치에서 기다리는 시간이 지남 → Claude Code 다이얼로그가 이어서 뜬다
        store.expirePermission(id: id)
        store.ingest(tool("PreToolUse", "Grep", id: "g1", agent: "sub2", input: #"{"pattern":"x"}"#))
        #expect(phase(store) == .waitingPermission)

        // 터미널에서 거부하면 그 호출의 결과는 오지 않는다: 기다리던 에이전트의 다음 툴 호출로 끝난 것을 안다
        store.ingest(tool("PreToolUse", "Read", id: "sr2", agent: "sub1", input: #"{"file_path":"/Users/dev/projects/api-server/b.ts"}"#))
        #expect(phase(store) == .runningTool)
    }

    @Test func permissionPromptWaitBelongsToItsAgent() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        store.ingest(tool("PreToolUse", "Agent", id: "a1", input: #"{"description":"조사","subagent_type":"Explore"}"#))
        store.ingest(tool("PreToolUse", "Bash", id: "sb1", agent: "sub1", input: #"{"command":"make"}"#))
        // 훅 권한 요청 없이 터미널 다이얼로그 알림만 옴
        store.ingest(notification("permission_prompt", agent: "sub1"))
        #expect(phase(store) == .waitingPermission)
        let seq = store.latestSignal?.seq

        store.ingest(tool("PreToolUse", "Grep", id: "g1", agent: "sub2", input: #"{"pattern":"x"}"#))
        store.ingest(tool("PostToolUse", "Grep", id: "g1", agent: "sub2", input: #"{"pattern":"x"}"#))
        #expect(phase(store) == .waitingPermission)
        #expect(store.latestSignal?.seq == seq)

        // 기다리던 서브에이전트가 끝나면 대기에서 나온다 (메인은 아직 Agent 툴로 다른 서브에이전트를 기다리는 중)
        store.ingest(hook("SubagentStop", #"{"agent_id":"sub1","agent_type":"Explore"}"#))
        let s = try #require(store.sessions["s1"])
        #expect(s.phase == .runningTool)
        #expect(s.currentActivity?.id == "a1")
        #expect(s.activities.first { $0.id == "sb1" }?.status != .running)
    }

    @Test func handedOffQuestionIsNotShownAgainAfterOtherAgentsTools() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        store.ingest(hook("SubagentStart", #"{"agent_id":"sub1","agent_type":"Plan"}"#))
        let id = try #require(store.ingest(question("q1", agent: "sub1")))
        store.handOff(id: id)
        #expect(store.isInputHandedOff("s1"))
        let seq = store.latestSignal?.seq

        // 다른 서브에이전트가 툴을 쓰는 동안에도 넘긴 질문의 입력 대기 · 넘김 표시가 유지된다
        store.ingest(tool("PreToolUse", "Grep", id: "g1", agent: "sub2", input: #"{"pattern":"x"}"#))
        store.ingest(tool("PostToolUse", "Grep", id: "g1", agent: "sub2", input: #"{"pattern":"x"}"#))
        #expect(phase(store) == .waitingInput)
        #expect(store.isInputHandedOff("s1"))

        // 약 6초 뒤 그 다이얼로그의 알림: "승인 필요" 카드를 새로 띄우지 않는다
        store.ingest(notification("permission_prompt"))
        #expect(phase(store) == .waitingInput)
        #expect(store.latestSignal?.seq == seq)
        #expect(store.isInputHandedOff("s1"))

        // 다이얼로그에서 답해 그 호출이 끝나면 평소대로
        store.ingest(tool("PostToolUse", "AskUserQuestion", id: "q1", agent: "sub1", input: questionInput))
        #expect(!store.isInputHandedOff("s1"))
        #expect(phase(store) == .runningTool)
    }

    @Test func backgroundAgentWaitOutlivesMainStop() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"백그라운드로 돌려줘"}"#))
        store.ingest(hook("SubagentStart", #"{"agent_id":"bg1","agent_type":"general-purpose"}"#))
        store.ingest(tool("PreToolUse", "Bash", id: "bb1", agent: "bg1", input: #"{"command":"make"}"#))
        store.ingest(notification("permission_prompt", agent: "bg1"))
        // 메인 에이전트의 툴 진행도 서브에이전트의 대기를 지우지 않는다
        store.ingest(tool("PreToolUse", "Read", id: "r1", input: #"{"file_path":"/Users/dev/projects/api-server/a.ts"}"#))
        store.ingest(tool("PostToolUse", "Read", id: "r1", input: #"{"file_path":"/Users/dev/projects/api-server/a.ts"}"#))
        #expect(phase(store) == .waitingPermission)

        // 메인 턴이 끝나도 백그라운드 서브에이전트의 터미널 다이얼로그는 남아 있다
        store.ingest(hook("Stop", "{}"))
        var s = try #require(store.sessions["s1"])
        #expect(s.phase == .waitingPermission)
        #expect(s.mainTurnEnded)
        #expect(s.hasUnseenCompletion)

        // 승인돼 그 호출이 끝나면 끝난 단계(완료)로 돌아간다 (작업 중 아님)
        store.ingest(tool("PostToolUse", "Bash", id: "bb1", agent: "bg1", input: #"{"command":"make"}"#))
        s = try #require(store.sessions["s1"])
        #expect(s.phase == .completed)
    }

    @Test func mainWaitClearsOnStop() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        store.ingest(tool("PreToolUse", "Bash", id: "b1", input: #"{"command":"rm -rf dist"}"#))
        store.ingest(notification("permission_prompt"))
        // 서브에이전트의 툴 진행으로는 메인의 승인 대기가 지워지지 않는다
        store.ingest(tool("PreToolUse", "Grep", id: "g1", agent: "sub1", input: #"{"pattern":"x"}"#))
        #expect(phase(store) == .waitingPermission)
        // 메인 턴이 끝나면 메인의 대기도 끝난다
        store.ingest(hook("Stop", "{}"))
        #expect(phase(store) == .completed)
    }

    // MARK: - 2. "메인 턴이 끝남" 은 단계가 아니라 따로 기억한다

    @Test func answeringBackgroundRequestsKeepsTurnEnded() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"백그라운드로 돌려줘"}"#))
        store.ingest(hook("SubagentStart", #"{"agent_id":"bg1","agent_type":"general-purpose"}"#))
        store.ingest(hook("Stop", "{}"))
        #expect(phase(store) == .completed)

        // 백그라운드 서브에이전트의 질문에 노치에서 답함: 예전에는 툴 실행 중이 되어 "끝났다" 는 걸 잃었다
        let q = try #require(store.ingest(question("q1", agent: "bg1")))
        #expect(phase(store) == .waitingInput)
        store.resolvePermission(id: q, decision: .answer([QuestionAnswer(labels: ["Postgres"])]))
        var s = try #require(store.sessions["s1"])
        #expect(s.phase == .completed)
        #expect(s.mainTurnEnded)

        // 그 뒤 백그라운드 툴 진행은 여전히 백그라운드
        store.ingest(tool("PostToolUse", "AskUserQuestion", id: "q1", agent: "bg1", input: questionInput))
        store.ingest(tool("PreToolUse", "Read", id: "r1", agent: "bg1", input: #"{"file_path":"/Users/dev/projects/api-server/a.ts"}"#))
        s = try #require(store.sessions["s1"])
        #expect(s.phase == .completed)
        #expect(s.currentActivity == nil)

        // 권한 요청을 거부해도 끝난 단계로
        let denied = try #require(store.ingest(permission(agent: "bg1")))
        #expect(phase(store) == .waitingPermission)
        store.resolvePermission(id: denied, decision: .deny(message: nil))
        #expect(phase(store) == .completed)

        // 완료를 확인한 뒤면 유휴로 돌아간다
        store.markSeen(sessionID: "s1")
        let allowed = try #require(store.ingest(permission(agent: "bg1", command: "make test")))
        store.resolvePermission(id: allowed, decision: .allow)
        #expect(phase(store) == .idle)
        store.ingest(tool("PostToolUse", "Bash", id: "bb2", agent: "bg1", input: #"{"command":"make test"}"#))
        #expect(phase(store) == .idle)

        // 새 프롬프트에서 다시 턴 진행 중
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"다음"}"#))
        #expect(store.sessions["s1"]?.mainTurnEnded == false)
        store.ingest(tool("PreToolUse", "Grep", id: "g2", agent: "bg1", input: #"{"pattern":"x"}"#))
        #expect(phase(store) == .runningTool)
    }

    @Test func restoredFinishedSessionKeepsTurnEnded() throws {
        let store = makeStore(clock)
        store.restore([RestoredSession(id: "s1", cwd: projectCwd, state: .finished, lastEventAt: clock.now)])
        #expect(store.sessions["s1"]?.mainTurnEnded == true)

        store.ingest(tool("PreToolUse", "Read", id: "r1", agent: "bg1", input: #"{"file_path":"/Users/dev/projects/api-server/a.ts"}"#))
        #expect(phase(store) == .completed)
        // 메인 에이전트가 툴을 쓰면(놓친 프롬프트 · Stop 훅이 이어 간 턴) 다시 진행 중
        store.ingest(tool("PreToolUse", "Read", id: "r2", input: #"{"file_path":"/Users/dev/projects/api-server/b.ts"}"#))
        #expect(phase(store) == .runningTool)
        #expect(store.sessions["s1"]?.mainTurnEnded == false)
    }

    // MARK: - 3. 턴 이벤트는 메인 에이전트의 훅 요청만 푼다

    @Test(arguments: [
        ("Stop", "{}"),
        ("StopFailure", #"{"error":"server_error"}"#),
        ("UserPromptSubmit", #"{"prompt":"다른 거 해줘"}"#),
    ])
    func turnEventsReleaseOnlyMainAgentRequests(event: String, fields: String) throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        store.ingest(hook("SubagentStart", #"{"agent_id":"bg1","agent_type":"general-purpose"}"#))
        let sub = try #require(store.ingest(permission(agent: "bg1")))
        store.ingest(tool("PreToolUse", "Bash", id: "b1", input: #"{"command":"rm -rf dist"}"#))
        let main = try #require(store.ingest(permission(command: "rm -rf dist")))

        store.ingest(hook(event, fields))
        #expect(store.pendingPermissions.map(\.id) == [sub])
        #expect(recorder.calls.map { $0.0.id } == [main])
        #expect(recorder.calls.map { $0.1 } == [.passthrough])
        // 아직 기다리는 서브에이전트 요청이 있으니 승인 대기로 보여준다
        #expect(phase(store) == .waitingPermission)

        // 그 서브에이전트가 끝나면 정리
        store.ingest(hook("SubagentStop", #"{"agent_id":"bg1","agent_type":"general-purpose"}"#))
        #expect(store.pendingPermissions.isEmpty)
        #expect(recorder.calls.map { $0.0.id } == [main, sub])
        #expect(phase(store) != .waitingPermission)
    }

    // MARK: - 4. 앱을 새로 띄운 뒤의 백그라운드 서브에이전트 수

    @Test func subagentsSeenOnlyByTheirEventsAreCounted() throws {
        let store = makeStore(clock)
        // 앱을 새로 띄워 SubagentStart 를 놓쳤다
        store.restore([RestoredSession(id: "s1", cwd: projectCwd, state: .finished, lastEventAt: clock.now)])
        store.ingest(tool("PreToolUse", "Read", id: "r1", agent: "bg1", input: #"{"file_path":"/Users/dev/projects/api-server/a.ts"}"#))
        #expect(store.sessions["s1"]?.activeSubagents == 1)
        store.ingest(tool("PostToolUse", "Read", id: "r1", agent: "bg1", input: #"{"file_path":"/Users/dev/projects/api-server/a.ts"}"#))
        #expect(store.sessions["s1"]?.activeSubagents == 1)

        // Claude 앱이 시작 없이 보내는 보조 작업의 종료는 여전히 무시
        store.ingest(hook("SubagentStop", #"{"agent_id":"helper","background_tasks":[]}"#))
        #expect(store.sessions["s1"]?.activeSubagents == 1)
        store.ingest(hook("SubagentStop", #"{"agent_id":"bg1"}"#))
        #expect(store.sessions["s1"]?.activeSubagents == 0)
    }

    @Test func turnEndTasksAreMatchedByLaterEvents() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        // 시작을 못 본 서브에이전트: 턴 끝 목록에서만 안다 ("task:<id>")
        store.ingest(hook("Stop", #"{"background_tasks":[{"id":"bg9","type":"subagent","status":"running"}]}"#))
        #expect(store.sessions["s1"]?.activeSubagents == 1)
        // 그 작업의 SubagentStop 으로 끝난다
        store.ingest(hook("SubagentStop", #"{"agent_id":"bg9"}"#))
        #expect(store.sessions["s1"]?.activeSubagents == 0)

        // 목록으로 알던 작업의 이벤트가 오면 그 ID 로 바꿔 한 번만 센다
        store.ingest(hook("Stop", #"{"background_tasks":[{"id":"bg8","type":"subagent","status":"running"}]}"#))
        store.ingest(tool("PreToolUse", "Grep", id: "g1", agent: "bg8", input: #"{"pattern":"x"}"#))
        #expect(store.sessions["s1"]?.activeSubagents == 1)
        store.ingest(hook("SubagentStop", #"{"agent_id":"bg8"}"#))
        #expect(store.sessions["s1"]?.activeSubagents == 0)
    }

    // MARK: - 5. 훅 연결이 끊긴 권한 요청은 승인 대기에서 나온다

    @Test func clientClosedPermissionLeavesWait() throws {
        // Claude 앱: 앱 자체 다이얼로그에서 답했을 가능성이 크다 → 요청한 툴이 실행 중
        let app = makeStore(clock)
        app.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#, env: desktopEnv))
        app.ingest(tool("PreToolUse", "Bash", id: "b1", input: #"{"command":"make"}"#, env: desktopEnv))
        let appRequest = try #require(app.ingest(permission(env: desktopEnv)))
        app.cancelPermission(id: appRequest)
        #expect(phase(app) == .runningTool)
        #expect(app.sessions["s1"]?.currentActivity?.id == "b1")

        // 터미널: Esc · 중단 → 쉬는 중 (메인 턴도 끝남)
        let cli = makeStore(clock)
        cli.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        cli.ingest(tool("PreToolUse", "Bash", id: "b1", input: #"{"command":"make"}"#))
        let cliRequest = try #require(cli.ingest(permission()))
        cli.cancelPermission(id: cliRequest)
        #expect(phase(cli) == .idle)
        #expect(cli.sessions["s1"]?.mainTurnEnded == true)

        // 메인 답변이 끝난 뒤 백그라운드 서브에이전트의 요청이면 끝난 단계로
        let background = makeStore(clock)
        background.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        background.ingest(hook("SubagentStart", #"{"agent_id":"bg1","agent_type":"general-purpose"}"#))
        background.ingest(hook("Stop", "{}"))
        let bgRequest = try #require(background.ingest(permission(agent: "bg1")))
        #expect(phase(background) == .waitingPermission)
        background.cancelPermission(id: bgRequest)
        #expect(phase(background) == .completed)
    }

    @Test func clientClosedPermissionKeepsOtherWaits() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        // sub2 의 터미널 다이얼로그(훅 대기 없음)가 남아 있다
        store.ingest(tool("PreToolUse", "Bash", id: "sb2", agent: "sub2", input: #"{"command":"make lint"}"#))
        store.ingest(notification("permission_prompt", agent: "sub2"))
        store.ingest(tool("PreToolUse", "Bash", id: "sb1", agent: "sub1", input: #"{"command":"make"}"#))
        let id = try #require(store.ingest(permission(agent: "sub1")))
        store.cancelPermission(id: id)
        #expect(phase(store) == .waitingPermission)
    }

    // MARK: - 6. 새 턴에는 이전 턴의 마지막 답변을 보여주지 않는다

    @Test func newPromptDropsPreviousAnswer() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        store.ingest(hook("Stop", #"{"last_assistant_message":"다 고쳤어."}"#))
        #expect(store.latestTextLine(for: "s1") == "다 고쳤어.")

        store.ingest(hook("UserPromptSubmit", #"{"prompt":"다음"}"#))
        let s = try #require(store.sessions["s1"])
        #expect(s.lastAssistantMessage == nil)
        #expect(store.latestTextLine(for: "s1") == nil)
    }

    // MARK: - 7. 줄인 payload 의 diff

    @Test func shrunkPayloadWithoutPatchCountsOnlyTheFile() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        let seq = store.latestSignal?.seq
        let path = "/Users/dev/projects/api-server/big.json"
        // 큰 파일 덮어쓰기: 헬퍼가 2단계로 줄여 structuredPatch · originalFile 이 빠지고 content 는 잘림
        store.ingest(hook("PostToolUse", #"{"tool_name":"Write","tool_use_id":"w1","tool_input":{"file_path":"\#(path)","content":"a\nb\nc"},"tool_response":{"type":"update","filePath":"\#(path)"},"_agent_notch_truncated":true}"#))
        var s = try #require(store.sessions["s1"])
        #expect(s.turn.changedFiles == [path])
        #expect(s.turn.added == 0)
        #expect(s.turn.removed == 0)
        #expect(s.lastDiff == nil)
        #expect(s.activities.first { $0.id == "w1" }?.diff == nil)
        #expect(store.latestSignal?.seq == seq)

        // structuredPatch 가 남아 있으면(1단계) 그 값은 믿는다
        let other = "/Users/dev/projects/api-server/a.ts"
        store.ingest(hook("PostToolUse", #"{"tool_name":"Edit","tool_use_id":"e1","tool_input":{"file_path":"\#(other)","old_string":"x","new_string":"y"},"tool_response":{"filePath":"\#(other)","structuredPatch":[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":2,"lines":["-old","+new","+more"]}]},"_agent_notch_truncated":true}"#))
        s = try #require(store.sessions["s1"])
        #expect(s.turn.changedFiles == [path, other])
        #expect(s.turn.added == 2)
        #expect(s.turn.removed == 1)
        #expect(s.lastDiff?.filePath == other)
    }

    // MARK: - 8. 턴 끝에서 아직 도는 서브에이전트의 활동은 닫지 않는다

    @Test func turnEndKeepsRunningSubagentActivities() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"백그라운드로 돌려줘"}"#))
        store.ingest(hook("SubagentStart", #"{"agent_id":"bg1","agent_type":"general-purpose"}"#))
        store.ingest(tool("PreToolUse", "Bash", id: "bb1", agent: "bg1", input: #"{"command":"npm test"}"#))
        store.ingest(tool("PreToolUse", "Read", id: "r1", input: #"{"file_path":"/Users/dev/projects/api-server/a.ts"}"#))
        store.ingest(hook("Stop", #"{"background_tasks":[{"id":"bg1","type":"subagent","status":"running"}]}"#))
        var s = try #require(store.sessions["s1"])
        #expect(s.activities.first { $0.id == "bb1" }?.status == .running)
        #expect(s.activities.first { $0.id == "agent:bg1" }?.status == .running)
        #expect(s.activities.first { $0.id == "r1" }?.status == .succeeded)
        #expect(s.activities.first { $0.id == "bb1" }?.agentID == "bg1")

        // 다음 프롬프트도 도는 서브에이전트의 활동은 실패로 닫지 않는다
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"그동안 다른 거"}"#))
        s = try #require(store.sessions["s1"])
        #expect(s.activities.first { $0.id == "bb1" }?.status == .running)

        // 그 서브에이전트가 끝나면 닫힌다
        store.ingest(hook("SubagentStop", #"{"agent_id":"bg1","agent_type":"general-purpose"}"#))
        s = try #require(store.sessions["s1"])
        #expect(s.activities.first { $0.id == "bb1" }?.status == .succeeded)
        #expect(s.activities.first { $0.id == "agent:bg1" }?.status == .succeeded)
    }

    // MARK: - 9. 완료 소요 시간은 턴이 끝난 시각까지

    @Test func completionDurationStopsAtTurnEnd() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        clock.advance(42)
        store.ingest(hook("Stop", "{}"))
        var s = try #require(store.sessions["s1"])
        #expect(s.turn.endedAt == clock.now)
        #expect(s.turnDuration == 42)

        // 그 뒤 이벤트(idle_prompt · 시작 없는 SubagentStop · 백그라운드 작업)로 늘지 않는다
        clock.advance(120)
        store.ingest(hook("Notification", #"{"notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#))
        store.ingest(hook("SubagentStop", #"{"agent_id":"helper"}"#))
        store.ingest(tool("PreToolUse", "Read", id: "r1", agent: "bg1", input: #"{"file_path":"/Users/dev/projects/api-server/a.ts"}"#))
        s = try #require(store.sessions["s1"])
        #expect(s.lastEventAt == clock.now)
        #expect(s.turnDuration == 42)

        // 실패한 턴도 같다
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"다음"}"#))
        #expect(store.sessions["s1"]?.turn.endedAt == nil)
        clock.advance(7)
        store.ingest(hook("StopFailure", #"{"error":"rate_limit"}"#))
        clock.advance(30)
        store.ingest(hook("Notification", #"{"notification_type":"idle_prompt","message":"waiting"}"#))
        #expect(store.sessions["s1"]?.turnDuration == 7)

        // 되살린 끝난 세션은 턴 시작을 몰라 소요 시간을 지어내지 않는다
        store.restore([RestoredSession(id: "old", cwd: otherCwd, state: .finished, lastEventAt: clock.now)])
        let restored = try #require(store.sessions["old"])
        #expect(restored.turn.endedAt == clock.now)
        #expect(restored.turnDuration == nil)
    }
}
