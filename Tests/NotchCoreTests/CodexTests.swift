import Foundation
import Testing
@testable import NotchCore
import NotchShared

/// Codex 훅 이벤트 (훅 명령의 `--agent codex` → `HookEnvelope.agent`)
func codexHook(
    _ event: String,
    session: String = "c1",
    cwd: String? = projectCwd,
    _ fields: String = "{}",
    env: [String: String] = [:],
    expectsReply: Bool? = nil
) -> HookEnvelope {
    var envelope = hook(event, session: session, cwd: cwd, fields, env: env)
    envelope.agent = AgentKind.codex.rawValue
    if let expectsReply { envelope.expectsReply = expectsReply }
    return envelope
}

@Suite("Codex 와이어")
struct CodexWireTests {
    @Test func envelopeWithoutAgentIsClaude() throws {
        // 예전 헬퍼 · Claude Code 훅은 agent 를 보내지 않는다
        let line = #"{"v":1,"event":"Stop","sentAt":0,"env":{},"expectsReply":false,"payload":{}}"#
        let envelope = try JSONDecoder().decode(HookEnvelope.self, from: Data(line.utf8))
        #expect(envelope.agent == nil)
        #expect(envelope.agentKind == .claude)
    }

    @Test func envelopeRoundTripsAgent() throws {
        let envelope = codexHook("Stop")
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(HookEnvelope.self, from: data)
        #expect(decoded.agentKind == .codex)
        // Claude Code envelope 는 agent 키를 아예 쓰지 않는다 (예전 앱과 같은 모양)
        let claude = try JSONEncoder().encode(hook("Stop"))
        #expect(!String(decoding: claude, as: UTF8.self).contains("\"agent\""))
    }

    @Test func unknownAgentNameFallsBackToClaude() {
        var envelope = hook("Stop")
        envelope.agent = "gemini"
        #expect(envelope.agentKind == .claude)
        #expect(AgentKind(name: " Codex ") == .codex)
        #expect(AgentKind(name: "") == nil)
    }

    @Test func forwardsOnlyNonSecretCodexKeys() {
        let keys = NotchWire.forwardedEnvironmentKeys
        #expect(keys.contains("CODEX_INTERNAL_ORIGINATOR_OVERRIDE"))
        #expect(keys.contains("CODEX_THREAD_ID"))
        #expect(!keys.contains { $0.contains("KEY") || $0.contains("TOKEN") || $0.contains("SECRET") })
    }
}

@Suite("Codex 세션 앱")
struct CodexHostTests {
    let threadID = "01a16199-d734-7d03-a3e3-b0d129131dcf"

    @Test func codexAppOriginatorIsCodexDesktop() throws {
        let context = TerminalContext(environment: ["CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Codex"], agent: .codex)
        #expect(context.isCodexDesktopApp)
        #expect(context.hostBundleIdentifier == TerminalContext.codexDesktopBundleID)
        #expect(!context.isClaudeDesktopApp)
        #expect(TerminalContext(originator: "Codex Desktop").isCodexDesktopApp)
        // VS Code 확장 같은 다른 앱 · 터미널은 Codex 앱이 아니다
        #expect(!TerminalContext(originator: "codex_vscode").isCodexDesktopApp)
        #expect(!TerminalContext(termProgram: "iTerm.app").isCodexDesktopApp)
        // 번들 ID 가 있으면 그게 먼저
        #expect(TerminalContext(bundleIdentifier: "com.microsoft.VSCode", originator: "Codex").hostBundleIdentifier == "com.microsoft.VSCode")
    }

    @Test func threadLinkOnlyForValidThreadID() throws {
        var context = TerminalContext(hostSessionID: threadID, originator: "Codex")
        #expect(context.codexDesktopThreadURL?.absoluteString == "codex://threads/\(threadID)")
        context.hostSessionID = "../../etc"
        #expect(context.codexDesktopThreadURL == nil)
        // Codex 앱 세션이 아니면 링크 없음 (터미널로 간다)
        #expect(TerminalContext(termProgram: "iTerm.app", hostSessionID: threadID).codexDesktopThreadURL == nil)
        // Claude 앱 링크와 섞이지 않는다
        #expect(context.claudeDesktopSessionURL == nil)
    }

    @Test func eachAgentReadsOnlyItsOwnKeys() {
        let env = [
            "CLAUDE_CODE_ENTRYPOINT": "claude-desktop",
            "CLAUDE_CODE_HOST_SESSION_ID": "local_abc",
            "CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Codex",
            "CODEX_THREAD_ID": threadID,
        ]
        let codex = TerminalContext(environment: env, agent: .codex)
        #expect(codex.isCodexDesktopApp)
        #expect(codex.entrypoint == nil)
        #expect(codex.hostSessionID == threadID)
        let claude = TerminalContext(environment: env, agent: .claude)
        #expect(claude.isClaudeDesktopApp)
        #expect(claude.originator == nil)
        #expect(claude.hostSessionID == "local_abc")
    }

    @MainActor
    @Test func storeMarksCodexSessionAndThread() throws {
        let store = makeStore(TestClock())
        store.ingest(codexHook("SessionStart", session: threadID, #"{"source":"startup","model":"gpt-6"}"#, env: ["CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Codex"]))
        store.ingest(hook("SessionStart", session: "claude-1", #"{"source":"startup"}"#))
        let codex = try #require(store.sessions[threadID])
        #expect(codex.agent == .codex)
        #expect(codex.terminal.isCodexDesktopApp)
        // 훅에 스레드 ID 가 없어도 session_id 가 스레드다
        #expect(codex.terminal.codexDesktopThreadURL?.absoluteString == "codex://threads/\(threadID)")
        #expect(store.sessions["claude-1"]?.agent == .claude)
    }
}

@MainActor
@Suite("Codex 세션 상태")
struct CodexSessionTests {
    let clock = TestClock()

    @Test func interruptEndsTurn() throws {
        let store = makeStore(clock)
        store.ingest(codexHook("UserPromptSubmit", #"{"prompt":"테스트 돌려줘","turn_id":"t1"}"#))
        store.ingest(codexHook("PreToolUse", #"{"tool_name":"Bash","tool_use_id":"call_1","tool_input":{"command":"swift test"}}"#))
        #expect(store.sessions["c1"]?.phase == .runningTool)

        clock.advance()
        store.ingest(codexHook("Interrupt", #"{"turn_id":"t1","permission_mode":"default"}"#))
        let s = try #require(store.sessions["c1"])
        #expect(s.phase == .idle)
        #expect(s.currentActivity == nil)
        #expect(s.activities.first { $0.id == "call_1" }?.status == .failed)
    }

    @Test func interruptReleasesPermissionWait() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        store.ingest(codexHook("UserPromptSubmit", #"{"prompt":"지워줘"}"#))
        let id = try #require(store.ingest(codexHook("PermissionRequest", #"{"tool_name":"Bash","tool_input":{"command":"rm -rf build","description":"빌드 폴더 삭제"}}"#)))
        #expect(store.sessions["c1"]?.phase == .waitingPermission)
        #expect(store.pendingPermissions.first?.id == id)
        // Codex 는 권한 제안(permission_suggestions)이 없어 항상 허용 규칙도 없다
        #expect(store.pendingPermissions.first?.suggestions == nil)

        store.ingest(codexHook("Interrupt"))
        #expect(store.pendingPermissions.isEmpty)
        #expect(store.sessions["c1"]?.phase == .idle)
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.1 == .passthrough)
    }

    @Test func requestUserInputWaitsForAnswerInSessionApp() throws {
        let store = makeStore(clock)
        store.ingest(codexHook("UserPromptSubmit", #"{"prompt":"배포해줘"}"#))
        let question = #"{"tool_name":"request_user_input","tool_use_id":"call_q","tool_input":{"questions":[{"id":"target","header":"대상","question":"어디에 배포할까?","options":[{"label":"스테이징","description":"먼저 확인"},{"label":"운영","description":"바로 반영"}]}]}}"#
        let requestID = store.ingest(codexHook("PreToolUse", question))
        // 훅으로 답할 수 없어 대기열에 넣지 않는다 (Codex 앱 · 터미널에서 답한다)
        #expect(requestID == nil)
        #expect(store.pendingPermissions.isEmpty)
        let s = try #require(store.sessions["c1"])
        #expect(s.phase == .waitingInput)
        #expect(s.currentActivity?.title == "질문")
        #expect(store.latestSignal?.signal == .needsInput(sessionID: "c1", message: "어디에 배포할까?"))

        store.ingest(codexHook("PostToolUse", #"{"tool_name":"request_user_input","tool_use_id":"call_q","tool_response":"스테이징"}"#))
        #expect(store.sessions["c1"]?.phase == .thinking)
    }

    @Test func applyPatchShowsEditAndDiff() throws {
        let store = makeStore(clock)
        store.ingest(codexHook("UserPromptSubmit", #"{"prompt":"TTL 빼줘"}"#))
        let patch = "*** Begin Patch\n*** Update File: src/auth/session.ts\n@@ export function ttl\n-const ttl = 3600\n+const ttl = env.SESSION_TTL ?? 3600\n+if (!token) return null\n*** Add File: src/auth/ttl.test.ts\n+import { ttl } from './session'\n*** End Patch\n"
        let input = try String(decoding: JSONEncoder().encode(JSONValue.object(["command": .string(patch)])), as: UTF8.self)
        store.ingest(codexHook("PreToolUse", #"{"tool_name":"apply_patch","tool_use_id":"call_p","tool_input":"# + input + "}"))
        var s = try #require(store.sessions["c1"])
        #expect(s.currentActivity?.title == "Edit 2개 파일")
        #expect(s.currentActivity?.label == "Edit")
        #expect(s.currentActivity?.detail == "src/auth/session.ts, src/auth/ttl.test.ts")

        store.ingest(codexHook("PostToolUse", #"{"tool_name":"apply_patch","tool_use_id":"call_p","tool_response":"Success","tool_input":"# + input + "}"))
        s = try #require(store.sessions["c1"])
        #expect(s.turn.added == 3)
        #expect(s.turn.removed == 1)
        #expect(s.turn.changedFiles == ["\(projectCwd)/src/auth/session.ts", "\(projectCwd)/src/auth/ttl.test.ts"])
        #expect(s.lastDiff?.filePath == "\(projectCwd)/src/auth/session.ts")
        #expect(s.lastDiff?.lines.map(\.kind) == [.removed, .added, .added])
        guard case .edited(_, let diff)? = store.latestSignal?.signal else {
            Issue.record("edited 신호가 없음")
            return
        }
        #expect(diff.fileName == "session.ts")
    }
}

@Suite("Codex apply_patch")
struct ApplyPatchTests {
    @Test func parsesHeredocAndOperations() throws {
        let text = """
        apply_patch <<'EOF'
        *** Begin Patch
        *** Add File: docs/new.md
        +# 제목
        +본문
        *** Delete File: old.txt
        *** Update File: a.swift
        *** Move to: b.swift
        @@
         let x = 1
        -let y = 2
        +let y = 3
        *** End of File
        *** End Patch
        EOF
        """
        let patch = try #require(ApplyPatch.parse(text))
        #expect(patch.files.map(\.operation) == [.add, .delete, .update])
        #expect(patch.files[2].resultPath == "b.swift")
        #expect(patch.files[0].lines.count == 2)
        #expect(patch.files[2].lines == [" let x = 1", "-let y = 2", "+let y = 3"])
        #expect(ApplyPatch.parse("echo hi") == nil)
    }

    @Test func diffCountsPerFileAndKeepsAbsolutePaths() throws {
        let patch = "*** Begin Patch\n*** Delete File: /tmp/gone.txt\n*** Add File: new.txt\n+a\n+b\n*** End Patch"
        let outcome = try #require(DiffEngine.outcome(
            toolName: "apply_patch", toolInput: .object(["command": .string(patch)]), toolResponse: nil, cwd: "/Users/dev/projects/web-app"
        ))
        #expect(outcome.changedFiles == ["/tmp/gone.txt", "/Users/dev/projects/web-app/new.txt"])
        #expect(outcome.added == 2)
        #expect(outcome.removed == 0)
        // 지운 파일은 내용이 없어 새 파일을 미리보기로
        #expect(outcome.snippet?.isNewFile == true)
        #expect(outcome.snippet?.startLine == 1)
    }

    @Test func permissionCardListsFiles() {
        let patch = "*** Begin Patch\n*** Update File: src/a.ts\n*** Move to: src/b.ts\n-x\n+y\n*** Delete File: README.md\n*** End Patch"
        let summary = ToolSummarizer.permissionSummary(
            toolName: "apply_patch", toolInput: .object(["command": .string(patch)]), cwd: projectCwd
        )
        #expect(summary.title == "파일 수정 요청")
        #expect(summary.detail == "이동 src/a.ts → src/b.ts⏎\n삭제 README.md")
        #expect(!summary.isTruncated)
    }

    @Test func codexToolSummaries() {
        func title(_ name: String, _ input: String) -> String {
            ToolSummarizer.summarize(toolName: name, toolInput: json(input), cwd: projectCwd).title
        }
        #expect(title("update_plan", #"{"plan":[{"step":"a","status":"pending"},{"step":"b","status":"pending"}]}"#) == "Todo")
        #expect(title("spawn_agent", #"{"task_name":"gpu_scene","message":"렌더링 개선"}"#) == "Agent gpu_scene")
        #expect(title("Bash", #"{"command":["bash","-lc","swift test"]}"#) == "Bash bash -lc swift test")
        #expect(title("exec", #"{"title":"파일 찾기"}"#) == "Code 파일 찾기")
        #expect(ToolSummarizer.summarize(toolName: "apply_patch", toolInput: json(#"{"command":"*** Begin Patch\n*** Add File: x.md\n+a\n*** End Patch"}"#), cwd: projectCwd).symbolName == "doc.badge.plus")
    }
}
