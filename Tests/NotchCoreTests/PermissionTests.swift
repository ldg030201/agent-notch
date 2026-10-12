import Foundation
import Testing
@testable import NotchCore
import NotchShared

@MainActor
@Suite struct PermissionTests {
    let clock = TestClock()
    let bashRequest = #"{"tool_name":"Bash","tool_input":{"command":"rm -rf node_modules","description":"Remove node_modules"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}],"behavior":"allow","destination":"localSettings"}]}"#

    private func startTurn(_ store: SessionStore, session: String = "s1") {
        store.ingest(hook("UserPromptSubmit", session: session, #"{"prompt":"정리해줘"}"#))
        store.ingest(hook("PreToolUse", session: session, #"{"tool_name":"Bash","tool_use_id":"b1","tool_input":{"command":"rm -rf node_modules"}}"#))
    }

    @Test func requestAndAllow() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        startTurn(store)

        clock.advance()
        let id = try #require(store.ingest(hook("PermissionRequest", bashRequest)))
        let info = try #require(store.pendingPermissions.first)
        #expect(info.id == id)
        #expect(info.title == "Bash 실행 요청")
        #expect(info.detail == "rm -rf node_modules")
        #expect(info.receivedAt == clock.now)
        #expect(info.suggestions?.arrayValue?.count == 1)
        #expect(store.sessions["s1"]?.phase == .waitingPermission)
        #expect(store.latestSignal?.signal == .permissionRequested(id: id, sessionID: "s1"))

        store.resolvePermission(id: id, decision: .allow)
        #expect(store.pendingPermissions.isEmpty)
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.0.id == id)
        #expect(recorder.calls.first?.1 == .allow)
        #expect(store.sessions["s1"]?.phase == .runningTool)

        // 이미 처리된 ID 는 무시
        store.resolvePermission(id: id, decision: .deny(message: nil))
        #expect(recorder.calls.count == 1)
    }

    @Test func allowOutput() {
        let info = pending("s1", at: 0)
        let output = PermissionReplyBuilder.output(for: info, decision: .allow)
        #expect(output == json(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#))
    }

    @Test func allowAlwaysOutput() {
        var info = pending("s1", at: 0)
        let suggestions = json(#"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test"}],"behavior":"allow","destination":"localSettings"}]"#)
        info.suggestions = suggestions
        let output = PermissionReplyBuilder.output(for: info, decision: .allowAlways)
        #expect(output?["hookSpecificOutput"]?["decision"]?["behavior"] == .string("allow"))
        #expect(output?["hookSpecificOutput"]?["decision"]?["updatedPermissions"] == suggestions)

        // 제안이 없거나 빈 배열이면 일반 허용
        info.suggestions = nil
        #expect(PermissionReplyBuilder.output(for: info, decision: .allowAlways) == PermissionReplyBuilder.output(for: info, decision: .allow))
        info.suggestions = .array([])
        #expect(PermissionReplyBuilder.output(for: info, decision: .allowAlways) == PermissionReplyBuilder.output(for: info, decision: .allow))
    }

    @Test func denyOutput() {
        let info = pending("s1", at: 0)
        let defaultDeny = PermissionReplyBuilder.output(for: info, decision: .deny(message: nil))
        #expect(defaultDeny == json(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"AgentNotch 에서 거부됨"}}}"#))
        let blank = PermissionReplyBuilder.output(for: info, decision: .deny(message: "  "))
        #expect(blank == defaultDeny)
        let custom = PermissionReplyBuilder.output(for: info, decision: .deny(message: "테스트만 돌려"))
        #expect(custom?["hookSpecificOutput"]?["decision"]?["message"] == .string("테스트만 돌려"))
        #expect(PermissionReplyBuilder.output(for: info, decision: .passthrough) == nil)
    }

    @Test func denyAndPassthroughPhases() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        startTurn(store)

        let denied = try #require(store.ingest(hook("PermissionRequest", bashRequest)))
        store.resolvePermission(id: denied, decision: .deny(message: nil))
        #expect(store.sessions["s1"]?.phase == .thinking)

        let passed = try #require(store.ingest(hook("PermissionRequest", bashRequest)))
        store.resolvePermission(id: passed, decision: .passthrough)
        #expect(store.sessions["s1"]?.phase == .waitingPermission)
        #expect(store.pendingPermissions.isEmpty)
        #expect(recorder.calls.map { $0.1 } == [.deny(message: nil), .passthrough])
    }

    @Test(arguments: [
        ("PostToolUse", #"{"tool_name":"Bash","tool_use_id":"b1","tool_response":{}}"#),
        ("PostToolUseFailure", #"{"tool_name":"Bash","tool_use_id":"b1","error":"denied"}"#),
        ("PreToolUse", #"{"tool_name":"Read","tool_use_id":"r2","tool_input":{"file_path":"/Users/dev/projects/api-server/a.ts"}}"#),
        ("UserPromptSubmit", #"{"prompt":"다른 거 해줘"}"#),
        ("Stop", "{}"),
        ("StopFailure", #"{"error":"unknown"}"#),
        ("SessionEnd", #"{"reason":"other"}"#),
    ])
    func stalePendingReleasedAsPassthrough(event: String, fields: String) throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        startTurn(store)
        let id = try #require(store.ingest(hook("PermissionRequest", bashRequest)))

        store.ingest(hook(event, fields))
        #expect(store.pendingPermissions.isEmpty)
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.0.id == id)
        #expect(recorder.calls.first?.1 == .passthrough)
    }

    @Test func preToolUseBeforeRequestKeepsIt() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        // 정상 순서: PreToolUse → PermissionRequest (같은 호출)
        startTurn(store)
        _ = try #require(store.ingest(hook("PermissionRequest", bashRequest)))
        #expect(store.pendingPermissions.count == 1)
        #expect(recorder.calls.isEmpty)
        // 다른 세션의 이벤트는 영향 없음
        store.ingest(hook("Stop", session: "other", cwd: otherCwd, "{}"))
        #expect(store.pendingPermissions.count == 1)
    }

    @Test func subagentPendingSurvivesOtherAgentTools() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        store.ingest(hook("PreToolUse", #"{"tool_name":"Bash","tool_use_id":"sb1","agent_id":"sub1","tool_input":{"command":"make"}}"#))
        let id = try #require(store.ingest(hook("PermissionRequest", #"{"tool_name":"Bash","agent_id":"sub1","tool_input":{"command":"make"}}"#)))

        // 메인 에이전트(또는 다른 서브에이전트)의 툴 진행은 sub1 의 요청과 무관
        store.ingest(hook("PreToolUse", #"{"tool_name":"Read","tool_use_id":"r1","tool_input":{"file_path":"/Users/dev/projects/api-server/a.ts"}}"#))
        store.ingest(hook("PostToolUse", #"{"tool_name":"Read","tool_use_id":"r1","tool_response":{}}"#))
        store.ingest(hook("PreToolUse", #"{"tool_name":"Grep","tool_use_id":"g1","agent_id":"sub2","tool_input":{"pattern":"x"}}"#))
        #expect(store.pendingPermissions.map(\.id) == [id])
        #expect(store.sessions["s1"]?.phase == .waitingPermission)
        #expect(recorder.calls.isEmpty)

        // sub1 이 끝나면 정리
        store.ingest(hook("SubagentStop", #"{"agent_id":"sub1","agent_type":"general-purpose"}"#))
        #expect(store.pendingPermissions.isEmpty)
        #expect(recorder.calls.map { $0.1 } == [.passthrough])
    }

    @Test func cancelRemovesWithoutCallback() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        startTurn(store)
        let id = try #require(store.ingest(hook("PermissionRequest", bashRequest)))
        store.cancelPermission(id: id)
        #expect(store.pendingPermissions.isEmpty)
        #expect(recorder.calls.isEmpty)
        #expect(store.sessions["s1"]?.phase == .waitingPermission)
        // 모르는 ID 는 무시
        store.cancelPermission(id: UUID())
        store.resolvePermission(id: UUID(), decision: .allow)
        #expect(recorder.calls.isEmpty)
    }

    @Test func permissionPromptNotificationWithPending() throws {
        let store = makeStore(clock)
        startTurn(store)
        let id = try #require(store.ingest(hook("PermissionRequest", bashRequest)))
        store.ingest(hook("Notification", #"{"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}"#))
        // 훅 대기 요청이 있으면 needsInput 을 따로 내지 않는다
        #expect(store.latestSignal?.signal == .permissionRequested(id: id, sessionID: "s1"))
        #expect(store.sessions["s1"]?.lastNotification == "Claude needs your permission to use Bash")
    }

    @Test func dismissReleasesPendings() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        startTurn(store)
        _ = try #require(store.ingest(hook("PermissionRequest", bashRequest)))
        store.dismiss(sessionID: "s1")
        #expect(store.sessions.isEmpty)
        #expect(store.pendingPermissions.isEmpty)
        #expect(recorder.calls.map { $0.1 } == [.passthrough])
    }

    @Test func permissionSummaries() {
        let cases: [(String, String, String, String)] = [
            ("Bash", #"{"command":"npm run test -- --watch=false"}"#, "Bash 실행 요청", "npm run test -- --watch=false"),
            ("Edit", #"{"file_path":"/Users/dev/projects/api-server/src/a.ts"}"#, "파일 수정 요청", "src/a.ts"),
            ("Write", #"{"file_path":"/Users/dev/other/b.ts"}"#, "파일 수정 요청", "/Users/dev/other/b.ts"),
            ("NotebookEdit", #"{"notebook_path":"/Users/dev/projects/api-server/n.ipynb"}"#, "파일 수정 요청", "n.ipynb"),
            ("WebFetch", #"{"url":"https://example.com/docs","prompt":"요약"}"#, "웹 요청", "https://example.com/docs"),
            ("mcp__github__create_issue", #"{"title":"x"}"#, "MCP 툴 요청", "github · create_issue"),
            ("ExitPlanMode", #"{"plan":"\n## 세션 TTL 분리\n1. 설정 추가"}"#, "계획 승인 요청", "세션 TTL 분리"),
            ("WebSearch", #"{"query":"swift"}"#, "WebSearch 사용 요청", #"{"query":"swift"}"#),
        ]
        for (tool, input, title, detail) in cases {
            let summary = ToolSummarizer.permissionSummary(toolName: tool, toolInput: json(input), cwd: projectCwd)
            #expect(summary.title == title, "\(tool)")
            #expect(summary.detail == detail, "\(tool)")
        }
    }
}
