import Foundation
import Testing
@testable import NotchCore
import NotchShared

/// 보이는 단계는 대기 목록과 메인 턴 단계로 한 곳(`finalize`)에서 정한다:
/// 승인 대기 > 입력 대기 > Claude 앱 확인 추정(턴 진행 중) > 메인 턴 단계 (끝난 턴이면 끝난 단계)
@MainActor
@Suite struct PhaseModelTests {
    let clock = TestClock()
    let questionInput = #"{"questions":[{"question":"어느 DB?","options":[{"label":"Postgres"},{"label":"SQLite"}]}]}"#
    let desktopEnv = ["__CFBundleIdentifier": "com.anthropic.claudefordesktop", "CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]

    private func tool(
        _ event: String, _ name: String, id: String, agent: String? = nil, input: String = "{}", env: [String: String] = [:]
    ) -> HookEnvelope {
        let agentField = agent.map { #""agent_id":"\#($0)","# } ?? ""
        let response = event == "PostToolUse" ? #","tool_response":{}"# : ""
        return hook(event, #"{\#(agentField)"tool_name":"\#(name)","tool_use_id":"\#(id)","tool_input":\#(input)\#(response)}"#, env: env)
    }

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

    private func phase(_ store: SessionStore, _ id: String = "s1") -> SessionPhase? {
        store.sessions[id]?.phase
    }

    // MARK: - 대기 사이의 우선순위

    /// 승인 대기와 입력 대기가 함께 있으면 어느 쪽이 나중에 왔든 승인 대기 (예전에는 나중에 온 질문이 승인 대기를 가렸다)
    @Test func permissionWaitOutranksLaterQuestion() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        store.ingest(tool("PreToolUse", "Bash", id: "sb1", agent: "sub1", input: #"{"command":"make"}"#))
        let request = try #require(store.ingest(permission(agent: "sub1")))
        let asked = try #require(store.ingest(question("q1")))
        #expect(phase(store) == .waitingPermission)
        // 질문 카드 신호는 그대로 낸다
        #expect(store.latestSignal?.signal == .needsInput(sessionID: "s1", message: "어느 DB?"))

        store.resolvePermission(id: request, decision: .allow)
        #expect(phase(store) == .waitingInput)
        store.resolvePermission(id: asked, decision: .answer([QuestionAnswer(labels: ["Postgres"])]))
        #expect(phase(store) == .runningTool)
    }

    /// 훅 요청 하나가 끊겨도 남은 대기로 단계를 다시 정한다 (예전에는 다른 요청이 남아 있으면 끊긴 요청의 단계가 그대로 남았다)
    @Test func cancelRecomputesFromRemainingWaits() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        let asked = try #require(store.ingest(question("q1", agent: "sub2")))
        store.ingest(tool("PreToolUse", "Bash", id: "sb1", agent: "sub1", input: #"{"command":"make"}"#))
        let request = try #require(store.ingest(permission(agent: "sub1")))
        #expect(phase(store) == .waitingPermission)

        store.cancelPermission(id: request)
        #expect(store.pendingPermissions.map(\.id) == [asked])
        #expect(phase(store) == .waitingInput)
    }

    // MARK: - 압축

    /// 압축 중에도 남은 대기를 보여준다 (예전에는 PreCompact 가 대기를 "압축 중" 으로 가렸다). 압축이 끝나면 메인 턴 단계로 돌아간다
    @Test func waitsShowDuringCompaction() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        store.ingest(tool("PreToolUse", "Bash", id: "sb1", agent: "sub1", input: #"{"command":"make"}"#))
        store.ingest(hook("Notification", #"{"notification_type":"permission_prompt","message":"needs permission","agent_id":"sub1"}"#))
        store.ingest(hook("PreCompact", #"{"trigger":"auto"}"#))
        #expect(phase(store) == .waitingPermission)
        #expect(store.sessions["s1"]?.mainPhase == .compacting)

        store.ingest(hook("PostCompact", #"{"trigger":"auto"}"#))
        #expect(phase(store) == .waitingPermission)
        #expect(store.sessions["s1"]?.mainPhase == .runningTool)
        store.ingest(tool("PostToolUse", "Bash", id: "sb1", agent: "sub1", input: #"{"command":"make"}"#))
        #expect(phase(store) == .thinking)
    }

    /// 끝난 턴의 수동 압축 중 백그라운드 서브에이전트가 툴을 써도 압축 중으로 남는다 (예전에는 그 툴 이벤트에 끝난 단계로 바뀌었다)
    @Test func backgroundToolKeepsManualCompaction() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"백그라운드로 돌려줘"}"#))
        store.ingest(hook("SubagentStart", #"{"agent_id":"bg1","agent_type":"general-purpose"}"#))
        store.ingest(hook("Stop", "{}"))
        store.ingest(hook("PreCompact", #"{"trigger":"manual"}"#))
        #expect(phase(store) == .compacting)

        store.ingest(tool("PreToolUse", "Read", id: "r1", agent: "bg1", input: #"{"file_path":"/Users/dev/projects/api-server/a.ts"}"#))
        store.ingest(tool("PostToolUse", "Read", id: "r1", agent: "bg1", input: #"{"file_path":"/Users/dev/projects/api-server/a.ts"}"#))
        #expect(phase(store) == .compacting)
        store.ingest(hook("PostCompact", #"{"trigger":"manual"}"#))
        #expect(phase(store) == .completed)
    }

    // MARK: - 메인 턴 단계

    /// 서브에이전트 이벤트 · 결정은 끝난 턴의 단계를 바꾸지 않는다 (메인 턴 단계는 끝난 단계로 남는다)
    @Test func backgroundAnswersKeepSettledMainPhase() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        store.ingest(hook("SubagentStart", #"{"agent_id":"bg1","agent_type":"general-purpose"}"#))
        store.ingest(hook("Stop", "{}"))
        let asked = try #require(store.ingest(question("q1", agent: "bg1")))
        #expect(store.sessions["s1"]?.mainPhase == .completed)
        store.resolvePermission(id: asked, decision: .answer([QuestionAnswer(labels: ["SQLite"])]))
        store.ingest(tool("PostToolUse", "AskUserQuestion", id: "q1", agent: "bg1", input: questionInput))
        let s = try #require(store.sessions["s1"])
        #expect(s.mainPhase == .completed)
        #expect(s.phase == .completed)

        // 대기 중에 완료를 확인했으면 대기가 풀린 뒤 유휴
        let request = try #require(store.ingest(permission(agent: "bg1")))
        store.markSeen(sessionID: "s1")
        #expect(phase(store) == .waitingPermission)
        store.resolvePermission(id: request, decision: .allow)
        #expect(phase(store) == .idle)
    }

    // MARK: - 넘긴 질문

    /// "터미널로" 넘긴 표시는 넘긴 그 질문의 대기에 붙는다: 그 질문이 끝나면 다른 질문 다이얼로그의 입력 대기 카드는 다시 보인다
    /// (예전에는 다른 입력 대기가 남아 있는 동안 세션 전체에 남아 그 카드까지 가렸다)
    @Test func handOffBelongsToItsQuestion() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        let other = try #require(store.ingest(question("q2", agent: "sub1")))
        let mine = try #require(store.ingest(question("q1")))
        store.handOff(id: mine)
        #expect(store.isInputHandedOff("s1"))
        // sub1 의 질문은 노치에서 기다리는 시간이 지나 다이얼로그로 넘어갔다 (넘긴 게 아니다)
        store.expirePermission(id: other)
        #expect(store.isInputHandedOff("s1"))

        // 넘긴 질문에 다이얼로그에서 답함 → 남은 sub1 의 다이얼로그는 입력 대기 카드로 알린다
        store.ingest(tool("PostToolUse", "AskUserQuestion", id: "q1", input: questionInput))
        #expect(!store.isInputHandedOff("s1"))
        #expect(phase(store) == .waitingInput)
    }

    // MARK: - Claude 앱 확인 추정

    /// 확인 대기로 알린 툴이 서브에이전트 종료로 닫히면 입력 대기에서 나온다 (예전에는 다음 단계 변경까지 입력 대기로 남았다)
    @Test func consentWaitEndsWhenItsSubagentStops() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"화면 확인해줘"}"#, env: desktopEnv))
        store.ingest(hook("SubagentStart", #"{"agent_id":"sub1","agent_type":"general-purpose"}"#, env: desktopEnv))
        store.ingest(tool("PreToolUse", "mcp__computer-use__request_full_control", id: "cu1", agent: "sub1", env: desktopEnv))
        clock.advance(3)
        store.checkStalledTools()
        #expect(phase(store) == .waitingInput)
        store.ingest(tool("PreToolUse", "Read", id: "r1", input: #"{"file_path":"/Users/dev/projects/api-server/a.ts"}"#, env: desktopEnv))
        #expect(phase(store) == .waitingInput)

        store.ingest(hook("SubagentStop", #"{"agent_id":"sub1","agent_type":"general-purpose"}"#, env: desktopEnv))
        #expect(phase(store) == .runningTool)
    }

    /// 훅 승인 카드가 결정되면 아직 기다리는 앱 확인 대기를 바로 다시 보여준다 (다음 1초 확인을 기다리지 않는다)
    @Test func consentWaitReturnsRightAfterDecision() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"화면 확인해줘"}"#, env: desktopEnv))
        store.ingest(tool("PreToolUse", "mcp__computer-use__request_full_control", id: "cu1", env: desktopEnv))
        clock.advance(3)
        store.checkStalledTools()
        let signaled = store.latestSignal?.seq
        store.ingest(tool("PreToolUse", "Bash", id: "sb1", agent: "sub1", input: #"{"command":"make"}"#, env: desktopEnv))
        let request = try #require(store.ingest(permission(agent: "sub1", env: desktopEnv)))
        #expect(phase(store) == .waitingPermission)

        store.resolvePermission(id: request, decision: .allow)
        let s = try #require(store.sessions["s1"])
        #expect(s.phase == .waitingInput)
        #expect(s.currentActivity?.id == "cu1")
        // 이미 알린 툴이라 새 신호는 없다 (요청 카드 신호만 있었다)
        #expect(store.latestSignal?.seq == (signaled ?? 0) + 1)
    }
}
