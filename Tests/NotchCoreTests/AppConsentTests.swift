import Foundation
import Testing
@testable import NotchCore
import NotchShared

/// Claude 데스크톱 앱 확인 카드 추정 (`checkStalledTools`)
@MainActor
@Suite struct AppConsentTests {
    let clock = TestClock()
    let desktopEnv = ["__CFBundleIdentifier": "com.anthropic.claudefordesktop", "CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]
    let fullControl = #"{"tool_name":"mcp__computer-use__request_full_control","tool_use_id":"cu1","tool_input":{}}"#
    let consentMessage = "Claude 앱에서 확인이 필요할 수 있어요 · computer-use · request_full_control"

    private func startTurn(_ store: SessionStore, session: String = "s1", env: [String: String]) {
        store.ingest(hook("UserPromptSubmit", session: session, #"{"prompt":"화면 확인해줘"}"#, env: env))
    }

    @Test func desktopStallSignalsOnce() throws {
        let store = makeStore(clock)
        startTurn(store, env: desktopEnv)
        store.ingest(hook("PreToolUse", fullControl, env: desktopEnv))
        let before = store.latestSignal?.seq

        // 지연 전에는 그대로 실행 중
        clock.advance(2)
        store.checkStalledTools()
        #expect(store.sessions["s1"]?.phase == .runningTool)
        #expect(store.latestSignal?.seq == before)

        clock.advance(0.5)
        store.checkStalledTools()
        let s = try #require(store.sessions["s1"])
        #expect(s.phase == .waitingInput)
        #expect(s.currentActivity?.id == "cu1")
        #expect(store.latestSignal?.signal == .needsInput(sessionID: "s1", message: consentMessage))
        let signaled = store.latestSignal?.seq

        // 여러 번 확인해도 신호는 한 번
        for _ in 0..<5 {
            clock.advance()
            store.checkStalledTools()
        }
        #expect(store.latestSignal?.seq == signaled)
        #expect(store.sessions["s1"]?.phase == .waitingInput)
    }

    @Test func entrypointAloneMarksDesktop() {
        let store = makeStore(clock)
        let env = ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]
        startTurn(store, env: env)
        store.ingest(hook("PreToolUse", #"{"tool_name":"mcp__ccd_directory__request_directory","tool_use_id":"d1","tool_input":{}}"#, env: env))
        clock.advance(3)
        store.checkStalledTools()
        #expect(store.sessions["s1"]?.phase == .waitingInput)
        #expect(store.latestSignal?.signal == .needsInput(
            sessionID: "s1",
            message: "Claude 앱에서 확인이 필요할 수 있어요 · ccd_directory · request_directory"
        ))
    }

    @Test func cliSessionNeverSignals() {
        let store = makeStore(clock)
        let env = ["TERM_PROGRAM": "iTerm.app", "CLAUDE_CODE_ENTRYPOINT": "cli"]
        startTurn(store, env: env)
        store.ingest(hook("PreToolUse", fullControl, env: env))
        let before = store.latestSignal?.seq
        clock.advance(10)
        store.checkStalledTools()
        #expect(store.sessions["s1"]?.phase == .runningTool)
        #expect(store.latestSignal?.seq == before)
    }

    @Test func unwatchedAndLongRunningToolsNeverSignal() {
        let store = makeStore(clock)
        startTurn(store, env: desktopEnv)
        let calls = [
            #"{"tool_name":"Bash","tool_use_id":"b1","tool_input":{"command":"sleep 30"}}"#,
            #"{"tool_name":"mcp__computer-use__computer_batch","tool_use_id":"cb1","tool_input":{"actions":[]}}"#,
            #"{"tool_name":"mcp__Claude_Browser__computer","tool_use_id":"w1","tool_input":{"action":"wait","duration":5}}"#,
        ]
        for call in calls {
            store.ingest(hook("PreToolUse", call, env: desktopEnv))
        }
        let before = store.latestSignal?.seq
        clock.advance(10)
        store.checkStalledTools()
        #expect(store.sessions["s1"]?.phase == .runningTool)
        #expect(store.latestSignal?.seq == before)
    }

    @Test func postToolUseClearsWait() throws {
        let store = makeStore(clock)
        startTurn(store, env: desktopEnv)
        store.ingest(hook("PreToolUse", fullControl, env: desktopEnv))
        clock.advance(3)
        store.checkStalledTools()
        #expect(store.sessions["s1"]?.phase == .waitingInput)
        let signaled = store.latestSignal?.seq

        clock.advance()
        store.ingest(hook("PostToolUse", #"{"tool_name":"mcp__computer-use__request_full_control","tool_use_id":"cu1","tool_response":{}}"#, env: desktopEnv))
        var s = try #require(store.sessions["s1"])
        #expect(s.phase == .thinking)
        #expect(s.currentActivity == nil)

        clock.advance(5)
        store.checkStalledTools()
        s = try #require(store.sessions["s1"])
        #expect(s.phase == .thinking)
        #expect(store.latestSignal?.seq == signaled)

        // 다른 호출(새 tool_use_id)은 다시 알린다
        store.ingest(hook("PreToolUse", #"{"tool_name":"mcp__Claude_Browser__navigate","tool_use_id":"n1","tool_input":{"url":"https://example.com"}}"#, env: desktopEnv))
        clock.advance(3)
        store.checkStalledTools()
        #expect(store.sessions["s1"]?.phase == .waitingInput)
        #expect(store.latestSignal?.seq == (signaled ?? 0) + 1)
    }

    @Test func failureStopAndSessionEndClearWait() {
        let failing = makeStore(clock)
        startTurn(failing, env: desktopEnv)
        failing.ingest(hook("PreToolUse", fullControl, env: desktopEnv))
        clock.advance(3)
        failing.checkStalledTools()
        failing.ingest(hook("PostToolUseFailure", #"{"tool_name":"mcp__computer-use__request_full_control","tool_use_id":"cu1","error":"denied"}"#, env: desktopEnv))
        #expect(failing.sessions["s1"]?.phase == .thinking)

        let stopped = makeStore(clock)
        startTurn(stopped, env: desktopEnv)
        stopped.ingest(hook("PreToolUse", fullControl, env: desktopEnv))
        clock.advance(3)
        stopped.checkStalledTools()
        stopped.ingest(hook("Stop", "{}", env: desktopEnv))
        let seq = stopped.latestSignal?.seq
        clock.advance(3)
        stopped.checkStalledTools()
        #expect(stopped.sessions["s1"]?.phase == .completed)
        #expect(stopped.latestSignal?.seq == seq)

        let ended = makeStore(clock)
        startTurn(ended, env: desktopEnv)
        ended.ingest(hook("PreToolUse", fullControl, env: desktopEnv))
        clock.advance(3)
        ended.checkStalledTools()
        ended.ingest(hook("SessionEnd", "{}", env: desktopEnv))
        ended.checkStalledTools()
        #expect(ended.sessions.isEmpty)
    }

    @Test func pendingHookPermissionBlocksAndRestartsDelay() throws {
        let store = makeStore(clock)
        startTurn(store, env: desktopEnv)
        store.ingest(hook("PreToolUse", fullControl, env: desktopEnv))
        clock.advance()
        let requestID = try #require(store.ingest(hook("PermissionRequest", #"{"tool_name":"mcp__computer-use__request_full_control","tool_input":{}}"#, env: desktopEnv)))
        let requested = store.latestSignal?.seq

        // 훅 권한 카드가 떠 있으면 알리지 않는다
        clock.advance(10)
        store.checkStalledTools()
        #expect(store.sessions["s1"]?.phase == .waitingPermission)
        #expect(store.latestSignal?.seq == requested)

        // 승인 직후부터 다시 잰다 (승인 대기 시간은 빼고)
        store.resolvePermission(id: requestID, decision: .allow)
        #expect(store.sessions["s1"]?.phase == .runningTool)
        clock.advance(1)
        store.checkStalledTools()
        #expect(store.latestSignal?.seq == requested)

        clock.advance(1.5)
        store.checkStalledTools()
        #expect(store.sessions["s1"]?.phase == .waitingInput)
        #expect(store.latestSignal?.signal == .needsInput(sessionID: "s1", message: consentMessage))
    }

    /// 훅 권한 요청이 거부 · 터미널로 넘김 · 취소 · 정리로 끝나면 그 툴은 실행되지 않았을 수 있어 (PostToolUse 가 오지 않음) 지켜보지 않는다
    @Test(arguments: ["거부", "터미널로", "취소", "서브에이전트 끝남"])
    func unresolvedHookPermissionStopsWatching(_ outcome: String) throws {
        let store = makeStore(clock)
        startTurn(store, env: desktopEnv)
        let agent = outcome == "서브에이전트 끝남" ? #","agent_id":"sub1""# : ""
        store.ingest(hook("PreToolUse", #"{"tool_name":"mcp__Claude_Browser__navigate","tool_use_id":"n1"\#(agent),"tool_input":{"url":"https://example.com"}}"#, env: desktopEnv))
        clock.advance()
        let requestID = try #require(store.ingest(hook(
            "PermissionRequest", #"{"tool_name":"mcp__Claude_Browser__navigate"\#(agent),"tool_input":{"url":"https://example.com"}}"#, env: desktopEnv
        )))
        clock.advance()
        switch outcome {
        case "거부": store.resolvePermission(id: requestID, decision: .deny(message: nil))
        case "터미널로": store.resolvePermission(id: requestID, decision: .passthrough)
        case "취소": store.cancelPermission(id: requestID)
        default: store.ingest(hook("SubagentStop", #"{"agent_id":"sub1","agent_type":"general-purpose"}"#, env: desktopEnv))
        }
        #expect(store.pendingPermissions.isEmpty)
        let seq = store.latestSignal?.seq

        clock.advance(3)
        store.checkStalledTools()
        #expect(store.sessions["s1"]?.phase != .waitingInput)

        // Claude 가 다음 툴로 넘어가도 남아 있는 거부된 툴로 입력 대기가 되지 않는다
        store.ingest(hook("PreToolUse", #"{"tool_name":"Read","tool_use_id":"r1","tool_input":{"file_path":"/Users/dev/projects/api-server/a.ts"}}"#, env: desktopEnv))
        clock.advance(3)
        store.checkStalledTools()
        #expect(store.sessions["s1"]?.phase == .runningTool)
        store.ingest(hook("PostToolUse", #"{"tool_name":"Read","tool_use_id":"r1","tool_response":{}}"#, env: desktopEnv))
        clock.advance(3)
        store.checkStalledTools()
        #expect(store.sessions["s1"]?.phase != .waitingInput)
        #expect(store.latestSignal?.seq == seq)
    }

    @Test func deniedPermissionDropsOnlyMatchingCall() throws {
        let store = makeStore(clock)
        startTurn(store, env: desktopEnv)
        // 같은 툴의 두 호출: 권한 요청(tool_use_id 없음)은 입력이 같은 호출에 잇는다
        store.ingest(hook("PreToolUse", #"{"tool_name":"mcp__Claude_Browser__navigate","tool_use_id":"n1","tool_input":{"url":"https://a.example.com"}}"#, env: desktopEnv))
        store.ingest(hook("PreToolUse", #"{"tool_name":"mcp__Claude_Browser__navigate","tool_use_id":"n2","tool_input":{"url":"https://b.example.com"}}"#, env: desktopEnv))
        let requestID = try #require(store.ingest(hook(
            "PermissionRequest", #"{"tool_name":"mcp__Claude_Browser__navigate","tool_input":{"url":"https://a.example.com"}}"#, env: desktopEnv
        )))
        store.resolvePermission(id: requestID, decision: .deny(message: nil))
        let seq = store.latestSignal?.seq

        // 거부 직후(thinking)에는 새로 알리지 않는다
        clock.advance(3)
        store.checkStalledTools()
        #expect(store.sessions["s1"]?.phase == .thinking)
        #expect(store.latestSignal?.seq == seq)

        // 다시 툴 실행 중이 되면 아직 지켜보는 n2 만 알린다 (서브에이전트의 툴: 메인 에이전트의 새 툴이면 앞 차례 n2 는 끝난 것으로 본다)
        store.ingest(hook("PreToolUse", #"{"tool_name":"Read","tool_use_id":"r1","agent_id":"sub1","tool_input":{"file_path":"/Users/dev/projects/api-server/a.ts"}}"#, env: desktopEnv))
        store.checkStalledTools()
        let s = try #require(store.sessions["s1"])
        #expect(s.phase == .waitingInput)
        #expect(s.currentActivity?.id == "n2")
        #expect(store.latestSignal?.signal == .needsInput(
            sessionID: "s1", message: "Claude 앱에서 확인이 필요할 수 있어요 · \(s.currentActivity?.title ?? "")"
        ))
    }

    @Test func otherWaitsAreNotOverridden() {
        let store = makeStore(clock)
        startTurn(store, env: desktopEnv)
        store.ingest(hook("PreToolUse", fullControl, env: desktopEnv))
        // Claude Code 자체 승인 다이얼로그(훅 대기 없음)가 떠 있으면 그대로 둔다
        store.ingest(hook("Notification", #"{"notification_type":"permission_prompt","message":"Claude needs your permission"}"#, env: desktopEnv))
        let seq = store.latestSignal?.seq
        clock.advance(5)
        store.checkStalledTools()
        #expect(store.sessions["s1"]?.phase == .waitingPermission)
        #expect(store.latestSignal?.seq == seq)
    }

    @Test func signaledWaitSurvivesParallelToolEnd() throws {
        let store = makeStore(clock)
        startTurn(store, env: desktopEnv)
        store.ingest(hook("PreToolUse", #"{"tool_name":"Read","tool_use_id":"r1","tool_input":{"file_path":"/Users/dev/projects/api-server/a.ts"}}"#, env: desktopEnv))
        store.ingest(hook("PreToolUse", fullControl, env: desktopEnv))
        clock.advance(3)
        store.checkStalledTools()
        let signaled = store.latestSignal?.seq

        // 병렬 툴이 끝나도 확인 카드를 기다리는 툴이 남아 있으면 입력 대기 유지 (다시 알리지 않음)
        store.ingest(hook("PostToolUse", #"{"tool_name":"Read","tool_use_id":"r1","tool_response":{}}"#, env: desktopEnv))
        let s = try #require(store.sessions["s1"])
        #expect(s.phase == .waitingInput)
        #expect(s.currentActivity?.id == "cu1")
        #expect(store.latestSignal?.seq == signaled)
    }

    @Test func heuristicRules() {
        let rules = AppConsentHeuristic.default
        #expect(rules.watches(toolName: "mcp__computer-use__request_access", toolInput: nil))
        #expect(rules.watches(toolName: "mcp__claude-in-chrome__navigate", toolInput: json(#"{"url":"https://example.com"}"#)))
        #expect(rules.watches(toolName: "mcp__ccd_directory__change_directory", toolInput: nil))
        #expect(!rules.watches(toolName: "mcp__ccd_directory__list", toolInput: nil))
        #expect(!rules.watches(toolName: "mcp__Claude_Browser__browser_batch", toolInput: nil))
        #expect(!rules.watches(toolName: "mcp__claude-in-chrome__computer", toolInput: json(#"{"action":"wait"}"#)))
        #expect(rules.watches(toolName: "mcp__claude-in-chrome__computer", toolInput: json(#"{"action":"left_click"}"#)))
        #expect(!rules.watches(toolName: "Bash", toolInput: nil))
    }

    /// 허용 목록: 확인 카드를 띄우는 툴만 2.5초, 첫 방문 사이트 승인을 띄울 수 있는 페이지 툴은 8초, 나머지는 지켜보지 않는다
    @Test func allowlistDelays() {
        let rules = AppConsentHeuristic.default
        for name in [
            "mcp__computer-use__request_access", "mcp__computer-use__request_full_control", "mcp__computer-use__request_teach_access",
            "mcp__ccd_directory__request_directory", "mcp__ccd_directory__change_directory",
            "mcp__Claude_Browser__navigate", "mcp__claude-in-chrome__navigate",
            "mcp__claude-in-chrome__select_browser", "mcp__claude-in-chrome__switch_browser",
        ] {
            #expect(rules.delay(toolName: name, toolInput: nil) == AppConsentHeuristic.consentDelay, "\(name)")
        }
        for prefix in ["mcp__Claude_Browser__", "mcp__claude-in-chrome__"] {
            for tool in ["computer", "find", "form_input", "get_page_text", "javascript_tool", "read_page"] {
                #expect(rules.delay(toolName: prefix + tool, toolInput: nil) == AppConsentHeuristic.pageActionDelay, "\(prefix + tool)")
            }
        }
        #expect(AppConsentHeuristic.pageActionDelay >= 8)
        // 예전에 접두사로 지켜보던 느린 툴 (앱 첫 실행 · 스크린샷 · 묶음 · 개발 서버 · 탭 · 콘솔 등)
        for name in [
            "mcp__computer-use__open_application", "mcp__computer-use__app_screenshot", "mcp__computer-use__computer_batch",
            "mcp__computer-use__list_apps", "mcp__computer-use__teach_step", "mcp__Claude_Browser__browser_batch",
            "mcp__Claude_Browser__preview_start", "mcp__Claude_Browser__tabs_create", "mcp__claude-in-chrome__tabs_create_mcp",
            "mcp__claude-in-chrome__read_console_messages", "mcp__claude-in-chrome__gif_creator", "mcp__claude-in-chrome__shortcuts_execute",
        ] {
            #expect(rules.delay(toolName: name, toolInput: nil) == nil, "\(name)")
        }
        // 기다리기 동작은 페이지 툴이어도 지켜보지 않는다
        #expect(rules.delay(toolName: "mcp__Claude_Browser__computer", toolInput: json(#"{"action":"wait","duration":5}"#)) == nil)
    }

    /// 느린 앱 · 브라우저 호출이 확인 카드로 잘못 뜨지 않는다 (예전에는 2.5초가 지나면 모두 "확인이 필요할 수 있어요" 카드)
    @Test func slowCallsOutsideAllowlistNeverSignal() {
        let store = makeStore(clock)
        startTurn(store, env: desktopEnv)
        let calls = [
            #"{"tool_name":"mcp__computer-use__open_application","tool_use_id":"o1","tool_input":{"app":"Xcode"}}"#,
            #"{"tool_name":"mcp__Claude_Browser__preview_start","tool_use_id":"p1","tool_input":{"name":"web"}}"#,
            #"{"tool_name":"mcp__claude-in-chrome__tabs_create_mcp","tool_use_id":"t1","tool_input":{}}"#,
        ]
        for call in calls {
            store.ingest(hook("PreToolUse", call, env: desktopEnv))
        }
        let before = store.latestSignal?.seq
        clock.advance(30)
        store.checkStalledTools()
        #expect(store.sessions["s1"]?.phase == .runningTool)
        #expect(store.latestSignal?.seq == before)
    }

    /// 페이지를 다루는 브라우저 툴은 훨씬 길게(8초) 기다린 뒤에만 확인 대기로 본다
    @Test(arguments: ["mcp__Claude_Browser__find", "mcp__claude-in-chrome__javascript_tool", "mcp__Claude_Browser__computer"])
    func pageActionWaitsLonger(tool: String) throws {
        let store = makeStore(clock)
        startTurn(store, env: desktopEnv)
        store.ingest(hook("PreToolUse", #"{"tool_name":"\#(tool)","tool_use_id":"pa1","tool_input":{"action":"left_click"}}"#, env: desktopEnv))
        let before = store.latestSignal?.seq

        clock.advance(7.5)
        store.checkStalledTools()
        #expect(store.sessions["s1"]?.phase == .runningTool)
        #expect(store.latestSignal?.seq == before)

        clock.advance(0.5)
        store.checkStalledTools()
        let s = try #require(store.sessions["s1"])
        #expect(s.phase == .waitingInput)
        #expect(s.currentActivity?.id == "pa1")
        #expect(store.latestSignal?.seq == (before ?? 0) + 1)
    }

    /// 세션을 띄운 앱 판단: 번들 ID → 알려진 `TERM_PROGRAM` → 진입점("desktop") 순서
    @Test func hostBundleIdentifier() {
        func host(_ context: TerminalContext) -> String? { context.hostBundleIdentifier }
        #expect(host(TerminalContext(termProgram: "iTerm.app")) == "com.googlecode.iterm2")
        #expect(host(TerminalContext(termProgram: "Apple_Terminal")) == "com.apple.Terminal")
        #expect(host(TerminalContext(termProgram: "vscode")) == "com.microsoft.VSCode")
        #expect(host(TerminalContext(termProgram: "WarpTerminal")) == "dev.warp.Warp-Stable")
        #expect(host(TerminalContext(termProgram: "ghostty")) == "com.mitchellh.ghostty")
        #expect(host(TerminalContext(termProgram: "WezTerm")) == "com.github.wez.wezterm")
        #expect(host(TerminalContext(termProgram: "zed")) == "dev.zed.Zed")
        #expect(host(TerminalContext(entrypoint: "claude-desktop")) == TerminalContext.claudeDesktopBundleID)
        // 번들 ID 가 있으면 그것을 우선
        #expect(host(TerminalContext(termProgram: "tmux", bundleIdentifier: "com.googlecode.iterm2")) == "com.googlecode.iterm2")
        #expect(host(TerminalContext(termProgram: "vscode", bundleIdentifier: "com.todesktop.230313mzl4w4u92")) == "com.todesktop.230313mzl4w4u92")
        #expect(host(TerminalContext(bundleIdentifier: " ", entrypoint: "claude-desktop")) == TerminalContext.claudeDesktopBundleID)
        #expect(host(TerminalContext(termProgram: "tmux")) == nil)
        #expect(host(TerminalContext()) == nil)
    }

    /// Claude 데스크톱 앱 판단은 점프 대상(`hostBundleIdentifier`)과 같은 규칙
    @Test func claudeDesktopAppFollowsHostRule() {
        #expect(TerminalContext(bundleIdentifier: "com.anthropic.claudefordesktop").isClaudeDesktopApp)
        #expect(TerminalContext(entrypoint: "claude-desktop").isClaudeDesktopApp)
        #expect(!TerminalContext(termProgram: "iTerm.app", entrypoint: "cli").isClaudeDesktopApp)
        #expect(!TerminalContext().isClaudeDesktopApp)
        // 알려진 터미널이 아니면(tmux 등) 진입점을 본다
        #expect(TerminalContext(termProgram: "tmux", entrypoint: "claude-desktop").isClaudeDesktopApp)
        // 알려진 터미널 · 다른 앱 번들 ID 가 있으면 진입점이 desktop 이어도 그 앱이다
        #expect(!TerminalContext(termProgram: "iTerm.app", entrypoint: "claude-desktop").isClaudeDesktopApp)
        #expect(!TerminalContext(bundleIdentifier: "com.googlecode.iterm2", entrypoint: "claude-desktop").isClaudeDesktopApp)
    }

    /// "Claude로": Claude 앱이 세션마다 붙이는 ID 로 앱 안의 그 세션을 여는 링크
    @Test func claudeDesktopSessionLink() {
        let id = "local_a65649ae-3ef5-4e30-84b0-a0579b35fcff"
        let context = TerminalContext(environment: [
            "__CFBundleIdentifier": TerminalContext.claudeDesktopBundleID,
            "CLAUDE_CODE_ENTRYPOINT": "claude-desktop",
            "CLAUDE_CODE_HOST_SESSION_ID": id,
        ])
        #expect(context.hostSessionID == id)
        #expect(context.claudeDesktopSessionURL?.absoluteString == "claude://code/continue?session=\(id)")

        // Claude 앱 세션이 아니면(터미널) 링크가 없다
        #expect(TerminalContext(termProgram: "iTerm.app", hostSessionID: id).claudeDesktopSessionURL == nil)
        // 앱이 받는 모양(local_ + 영문 · 숫자 · 하이픈 64자 이하)이 아니면 링크를 만들지 않는다
        func link(_ raw: String) -> URL? {
            TerminalContext(entrypoint: "claude-desktop", hostSessionID: raw).claudeDesktopSessionURL
        }
        #expect(link("local_abc-123") != nil)
        #expect(link("local_" + String(repeating: "a", count: 64)) != nil)
        #expect(link("local_" + String(repeating: "a", count: 65)) == nil)
        #expect(link("local_") == nil)
        #expect(link("cse_abc") == nil)
        #expect(link("local_abc&session=other") == nil)
        #expect(link("local_ab/../c") == nil)
        #expect(link("local_한글") == nil)
        #expect(TerminalContext(entrypoint: "claude-desktop").claudeDesktopSessionURL == nil)
    }
}
