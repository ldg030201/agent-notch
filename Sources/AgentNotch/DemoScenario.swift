import Foundation
import NotchCore
import NotchShared

/// 약 40초짜리 데모. 가짜 훅 이벤트를 소켓 없이 `SessionStore.ingest` 에 바로 넣는다.
///
/// - api-server (Claude Code): Read → Edit(3줄 diff) → 응답 스트리밍 → Bash `npm test` → 두 번째 Edit → Stop
/// - web-app (Codex 앱): `npm run test -- --watch=false` 권한 요청 → 사용자의 선택에 따라 이어서 진행 (허용하면 apply_patch 로 고침)
/// - blog (Claude Code): 대기
///
/// 데모 권한 결정도 `onPermissionResolved` 로 흘러가지만, 소켓 서버는 모르는 ID 라 아무것도 하지 않는다.
@MainActor
final class DemoScenario {
    private struct DemoSession {
        let id: String
        let project: String
        var agent: AgentKind = .claude
        var cwd: String { "/Users/dev/projects/\(project)" }
    }

    private static let apiServer = DemoSession(id: "demo-0000-api-server", project: "api-server")
    private static let webApp = DemoSession(id: "demo-0000-web-app", project: "web-app", agent: .codex)
    private static let blog = DemoSession(id: "demo-0000-blog", project: "blog")
    private static let all = [blog, webApp, apiServer]

    private let store: SessionStore
    private var tasks: [Task<Void, Never>] = []
    private var runningCount = 0
    /// 다시 시작/중지할 때 이전 재생의 완료 알림을 무시하기 위한 세대 번호
    private var generation = 0
    private var toolSeq = 0

    init(store: SessionStore) {
        self.store = store
    }

    var isRunning: Bool { !tasks.isEmpty }

    /// 스토어에 데모 세션이 남아 있는지
    var hasSessions: Bool {
        Self.all.contains { store.sessions[$0.id] != nil }
    }

    /// 처음부터 다시 재생 (남아 있는 데모 세션은 먼저 지운다)
    func start() {
        stop()
        clearSessions()
        toolSeq = 0
        let current = generation
        runningCount = 2
        tasks = [
            Task { [weak self] in
                try? await self?.runMain()
                self?.taskFinished(generation: current)
            },
            Task { [weak self] in
                try? await self?.runWebApp()
                self?.taskFinished(generation: current)
            },
        ]
    }

    /// 재생 중지 (세션은 남겨 둔다)
    func stop() {
        generation += 1
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        runningCount = 0
    }

    /// 데모 세션 제거 (남은 권한 요청도 함께 정리됨)
    func clearSessions() {
        for session in Self.all where store.sessions[session.id] != nil {
            send("SessionEnd", session, ["reason": "other"])
        }
    }

    private func taskFinished(generation finished: Int) {
        guard finished == generation else { return }
        runningCount -= 1
        if runningCount <= 0 { tasks.removeAll() }
    }

    // MARK: - 시나리오

    private func runMain() async throws {
        let api = Self.apiServer
        for session in Self.all {
            send("SessionStart", session, ["source": "startup", "model": session.agent == .codex ? "gpt-6" : "claude-opus-5"])
            try await pause(0.4)
        }
        try await pause(1)

        send("UserPromptSubmit", api, ["prompt": "세션이 만료되면 401 대신 500 이 나는 버그 고쳐줘"])
        try await pause(1.8)

        let sessionFile = "\(api.cwd)/src/auth/session.ts"
        let readID = startTool(api, "Read", ["file_path": sessionFile])
        try await pause(1.6)
        finishTool(api, "Read", readID, ["file_path": sessionFile], [
            "type": "text",
            "file": ["filePath": sessionFile, "numLines": 88, "startLine": 1, "totalLines": 88],
        ])
        try await pause(0.6)
        stream(api, "세션 만료 검사가 초와 밀리초를 섞어 비교하고 있어요.\n", message: 0)
        try await pause(1.6)

        let editInput: [String: Any] = [
            "file_path": sessionFile,
            "old_string": "  return session.expiresAt < Date.now()",
            "new_string": "  const now = Math.floor(Date.now() / 1000)\n  return session.expiresAt < now",
            "replace_all": false,
        ]
        let editID = startTool(api, "Edit", editInput)
        try await pause(1.2)
        finishTool(api, "Edit", editID, editInput, ["filePath": sessionFile])
        try await pause(2.5)

        stream(api, "만료 시각을 초 단위로 맞췄어요.\n", message: 1)
        try await pause(1.2)
        stream(api, "이제 인증 테스트를 돌려 볼게요.\n", message: 2)
        try await pause(1.5)

        let testInput: [String: Any] = ["command": "npm test -- auth", "description": "인증 테스트 실행"]
        let testID = startTool(api, "Bash", testInput)
        try await pause(4)
        finishTool(api, "Bash", testID, testInput, [
            "stdout": "PASS src/auth/session.test.ts\nTests: 12 passed, 12 total\n",
            "stderr": "",
            "interrupted": false,
            "isImage": false,
        ])
        try await pause(1.2)

        let testFile = "\(api.cwd)/src/auth/session.test.ts"
        let secondEdit: [String: Any] = [
            "file_path": testFile,
            "old_string": "describe('isExpired', () => {",
            "new_string": "describe('isExpired', () => {\n  it('초 단위 만료 시각을 비교한다', () => {\n    expect(isExpired({ expiresAt: 0 })).toBe(true)\n  })",
            "replace_all": false,
        ]
        let secondID = startTool(api, "Edit", secondEdit)
        try await pause(1.2)
        finishTool(api, "Edit", secondID, secondEdit, ["filePath": testFile])
        try await pause(2)

        stream(api, "회귀 테스트도 하나 추가했어요.\n", message: 3)
        try await pause(1.5)
        send("Stop", api, [
            "stop_hook_active": false,
            "last_assistant_message": "만료 검사를 초 단위로 고쳤어요. 이제 만료된 세션은 401 을 돌려주고, 회귀 테스트도 추가했어요.",
        ])
    }

    private func runWebApp() async throws {
        let web = Self.webApp
        try await pause(9)
        send("UserPromptSubmit", web, ["prompt": "테스트 한 번 돌려서 깨진 거 있는지 봐줘"])
        try await pause(2.5)

        // Codex: 권한 요청에 항상 허용 규칙(permission_suggestions)이 없다
        let command: [String: Any] = ["command": "npm run test -- --watch=false", "description": "테스트 실행"]
        let toolID = startTool(web, "Bash", command)
        try await pause(0.8)
        let requestID = send("PermissionRequest", web, [
            "tool_name": "Bash",
            "tool_input": command,
            "turn_id": "demo-turn",
        ])

        // 사용자가 노치에서 고를 때까지 기다린다 (최대 3분)
        var waited = 0.0
        while let requestID, store.pendingPermissions.contains(where: { $0.id == requestID }), waited < 180 {
            try await pause(0.25)
            waited += 0.25
        }
        guard let session = store.sessions[web.id] else { return }

        switch session.phase {
        case .runningTool:
            // 허용 → 테스트 실행 → 2개 실패 → apply_patch 로 고치고 끝
            try await pause(2.5)
            finishTool(web, "Bash", toolID, command, [
                "stdout": "Tests: 2 failed, 41 passed, 43 total\n",
                "exit_code": 1,
            ])
            try await pause(2)
            let patch: [String: Any] = ["command": """
                *** Begin Patch
                *** Update File: src/LoginForm.tsx
                @@ function LoginForm
                -  const email = values.email
                +  const email = values.email.trim()
                +  if (!email.includes('@')) return setError('이메일 형식이 아니에요')
                *** End Patch
                """]
            let patchID = startTool(web, "apply_patch", patch)
            try await pause(1.2)
            finishTool(web, "apply_patch", patchID, patch, ["output": "Success. Updated the following files:\nM src/LoginForm.tsx"])
            try await pause(3)
            send("Stop", web, [
                "stop_hook_active": false,
                "last_assistant_message": "이메일 앞뒤 공백 때문에 실패하던 테스트 2개를 고쳤어요.",
            ])
        case .thinking:
            // 거부 → Codex 가 다른 방법으로 마무리 (Codex 는 실패 이벤트 없이 이어서 답한다)
            try await pause(2)
            send("Stop", web, [
                "stop_hook_active": false,
                "last_assistant_message": "테스트 실행을 건너뛰었어요. 직접 돌려 보시겠어요?",
            ])
        case .waitingPermission:
            // 터미널로 넘김 → 터미널에서 허용했다고 치고 이어서 진행
            try await pause(3)
            finishTool(web, "Bash", toolID, command, [
                "stdout": "Tests: 43 passed, 43 total\n",
                "stderr": "",
                "interrupted": false,
                "isImage": false,
            ])
            try await pause(1.5)
            send("Stop", web, [
                "stop_hook_active": false,
                "last_assistant_message": "테스트 43개 모두 통과했어요.",
            ])
        default:
            return
        }
    }

    // MARK: - 이벤트 만들기

    @discardableResult
    private func send(_ event: String, _ session: DemoSession, _ fields: [String: Any]) -> UUID? {
        var payload: [String: JSONValue] = [
            "session_id": .string(session.id),
            "cwd": .string(session.cwd),
            "hook_event_name": .string(event),
            "permission_mode": .string("default"),
        ]
        for (key, value) in fields {
            payload[key] = JSONValue(any: value)
        }
        // Codex 세션은 Codex 앱에서 돈다고 친다 (버튼이 "Codex로")
        let envelope = HookEnvelope(
            event: event,
            sentAt: Date().timeIntervalSince1970,
            env: session.agent == .codex ? ["CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Codex"] : [:],
            expectsReply: NotchWire.replyEvents.contains(event),
            payload: .object(payload),
            agent: session.agent == .claude ? nil : session.agent.rawValue
        )
        return store.ingest(envelope)
    }

    private func startTool(_ session: DemoSession, _ tool: String, _ input: [String: Any]) -> String {
        toolSeq += 1
        let id = "toolu_demo_\(toolSeq)"
        send("PreToolUse", session, ["tool_name": tool, "tool_input": input, "tool_use_id": id])
        return id
    }

    private func finishTool(
        _ session: DemoSession,
        _ tool: String,
        _ id: String,
        _ input: [String: Any],
        _ response: [String: Any]
    ) {
        send("PostToolUse", session, [
            "tool_name": tool,
            "tool_input": input,
            "tool_response": response,
            "tool_use_id": id,
            "duration_ms": 1200,
        ])
    }

    /// 메시지 하나를 한 조각으로 보낸다 (`-p` 모드처럼 index 0, final true)
    private func stream(_ session: DemoSession, _ delta: String, message: Int) {
        send("MessageDisplay", session, [
            "turn_id": "demo-turn",
            "message_id": "demo-message-\(message)",
            "index": 0,
            "final": true,
            "delta": delta,
        ])
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
