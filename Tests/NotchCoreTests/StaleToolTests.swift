import Foundation
import Testing
@testable import NotchCore
import NotchShared

/// 끝났다는 이벤트가 오지 않는 툴 · 노치 대기 시간이 지난 질문
@MainActor
@Suite("남은 툴 · 질문 대기 시간")
struct StaleToolTests {
    let clock = TestClock()
    let desktopEnv = ["__CFBundleIdentifier": "com.anthropic.claudefordesktop", "CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]

    /// 다른 훅에 막힌 툴(PreToolUse hook error)은 PostToolUse · PostToolUseFailure 가 오지 않는다.
    /// 앱 확인 추정 카드가 떴더라도, 같은 에이전트가 다음 툴을 시작하면 그 툴은 끝난 것이라 카드가 내려간다
    @Test func blockedToolEndsWhenNextToolStarts() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"메인 폴더로 옮겨줘"}"#, env: desktopEnv))
        store.ingest(hook("PreToolUse", #"{"tool_name":"mcp__ccd_directory__change_directory","tool_use_id":"cd1","tool_input":{"path":"/Users/dev/projects/f1"}}"#, env: desktopEnv))
        clock.advance(3)
        store.checkStalledTools()
        #expect(store.sessions["s1"]?.phase == .waitingInput)

        // 모델이 막힌 결과를 받고 다음 툴을 부른다
        clock.advance(5)
        store.ingest(hook("PreToolUse", #"{"tool_name":"ToolSearch","tool_use_id":"ts1","tool_input":{"query":"select:x"}}"#, env: desktopEnv))
        var s = try #require(store.sessions["s1"])
        #expect(s.phase == .runningTool)
        #expect(s.currentActivity?.id == "ts1")
        #expect(s.activities.first { $0.id == "cd1" }?.status == .failed)
        // 다시 재도 알리지 않는다
        clock.advance(5)
        let seq = store.latestSignal?.seq
        store.checkStalledTools()
        #expect(store.latestSignal?.seq == seq)

        // 늦게라도 결과가 오면 바로잡는다
        store.ingest(hook("PostToolUse", #"{"tool_name":"mcp__ccd_directory__change_directory","tool_use_id":"cd1","tool_response":{}}"#, env: desktopEnv))
        s = try #require(store.sessions["s1"])
        #expect(s.activities.first { $0.id == "cd1" }?.status == .succeeded)
    }

    /// 병렬로 함께 부른 툴(거의 같은 때 시작) · 다른 에이전트의 툴 · 서브에이전트를 띄운 툴은 닫지 않는다
    @Test func parallelAndOtherAgentToolsStay() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"찾아줘"}"#))
        store.ingest(hook("PreToolUse", #"{"tool_name":"Agent","tool_use_id":"a1","tool_input":{"description":"탐색"}}"#))
        store.ingest(hook("PreToolUse", #"{"tool_name":"WebFetch","tool_use_id":"w1","tool_input":{"url":"https://a.example.com"}}"#))
        clock.advance(1)
        store.ingest(hook("PreToolUse", #"{"tool_name":"WebFetch","tool_use_id":"w2","tool_input":{"url":"https://b.example.com"}}"#))
        clock.advance(10)
        // 서브에이전트의 툴은 메인 에이전트의 툴을 닫지 않는다
        store.ingest(hook("PreToolUse", #"{"tool_name":"Read","tool_use_id":"r1","agent_id":"sub1","tool_input":{"file_path":"/Users/dev/projects/api-server/a.ts"}}"#))
        let s = try #require(store.sessions["s1"])
        for id in ["a1", "w1", "w2", "r1"] {
            #expect(s.activities.first { $0.id == id }?.status == .running, "\(id)")
        }
    }

    @Test func interactionsWaitLongerThanPermissions() {
        let preferences = AppPreferences(defaults: UserDefaults(suiteName: "agentnotch-test-\(UUID().uuidString)")!)
        preferences.permissionTimeout = 120
        #expect(preferences.replyTimeout(isInteraction: false) == 120)
        #expect(preferences.replyTimeout(isInteraction: true) == Double(NotchWire.maxAppReplyTimeout))
        #expect(AppPreferences.interactionTimeout > 500)
    }

    /// 노치 대기 시간이 지난 질문: 입력 대기 카드가 왜 선택지가 없는지 알려 준다 (세션 앱마다 다른 이름)
    @Test func expiredQuestionExplainsHandOff() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"배포해줘"}"#, env: desktopEnv))
        var envelope = hook("PreToolUse", #"{"tool_name":"AskUserQuestion","tool_use_id":"q1","tool_input":{"questions":[{"question":"어디에 배포할까?","header":"대상","multiSelect":false,"options":[{"label":"스테이징"},{"label":"운영"}]}]}}"#, env: desktopEnv)
        envelope.expectsReply = true
        let id = try #require(store.ingest(envelope))

        store.expirePermission(id: id)
        #expect(store.pendingPermissions.isEmpty)
        #expect(store.sessions["s1"]?.phase == .waitingInput)
        #expect(store.latestSignal?.signal == .needsInput(
            sessionID: "s1", message: "노치에서 기다리는 시간이 지나 Claude 앱으로 넘겼어요. 앱에서 답해 주세요"
        ))
        #expect(SessionStore.expiredInteractionMessage(TerminalContext(termProgram: "iTerm.app")) == "노치에서 기다리는 시간이 지나 터미널로 넘겼어요. 터미널에서 답해 주세요")
        #expect(SessionStore.expiredInteractionMessage(TerminalContext(originator: "Codex")).hasPrefix("노치에서 기다리는 시간이 지나 Codex 앱으로"))
    }
}

/// 자동 모드 거부 (`PermissionDenied`): 실행되지 않아 PostToolUse · PostToolUseFailure 가 오지 않는 호출을 닫는다
@MainActor
@Suite("자동 모드 거부")
struct PermissionDeniedTests {
    let clock = TestClock()
    let desktopEnv = ["__CFBundleIdentifier": "com.anthropic.claudefordesktop", "CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]

    @Test func deniedToolClosesAndConsentCardGoes() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"메인 폴더로"}"#, env: desktopEnv))
        // 자동 모드: 검사기를 기다리는 동안 10초까지는 앱 확인으로 보지 않는다
        store.ingest(hook("PreToolUse", #"{"tool_name":"mcp__ccd_directory__change_directory","tool_use_id":"cd1","permission_mode":"auto","tool_input":{"path":"/Users/dev/projects/f1"}}"#, env: desktopEnv))
        clock.advance(6)
        store.checkStalledTools()
        #expect(store.sessions["s1"]?.phase == .runningTool)
        clock.advance(5)
        store.checkStalledTools()
        #expect(store.sessions["s1"]?.phase == .waitingInput)

        store.ingest(hook("PermissionDenied", #"{"tool_name":"mcp__ccd_directory__change_directory","tool_use_id":"cd1","permission_mode":"auto","tool_input":{"path":"/Users/dev/projects/f1"},"reason":"Auto mode could not evaluate this action and is blocking it for safety"}"#, env: desktopEnv))
        let s = try #require(store.sessions["s1"])
        #expect(s.phase == .thinking)
        #expect(s.currentActivity == nil)
        #expect(s.activities.first { $0.id == "cd1" }?.status == .failed)
        let seq = store.latestSignal?.seq
        clock.advance(20)
        store.checkStalledTools()
        #expect(store.latestSignal?.seq == seq)
    }

    @Test func autoModeWaitsLongerOnlyInAutoMode() {
        let heuristic = AppConsentHeuristic.default
        let name = "mcp__ccd_directory__change_directory"
        #expect(heuristic.delay(toolName: name, toolInput: nil) == 2.5)
        #expect(heuristic.delay(toolName: name, toolInput: nil, permissionMode: "default") == 2.5)
        #expect(heuristic.delay(toolName: name, toolInput: nil, permissionMode: "auto") == AppConsentHeuristic.autoModeDelay)
        #expect(heuristic.delay(toolName: "Read", toolInput: nil, permissionMode: "auto") == nil)
    }
}
