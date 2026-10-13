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

        // 다시 툴 실행 중이 되면 아직 지켜보는 n2 만 알린다
        store.ingest(hook("PreToolUse", #"{"tool_name":"Read","tool_use_id":"r1","tool_input":{"file_path":"/Users/dev/projects/api-server/a.ts"}}"#, env: desktopEnv))
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

        #expect(TerminalContext(bundleIdentifier: "com.anthropic.claudefordesktop").isClaudeDesktopApp)
        #expect(TerminalContext(entrypoint: "claude-desktop").isClaudeDesktopApp)
        #expect(!TerminalContext(termProgram: "iTerm.app", entrypoint: "cli").isClaudeDesktopApp)
        #expect(!TerminalContext().isClaudeDesktopApp)
    }
}
