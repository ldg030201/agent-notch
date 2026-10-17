import Foundation
import Observation
import NotchCore
import NotchShared

// 스냅숏 렌더링용 가짜 데이터. 실제 사용자 설정 · 파일 · 네트워크를 건드리지 않는다.

/// 디스크에 쓰지도, 사용자 설정을 읽지도 않는 메모리 전용 UserDefaults
final class MemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    /// `UserDefaults.init()` 과 겹치지 않게 인자를 하나 둔다 (실패할 수 있는 이니셜라이저라 `guard let` 으로 받는다)
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

/// 표시 상태의 시계 (부팅 후 초, `PresentationController.uptime`). 스냅숏은 렌더링이 느려도 같은 그림이 되도록 멈춰 두고
/// 필요할 때만 앞으로 돌린다 (접히는 동안 붙잡은 카드 띠를 놓을 시각이 지남 등)
@MainActor
final class SnapshotUptime {
    private(set) var now: TimeInterval = 1000

    func advance(by seconds: TimeInterval) {
        now += seconds
    }
}

/// 아무것도 하지 않는 동작 (렌더링 전용). 권한 결정만 검사용으로 받아 볼 수 있다
@MainActor
final class SnapshotActions: IslandActions {
    /// 전달된 권한 결정 (승인 대기 검사 `SnapshotDecisionCheck`)
    var onResolvePermission: ((UUID, PermissionDecision) -> Void)?

    func resolvePermission(id: UUID, decision: PermissionDecision) {
        onResolvePermission?(id, decision)
    }
    func handOff(requestID: UUID) {}
    func jumpToTerminal(sessionID: String) {}
    func openFile(path: String) {}
    func togglePin(sessionID: String) {}
    func focus(sessionID: String) {}
    func dismiss(sessionID: String) {}
}

@MainActor
final class SnapshotSettingsProvider: SettingsProvider {
    var appVersion: String { "0.1.0" }
    var hookState: (text: String, installed: Bool) { ("설치됨 · 이벤트 14개", true) }
    func installHooks() throws {}
    func uninstallHooks() throws {}
    var launchAtLoginEnabled: Bool { true }
    var launchAtLoginManagedByHomebrew: Bool { false }
    func setLaunchAtLogin(_ enabled: Bool) throws {}
    var globalShortcut: GlobalShortcutState? { nil }
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
            .init(title: "알림", icon: "bell.fill", isNew: true, notes: [
                .init(kind: "new", text: "세션별 알림 끄기"),
                .init(kind: "new", text: "조용한 시간 설정"),
            ]),
        ]),
        ChangelogDisplayEntry(version: "0.2.0", date: "2026-01-14", groups: [
            .init(title: "표시", icon: "display", notes: [
                .init(kind: "improve", text: "외부 모니터 알약 간격 개선"),
                .init(kind: "fix", text: "열린 메뉴 위로 카드가 겹치던 문제 수정"),
            ]),
            .init(title: "권한 · 질문", icon: "hand.raised.fill", notes: [
                .init(kind: "new", text: "권한 카드 접기 추가"),
            ]),
        ]),
        ChangelogDisplayEntry(version: "0.1.0", date: "2026-01-02", groups: [
            // 아이콘이 없는 예전 내역 (점으로 보인다)
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
    func dismissUpgrade() {}
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
    static let docsSite = Project(id: "snapshot-docs-site", name: "docs-site")
    static let mobileApp = Project(id: "snapshot-mobile-app", name: "mobile-app")

    let clock: SnapshotClock
    let store: SessionStore
    private var toolSeq = 0
    /// 프로젝트(세션 ID)별 훅 환경변수 (세션을 띄운 앱). 없으면 빈 환경
    var hostEnvironment: [String: [String: String]] = [:]

    /// Claude 데스크톱 앱에서 돌아가는 세션의 환경변수 (예시 값)
    static let desktopEnvironment = [
        "__CFBundleIdentifier": TerminalContext.claudeDesktopBundleID,
        "CLAUDE_CODE_ENTRYPOINT": "claude-desktop",
    ]

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

    /// 세션 둘 더 (쉬는 중) — 다른 세션 상태 요약 장면용 (모두 5개)
    mutating func startMoreSessions() {
        send(Self.docsSite, "SessionStart", at: 400, ["source": "startup"])
        send(Self.mobileApp, "SessionStart", at: 420, ["source": "startup"])
    }

    /// 펼친 목록 장면용 다른 세션들: blog 는 오타를 고치고 끝남(미확인 완료), docs-site 는 답변은 끝나고 문서 서버(백그라운드 셸)만 도는 중,
    /// web-app 은 파일을 고치는 중. `startMoreSessions` 다음, `apiServerEdits` 전에 부른다 (mobile-app 은 쉬는 중 그대로)
    mutating func otherSessionsAtWork() {
        let blog = Self.blog
        send(blog, "UserPromptSubmit", at: 430, ["prompt": "글 오타 고쳐줘"])
        let post = "\(blog.cwd)/posts/hello.md"
        tool(blog, "Edit", at: 440, input: ["file_path": post], response: [
            "filePath": post, "structuredPatch": [Self.hunk(newStart: 3, removed: ["안녕하새요"], added: ["안녕하세요"])],
        ])
        send(blog, "Stop", at: 445, ["stop_hook_active": false, "last_assistant_message": "오타 한 군데 고쳤어."])

        let docs = Self.docsSite
        send(docs, "UserPromptSubmit", at: 460, ["prompt": "문서 사이트 띄워줘"])
        tool(docs, "Bash", at: 465, input: ["command": "npm run docs", "description": "문서 서버", "run_in_background": true], response: [
            "stdout": "", "stderr": "", "interrupted": false, "backgroundTaskId": "snapshot-docs-shell",
        ])
        send(docs, "Stop", at: 470, ["stop_hook_active": false, "last_assistant_message": "문서 서버 띄워 뒀어."])
        // 끝난 답변은 이미 확인함 (목록에 "완료" 대신 "백그라운드 1개 작업 중")
        store.markSeen(sessionID: docs.id)

        let web = Self.webApp
        send(web, "UserPromptSubmit", at: 560, ["prompt": "로그인 폼에 입력 검사 넣어줘"])
        let form = "\(web.cwd)/src/LoginForm.tsx"
        tool(web, "Read", at: 565, input: ["file_path": form], response: ["type": "text"])
        start(web, "Edit", at: 570, input: ["file_path": form, "old_string": "onSubmit(values)", "new_string": "if (validate(values)) onSubmit(values)"])
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

    /// api-server: 개발 서버를 백그라운드 셸로 띄우고 서브에이전트 2개가 도는 중 (접힌 상태 배지 "⧉ 3").
    /// `apiServerEdits` 다음, `apiServerRunsTests` 전에 부른다
    mutating func apiServerStartsBackgroundWork() {
        let api = Self.apiServer
        tool(api, "Bash", at: 613.5, input: ["command": "npm run dev", "description": "개발 서버", "run_in_background": true], response: [
            "stdout": "", "stderr": "", "interrupted": false, "backgroundTaskId": "snapshot-shell-1",
        ])
        send(api, "SubagentStart", at: 613.7, ["agent_id": "snapshot-agent-1", "agent_type": "Explore"])
        send(api, "SubagentStart", at: 613.8, ["agent_id": "snapshot-agent-2", "agent_type": "Plan"])
    }

    /// api-server: 테스트 실행 중 (접힌 상태 · 펼침에 스피너)
    mutating func apiServerRunsTests() {
        start(Self.apiServer, "Bash", at: 614, input: ["command": "npm test", "description": "테스트 실행"])
        clock.set(842)
    }

    /// api-server: MCP 브라우저 툴 실행 중 (제목이 긴 툴, 이번 턴 수정 없음)
    mutating func apiServerUsesBrowser() {
        let api = Self.apiServer
        send(api, "UserPromptSubmit", at: 600, ["prompt": "로그인 화면이 제대로 뜨는지 브라우저로 확인해줘"])
        start(api, "mcp__Claude_Browser__browser_batch", at: 614, input: ["actions": [["name": "navigate"], ["name": "computer"]]])
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

    /// 세션 하나가 새 턴에서 긴 Bash 명령을 실행 (접힌 상태엔 짧은 이름 "Bash" 만, 명령은 펼친 타임라인에)
    mutating func runsLongCommand(_ project: Project, at seconds: TimeInterval) {
        send(project, "UserPromptSubmit", at: seconds, ["prompt": "빌드해서 확인해줘"])
        start(project, "Bash", at: seconds + 2, input: [
            "command": "SP=/private/tmp/build && swift build --scratch-path $SP/debug 2>&1 | tail -5",
            "description": "빌드",
        ])
        clock.set(seconds + 4)
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

    /// web-app: 빌드 결과물 삭제 권한 요청 (`permission-desktop`: Claude 앱 세션도 노치에서 바로 허용 · 거부)
    mutating func webAppAsksDeletePermission() {
        let web = Self.webApp
        send(web, "UserPromptSubmit", at: 820, ["prompt": "빌드 결과물 지우고 처음부터 다시 빌드해줘"])
        let command: [String: Any] = ["command": "rm -rf dist .next", "description": "빌드 결과물 삭제"]
        start(web, "Bash", at: 830, input: command)
        send(web, "PermissionRequest", at: 831, [
            "tool_name": "Bash",
            "tool_input": command,
            "permission_suggestions": [[
                "type": "addRules",
                "rules": [["toolName": "Bash", "ruleContent": "rm -rf dist .next"]],
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

    /// blog: 노치에서 답하는 질문 (지금 훅 설정: 질문 툴의 PreToolUse 가 노치의 답을 기다림)
    mutating func blogAsksInNotch(_ questions: [[String: Any]]) {
        let blog = Self.blog
        send(blog, "UserPromptSubmit", at: 760, ["prompt": "새 글 배포해줘"])
        startWaiting(blog, "AskUserQuestion", at: 770, input: ["questions": questions])
        clock.set(772)
    }

    /// 노치 질문 장면의 질문들 (예시 내용)
    static let deployImageQuestion: [String: Any] = [
        "question": "배포 전에 이미지도 같이 최적화할까요?",
        "header": "이미지",
        "multiSelect": false,
        "options": [
            ["label": "같이 하기 (Recommended)", "description": "WebP 로 바꾸고 용량을 줄임 (약 2분)"],
            ["label": "건너뛰기", "description": "지금 이미지 그대로 배포"],
            ["label": "새 이미지만", "description": "이번 글에 추가된 이미지 3개만 최적화"],
        ],
    ]
    static let deployChecksQuestion: [String: Any] = [
        "question": "배포 전에 어떤 검사를 돌릴까요?",
        "header": "검사",
        "multiSelect": true,
        "options": [
            ["label": "링크 검사", "description": "깨진 내부 · 외부 링크 찾기"],
            ["label": "맞춤법", "description": "새 글 본문만"],
            ["label": "빌드", "description": "정적 사이트 전체 빌드"],
            ["label": "미리보기 배포", "description": "스테이징 주소에 먼저 올리기"],
        ],
    ]
    static let deployTargetQuestion: [String: Any] = [
        "question": "어느 환경에 배포할까요?",
        "header": "환경",
        "multiSelect": false,
        "options": [["label": "프로덕션"], ["label": "스테이징"]],
    ]
    static let deployNoticeQuestion: [String: Any] = [
        "question": "배포가 끝나면 어디로 알릴까요?",
        "header": "알림",
        "multiSelect": true,
        "options": [["label": "메일"], ["label": "슬랙 #blog"], ["label": "알리지 않음"]],
    ]

    /// blog: 계획 모드에서 세운 배포 계획 승인 요청 (지금 훅 설정)
    mutating func blogAsksPlanApproval() {
        let blog = Self.blog
        send(blog, "UserPromptSubmit", at: 760, ["prompt": "새 글 배포 계획 세워줘"])
        startWaiting(blog, "ExitPlanMode", at: 770, input: [
            "plan": """
            # 새 글 배포 계획

            1. 이미지 최적화 (WebP 변환, 최대 폭 1600px)
            2. 정적 사이트 빌드 후 링크 검사
            3. 스테이징에 먼저 올려 미리보기 확인
            4. 프로덕션 배포 · 캐시 무효화
            5. RSS · 사이트맵 갱신 확인
            6. 배포 결과를 변경 내역에 기록
            """,
            "planFilePath": "/Users/dev/.claude/plans/blog-deploy.md",
        ])
        clock.set(772)
    }

    // MARK: 이벤트 만들기

    /// 훅 이벤트 하나. `expectsReply` 가 nil 이면 늘 기다리는 이벤트(PermissionRequest)만 응답을 기다린다
    /// (예전 훅 설정처럼 질문 툴의 PreToolUse 는 기다리지 않음 → 입력 대기 카드)
    mutating func send(
        _ project: Project, _ event: String, at seconds: TimeInterval, _ fields: [String: Any], expectsReply: Bool? = nil
    ) {
        clock.set(seconds)
        var payload: [String: JSONValue] = [
            "session_id": .string(project.id),
            "cwd": .string(project.cwd),
            "hook_event_name": .string(event),
            "permission_mode": .string("default"),
        ]
        for (key, value) in fields { payload[key] = JSONValue(any: value) }
        store.ingest(HookEnvelope(
            event: event,
            sentAt: clock.now.timeIntervalSince1970,
            env: hostEnvironment[project.id] ?? [:],
            expectsReply: expectsReply ?? NotchWire.replyEvents.contains(event),
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

    /// 헬퍼가 노치의 답을 기다리는 툴 호출 (질문 · 계획 승인의 PreToolUse)
    @discardableResult
    private mutating func startWaiting(_ project: Project, _ name: String, at seconds: TimeInterval, input: [String: Any]) -> String {
        toolSeq += 1
        let id = "toolu_snapshot_\(toolSeq)"
        let fields: [String: Any] = ["tool_name": name, "tool_input": input, "tool_use_id": id]
        send(project, "PreToolUse", at: seconds, fields, expectsReply: NotchWire.expectsReply(
            event: "PreToolUse", toolName: name, hasReplyTimeout: true
        ))
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
}
