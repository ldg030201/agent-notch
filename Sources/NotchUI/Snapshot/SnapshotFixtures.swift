import Foundation
import Observation
import NotchCore
import NotchShared

// 스냅숏 렌더링용 가짜 데이터. 실제 사용자 설정 · 파일 · 네트워크를 건드리지 않는다.

/// 디스크에 쓰지도, 사용자 설정을 읽지도 않는 메모리 전용 UserDefaults
final class MemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    init?(values: [String: Any] = [:]) {
        super.init(suiteName: "AgentNotch.snapshot.memory")
        storage = values
    }

    override func object(forKey defaultName: String) -> Any? { storage[defaultName] }
    override func string(forKey defaultName: String) -> String? { storage[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) { storage[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { storage[defaultName] = value }
    override func set(_ value: Double, forKey defaultName: String) { storage[defaultName] = value }
    override func set(_ value: Int, forKey defaultName: String) { storage[defaultName] = value }
    override func removeObject(forKey defaultName: String) { storage[defaultName] = nil }
}

/// 고정 시계 (이벤트마다 직접 앞으로 돌린다)
@MainActor
final class SnapshotClock {
    /// 2026-01-15 10:30:00 KST
    static let base = Date(timeIntervalSince1970: 1_768_440_600)
    private(set) var now = SnapshotClock.base

    func set(_ seconds: TimeInterval) {
        now = Self.base.addingTimeInterval(seconds)
    }
}

/// 아무것도 하지 않는 동작 (렌더링 전용)
@MainActor
final class SnapshotActions: IslandActions {
    func resolvePermission(id: UUID, decision: PermissionDecision) {}
    func jumpToTerminal(sessionID: String) {}
    func openFile(path: String, line: Int?) {}
    func togglePin(sessionID: String) {}
    func focus(sessionID: String) {}
    func dismiss(sessionID: String) {}
    func openSettings() {}
}

@MainActor
final class SnapshotSettingsProvider: SettingsProvider {
    var appVersion: String { "0.1.0" }
    var hookStatusText: String { "설치됨 · 이벤트 14개" }
    var hooksInstalled: Bool { true }
    func installHooks() throws {}
    func uninstallHooks() throws {}
    var launchAtLoginEnabled: Bool { true }
    var launchAtLoginManagedByHomebrew: Bool { false }
    func setLaunchAtLogin(_ enabled: Bool) throws {}
}

/// 새 버전이 있는 상태의 가짜 업데이트 정보
@MainActor
@Observable
final class SnapshotUpdateProvider: UpdateProvider {
    var currentVersion = "0.1.0"
    var latestVersion: String? = "0.2.0"
    var hasUpdate = true
    var isChecking = false
    var lastCheckedAt: Date?
    var errorText: String?
    var checksForUpdates = true
    var changelog: [ChangelogDisplayEntry] = [
        ChangelogDisplayEntry(version: "0.3.0", date: nil, groups: [
            .init(title: "아일랜드", notes: [
                .init(kind: "new", text: "세션별 알림 끄기"),
            ]),
        ]),
        ChangelogDisplayEntry(version: "0.2.0", date: "2026-01-14", groups: [
            .init(title: "메뉴바", notes: [
                .init(kind: "new", text: "외부 모니터에서는 메뉴바 안 빈 곳에 알약으로 표시"),
                .init(kind: "improve", text: "노치 옆이 메뉴바 아이콘으로 막히면 노치 아래 띠로 표시"),
            ]),
            .init(title: "권한 요청", notes: [
                .init(kind: "new", text: "권한 카드 접기 (요청은 그대로 대기)"),
                .init(kind: "fix", text: "열린 메뉴 위로 카드가 겹치던 문제"),
            ]),
        ]),
        ChangelogDisplayEntry(version: "0.1.0", date: "2026-01-02", groups: [
            .init(title: "처음 공개", notes: [
                .init(kind: "new", text: "노치에서 Claude Code 세션 보기 · 권한 승인"),
            ]),
        ]),
    ]
    var upgradePhase: UpgradePhase = .idle
    var upgradeLog = ""

    init(now: Date) {
        lastCheckedAt = now.addingTimeInterval(-3 * 60)
    }

    func checkNow() {}
    func startUpgrade() {}
    func cancelUpgrade() {}
    func relaunchAfterUpgrade() {}
    func forceQuit() {}
}

/// 가짜 훅 이벤트를 스토어에 넣어 실제 모델을 만든다 (경로 · 내용은 모두 예시)
@MainActor
struct SnapshotWorld {
    struct Project {
        let id: String
        let name: String
        var cwd: String { "/Users/dev/projects/\(name)" }
    }

    static let apiServer = Project(id: "snapshot-api-server", name: "api-server")
    static let webApp = Project(id: "snapshot-web-app", name: "web-app")
    static let blog = Project(id: "snapshot-blog", name: "blog")

    let clock: SnapshotClock
    let store: SessionStore
    private var toolSeq = 0

    init() {
        let clock = SnapshotClock()
        self.clock = clock
        self.store = SessionStore(clock: { clock.now })
    }

    // MARK: 장면 조각

    /// 세 세션 시작 (blog 가 가장 오래 쉬고 있음)
    mutating func startSessions() {
        send(Self.blog, "SessionStart", at: 0, ["source": "startup"])
        send(Self.webApp, "SessionStart", at: 180, ["source": "startup"])
        send(Self.apiServer, "SessionStart", at: 300, ["source": "startup"])
    }

    /// api-server: Read → Edit(+12 −3) → 응답 한 줄 (피크 직전 상태). 수정된 diff 를 돌려준다.
    @discardableResult
    mutating func apiServerEdits() -> DiffSnippet? {
        let api = Self.apiServer
        send(api, "UserPromptSubmit", at: 600, ["prompt": "세션 만료 시간을 환경변수로 빼줘"])
        let file = "\(api.cwd)/src/auth/session.ts"
        tool(api, "Read", at: 605, input: ["file_path": file], response: ["type": "text"])
        tool(api, "Edit", at: 611, input: [
            "file_path": file,
            "old_string": "const ttl = 3600",
            "new_string": "const ttl = env.SESSION_TTL ?? 3600",
        ], response: ["filePath": file, "structuredPatch": [Self.hunk(newStart: 42, lines: [
            "-const ttl = 3600",
            "+const ttl = env.SESSION_TTL ?? 3600",
            "+if (!token) return null",
            "-const secret = process.env.SECRET",
            "+const secret = env.SESSION_SECRET",
            "+if (!secret) throw new Error('SESSION_SECRET 없음')",
            "+const expiresAt = Math.floor(Date.now() / 1000) + ttl",
            "+const payload = { ...claims, exp: expiresAt }",
            "-return jwt.sign(claims, secret)",
            "+return jwt.sign(payload, secret)",
            "+",
            "+export function isExpired(session: Session) {",
            "+  // 초 단위로 비교",
            "+  return session.expiresAt < Math.floor(Date.now() / 1000)",
            "+}",
        ])]])
        stream(api, at: 612, "세션 만료 시간을 환경변수로 뺐어. 이제 테스트 돌려볼게…")
        return store.sessions[api.id]?.lastDiff
    }

    /// api-server: 테스트 실행 중 (접힌 상태 · 펼침에 스피너)
    mutating func apiServerRunsTests() {
        start(Self.apiServer, "Bash", at: 614, input: ["command": "npm test", "description": "테스트 실행"])
        clock.set(842)
    }

    /// api-server: 파일 두 개 더 고치고 테스트 통과 후 완료 (총 3개 파일 +40 −12, 2m 14s)
    mutating func apiServerCompletes() {
        let api = Self.apiServer
        let bash = start(api, "Bash", at: 614, input: ["command": "npm test", "description": "테스트 실행"])
        finish(api, "Bash", id: bash, at: 640, input: ["command": "npm test"], response: [
            "stdout": "Tests: 14 passed, 14 total\n", "stderr": "", "interrupted": false,
        ])
        let config = "\(api.cwd)/src/config.ts"
        tool(api, "Edit", at: 660, input: ["file_path": config], response: [
            "filePath": config,
            "structuredPatch": [Self.hunk(newStart: 8, removed: Array(repeating: "// 임시 값", count: 5), added: Array(repeating: "export const env = loadEnv()", count: 14))],
        ])
        let test = "\(api.cwd)/src/auth/session.test.ts"
        tool(api, "Edit", at: 700, input: ["file_path": test], response: [
            "filePath": test,
            "structuredPatch": [Self.hunk(newStart: 20, removed: Array(repeating: "it.skip('ttl')", count: 4), added: Array(repeating: "it('ttl 을 환경변수로 읽는다', () => {})", count: 14))],
        ])
        stream(api, at: 733, "세션 TTL 설정 분리하고 테스트 14개 전부 통과했어.")
        send(api, "Stop", at: 734, [
            "stop_hook_active": false,
            "last_assistant_message": "세션 TTL 설정 분리하고 테스트 14개 전부 통과했어.",
        ])
        clock.set(736)
    }

    /// web-app: 테스트 실행 권한 요청 대기
    mutating func webAppAsksPermission() {
        let web = Self.webApp
        send(web, "UserPromptSubmit", at: 820, ["prompt": "테스트 한 번 돌려서 깨진 거 있는지 봐줘"])
        let command: [String: Any] = ["command": "npm run test -- --watch=false", "description": "테스트 실행"]
        start(web, "Bash", at: 830, input: command)
        send(web, "PermissionRequest", at: 831, [
            "tool_name": "Bash",
            "tool_input": command,
            "permission_suggestions": [[
                "type": "addRules",
                "rules": [["toolName": "Bash", "ruleContent": "npm run test:*"]],
                "behavior": "allow",
                "destination": "localSettings",
            ]],
        ])
        clock.set(842)
    }

    /// web-app: 카드에 다 들어가지 않는 여러 줄 명령 권한 요청 (허용 막힘 · 터미널로 안내)
    mutating func webAppAsksClippedPermission() {
        let web = Self.webApp
        send(web, "UserPromptSubmit", at: 820, ["prompt": "스테이징 배포 스크립트 만들어줘"])
        let command: [String: Any] = [
            "command": """
            cat > scripts/deploy.sh <<'EOF'
            #!/bin/sh
            set -e
            npm run build


            rsync -av dist/ deploy@staging.example.com:/srv/web-app
            EOF
            """,
            "description": "배포 스크립트 작성",
        ]
        start(web, "Bash", at: 830, input: command)
        send(web, "PermissionRequest", at: 831, [
            "tool_name": "Bash",
            "tool_input": command,
            "permission_suggestions": [[
                "type": "addRules",
                "rules": [["toolName": "Bash", "ruleContent": "cat:*"]],
                "behavior": "allow",
                "destination": "localSettings",
            ]],
        ])
        clock.set(842)
    }

    /// web-app: 프로젝트 밖 파일 수정 권한 요청 (항상 허용 범위가 여러 줄)
    mutating func webAppAsksScopedPermission() {
        let web = Self.webApp
        send(web, "UserPromptSubmit", at: 820, ["prompt": "공용 설정에도 같은 값 넣어줘"])
        let file = "/Users/dev/projects/shared-config/env.ts"
        let input: [String: Any] = ["file_path": file, "old_string": "ttl: 3600", "new_string": "ttl: env.SESSION_TTL"]
        start(web, "Edit", at: 830, input: input)
        send(web, "PermissionRequest", at: 831, [
            "tool_name": "Edit",
            "tool_input": input,
            "permission_suggestions": [
                ["type": "addDirectories", "directories": ["/Users/dev/projects/shared-config"], "destination": "session"],
                ["type": "setMode", "mode": "acceptEdits", "destination": "session"],
            ],
        ])
        clock.set(842)
    }

    /// web-app: 테스트 실패 후 사용량 한도로 턴 실패
    mutating func webAppFails() {
        let web = Self.webApp
        send(web, "UserPromptSubmit", at: 650, ["prompt": "테스트 한 번 돌려서 깨진 거 있는지 봐줘"])
        let command: [String: Any] = ["command": "npm run test -- --watch=false"]
        tool(web, "Bash", at: 690, input: command, response: [
            "stdout": "Tests: 2 failed, 41 passed, 43 total\n", "stderr": "", "interrupted": false,
        ])
        send(web, "StopFailure", at: 700, ["error": "rate_limit"])
        clock.set(702)
    }

    /// blog: 질문에 답 기다림
    mutating func blogAsksQuestion() {
        let blog = Self.blog
        send(blog, "UserPromptSubmit", at: 760, ["prompt": "새 글 배포해줘"])
        start(blog, "AskUserQuestion", at: 770, input: ["questions": [[
            "question": "배포 전에 이미지도 같이 최적화할까요?",
            "header": "이미지",
            "options": [["label": "같이 하기"], ["label": "건너뛰기"]],
        ]]])
        clock.set(772)
    }

    // MARK: 이벤트 만들기

    mutating func send(_ project: Project, _ event: String, at seconds: TimeInterval, _ fields: [String: Any]) {
        clock.set(seconds)
        var payload: [String: JSONValue] = [
            "session_id": .string(project.id),
            "cwd": .string(project.cwd),
            "hook_event_name": .string(event),
            "permission_mode": .string("default"),
        ]
        for (key, value) in fields { payload[key] = Self.json(value) }
        store.ingest(HookEnvelope(
            event: event,
            sentAt: clock.now.timeIntervalSince1970,
            env: [:],
            expectsReply: NotchWire.replyEvents.contains(event),
            payload: .object(payload)
        ))
    }

    @discardableResult
    private mutating func start(_ project: Project, _ name: String, at seconds: TimeInterval, input: [String: Any]) -> String {
        toolSeq += 1
        let id = "toolu_snapshot_\(toolSeq)"
        send(project, "PreToolUse", at: seconds, ["tool_name": name, "tool_input": input, "tool_use_id": id])
        return id
    }

    private mutating func finish(
        _ project: Project, _ name: String, id: String, at seconds: TimeInterval,
        input: [String: Any], response: [String: Any]
    ) {
        send(project, "PostToolUse", at: seconds, [
            "tool_name": name, "tool_input": input, "tool_response": response, "tool_use_id": id,
        ])
    }

    private mutating func tool(
        _ project: Project, _ name: String, at seconds: TimeInterval,
        input: [String: Any], response: [String: Any]
    ) {
        let id = start(project, name, at: seconds - 1, input: input)
        finish(project, name, id: id, at: seconds, input: input, response: response)
    }

    private mutating func stream(_ project: Project, at seconds: TimeInterval, _ text: String) {
        send(project, "MessageDisplay", at: seconds, [
            "message_id": "snapshot-message-\(Int(seconds))", "index": 0, "final": true, "delta": text + "\n",
        ])
    }

    /// structuredPatch hunk (삭제 줄 → 추가 줄 순서)
    private static func hunk(newStart: Int, removed: [String], added: [String]) -> [String: Any] {
        hunk(newStart: newStart, lines: removed.map { "-" + $0 } + added.map { "+" + $0 })
    }

    /// structuredPatch hunk (앞에 +/- 가 붙은 줄)
    private static func hunk(newStart: Int, lines: [String]) -> [String: Any] {
        [
            "oldStart": newStart, "oldLines": lines.filter { !$0.hasPrefix("+") }.count,
            "newStart": newStart, "newLines": lines.filter { !$0.hasPrefix("-") }.count,
            "lines": lines,
        ]
    }

    private static func json(_ value: Any) -> JSONValue {
        switch value {
        case let value as JSONValue: return value
        case let value as String: return .string(value)
        case let value as Bool: return .bool(value)
        case let value as Int: return .number(Double(value))
        case let value as Double: return .number(value)
        case let value as [Any]: return .array(value.map(json))
        case let value as [String: Any]: return .object(value.mapValues(json))
        default: return .null
        }
    }
}
