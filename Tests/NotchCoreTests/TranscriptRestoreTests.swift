import Foundation
import Testing
@testable import NotchCore
import NotchShared

/// 대화 기록 끝부분으로 세션 되살리기 (가짜 기록만 사용)
@MainActor
@Suite struct TranscriptRestoreTests {
    /// 기록 한 줄 (메인 대화, 가짜 세션 · 경로)
    static func line(_ fields: String, at time: String = "2026-10-13T08:00:00.000Z", sidechain: Bool = false) -> String {
        """
        {"sessionId":"sess-1","cwd":"\(projectCwd)","gitBranch":"main","entrypoint":"cli",\
        "isSidechain":\(sidechain),"timestamp":"\(time)",\(fields)}
        """
    }

    static let prompt = line(#""type":"user","message":{"role":"user","content":"테스트 돌려줘"}"#)
    static func toolUse(_ id: String, _ name: String, at time: String = "2026-10-13T08:00:05.000Z") -> String {
        line(#""type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{"command":"npm test"}}],"stop_reason":"tool_use"}"#, at: time)
    }
    static func toolResult(_ id: String) -> String {
        line(#""type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"ok"}]}"#, at: "2026-10-13T08:00:09.000Z")
    }
    static let stopSummary = line(#""type":"system","subtype":"stop_hook_summary","hookCount":1"#, at: "2026-10-13T08:00:12.000Z")

    @Test func runningToolIsRestored() throws {
        let restored = try #require(TranscriptTail.restore(lines: [Self.prompt, Self.toolUse("t1", "Bash")]))
        #expect(restored.id == "sess-1")
        #expect(restored.cwd == projectCwd)
        #expect(restored.gitBranch == "main")
        #expect(restored.entrypoint == "cli")
        #expect(restored.state == .runningTool(name: "Bash", input: json(#"{"command":"npm test"}"#), toolUseID: "t1"))
        #expect(restored.lastEventAt == TranscriptTail.parseTimestamp("2026-10-13T08:00:05.000Z"))
    }

    @Test func finishedToolMeansThinking() throws {
        let restored = try #require(TranscriptTail.restore(lines: [Self.prompt, Self.toolUse("t1", "Bash"), Self.toolResult("t1")]))
        #expect(restored.state == .thinking)
    }

    @Test func stopHookSummaryEndsTurn() throws {
        let lines = [Self.prompt, Self.toolUse("t1", "Bash"), Self.toolResult("t1"), Self.stopSummary]
        #expect(try #require(TranscriptTail.restore(lines: lines)).state == .finished)
        // 끝난 뒤 새 입력이 오면 다시 응답 중
        #expect(try #require(TranscriptTail.restore(lines: lines + [Self.prompt])).state == .thinking)
    }

    @Test func endTurnAndInterruptEndTurn() throws {
        let endTurn = Self.line(#""type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"끝"}],"stop_reason":"end_turn"}"#)
        #expect(try #require(TranscriptTail.restore(lines: [Self.prompt, endTurn])).state == .finished)

        let interrupted = Self.line(#""type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}"#)
        #expect(try #require(TranscriptTail.restore(lines: [Self.prompt, Self.toolUse("t1", "Bash"), interrupted])).state == .finished)
    }

    @Test func sidechainAndMetaLinesAreIgnored() throws {
        let sidechainTool = Self.line(
            #""type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"s1","name":"Read","input":{}}]}"#,
            sidechain: true
        )
        let meta = Self.line(#""type":"user","isMeta":true,"message":{"role":"user","content":"<system-reminder>"}"#)
        let lines = [Self.prompt, Self.toolUse("t1", "Bash"), Self.toolResult("t1"), Self.stopSummary, sidechainTool, meta]
        #expect(try #require(TranscriptTail.restore(lines: lines)).state == .finished)
    }

    @Test func unknownSessionOrNoTurnIsSkipped() {
        #expect(TranscriptTail.restore(lines: [#"{"type":"user","message":{"content":"x"}}"#]) == nil)
        #expect(TranscriptTail.restore(lines: [Self.line(#""type":"attachment""#)]) == nil)
        #expect(TranscriptTail.restore(lines: ["not json", ""]) == nil)
    }

    // MARK: - 대화가 아닌 사용자 줄 (슬래시 명령 · 명령 출력 · 셸 모드 · 압축 요약 · 작업 알림)

    /// 사용자 텍스트 줄 (isMeta 아님, 가짜 내용)
    static func userText(_ text: String, extra: String = "", at time: String = "2026-10-13T08:00:20.000Z") -> String {
        let escaped = String(decoding: try! JSONValue.string(text).serialized(), as: UTF8.self)
        return line(#""type":"user",\#(extra)"message":{"role":"user","content":\#(escaped)}"#, at: time)
    }
    static func command(_ name: String) -> String {
        userText("<command-name>/\(name)</command-name>\n<command-message>\(name)</command-message>\n<command-args></command-args>")
    }
    static let caveat = line(#""type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat</local-command-caveat>"}"#)
    static let commandStdout = userText("<local-command-stdout>Set model</local-command-stdout>")
    static let localCommand = line(#""type":"system","subtype":"local_command","content":"<command-name>/clear</command-name>""#)
    static let finishedTurn = [prompt, toolUse("t1", "Bash"), toolResult("t1"), stopSummary]

    /// `/clear` 는 새 세션 기록 맨 앞에 적힌다: 뒤에 진짜 입력이 없으면 되살리지 않는다 (예전엔 "응답 중" 유령)
    @Test func clearOnlySessionIsSkipped() throws {
        #expect(TranscriptTail.restore(lines: [Self.caveat, Self.command("clear"), Self.localCommand]) == nil)
        // 끝난 대화 뒤 /clear 도 앞의 턴을 잊는다
        #expect(TranscriptTail.restore(lines: Self.finishedTurn + [Self.caveat, Self.command("clear"), Self.localCommand]) == nil)
        // /clear 뒤 진짜 입력은 새 턴
        let restarted = [Self.caveat, Self.command("clear"), Self.localCommand, Self.prompt]
        #expect(try #require(TranscriptTail.restore(lines: restarted)).state == .thinking)
    }

    /// `/exit` · `/quit` 로 끝난 세션은 되살리지 않는다. 다시 이어서(resume) 입력하면 되살린다
    @Test func exitedSessionIsSkipped() throws {
        for name in ["exit", "quit"] {
            let exited = Self.finishedTurn + [Self.caveat, Self.command(name), Self.userText("<local-command-stdout>Bye!</local-command-stdout>")]
            #expect(TranscriptTail.restore(lines: exited) == nil, "\(name)")
            #expect(try #require(TranscriptTail.restore(lines: exited + [Self.prompt])).state == .thinking, "\(name)")
        }
        // 응답 중에 끝내도 마찬가지
        #expect(TranscriptTail.restore(lines: [Self.prompt, Self.command("exit")]) == nil)
    }

    /// 로컬 명령(/model · /login · /compact)은 턴이 아니고, 출력이 나오면 입력 대기
    @Test func localCommandsAreNotTurns() throws {
        let afterFinished = Self.finishedTurn + [Self.caveat, Self.command("model"), Self.commandStdout]
        #expect(try #require(TranscriptTail.restore(lines: afterFinished)).state == .finished)
        // 응답이 없던 입력 뒤 /login: 입력을 기다리는 중 (예전엔 "응답 중" 유령)
        let unanswered = [Self.prompt, Self.caveat, Self.command("login"), Self.userText("<local-command-stderr>x</local-command-stderr>")]
        #expect(try #require(TranscriptTail.restore(lines: unanswered)).state == .finished)
        // 명령만 있는 기록은 턴이 없다
        #expect(TranscriptTail.restore(lines: [Self.caveat, Self.command("model"), Self.commandStdout]) == nil)
        #expect(TranscriptTail.restore(lines: [Self.caveat, Self.command("rename"), Self.localCommand]) == nil)
    }

    /// `/compact` 요약(isCompactSummary · isVisibleInTranscriptOnly) · `!` 셸 모드 줄은 새 턴이 아니다
    @Test func compactSummaryAndBashModeAreIgnored() throws {
        let boundary = Self.line(#""type":"system","subtype":"compact_boundary""#)
        let summary = Self.userText("This session is being continued", extra: #""isCompactSummary":true,"isVisibleInTranscriptOnly":true,"#)
        let compacted = Self.finishedTurn + [Self.userText("/compact"), boundary, summary, Self.caveat, Self.command("compact"), Self.commandStdout]
        #expect(try #require(TranscriptTail.restore(lines: compacted)).state == .finished)
        // 자동 압축은 턴 중간: 요약 뒤에도 툴이 계속 돈다
        let auto = [Self.prompt, Self.toolUse("t1", "Bash"), Self.toolResult("t1"), boundary, summary, Self.toolUse("t2", "Read")]
        #expect(try #require(TranscriptTail.restore(lines: auto)).state == .runningTool(name: "Read", input: json(#"{"command":"npm test"}"#), toolUseID: "t2"))
        #expect(try #require(TranscriptTail.restore(lines: [Self.prompt, Self.toolUse("t1", "Bash"), summary])).state
            == .runningTool(name: "Bash", input: json(#"{"command":"npm test"}"#), toolUseID: "t1"))

        let bashMode = Self.finishedTurn + [Self.userText("<bash-input>ls</bash-input>"), Self.userText("<bash-stdout>a</bash-stdout><bash-stderr></bash-stderr>")]
        #expect(try #require(TranscriptTail.restore(lines: bashMode)).state == .finished)
        #expect(TranscriptTail.restore(lines: [Self.userText("<bash-input>ls</bash-input>")]) == nil)
    }

    /// 프롬프트 명령(스킬 · /simplify 등)과 작업 알림은 모델 응답이 이어질 때만 턴
    @Test func promptCommandsAndNotificationsNeedReply() throws {
        let expanded = Self.line(#""type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Review the diff"}]}"#)
        let skill = Self.userText("<command-message>simplify</command-message>\n<command-name>/simplify</command-name>")
        let thinkingText = Self.line(#""type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"보는 중"}],"stop_reason":null}"#)
        let endTurn = Self.line(#""type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"끝"}],"stop_reason":"end_turn"}"#)

        // 응답이 오기 전엔 앞 상태 그대로, 응답이 오면 턴
        #expect(try #require(TranscriptTail.restore(lines: Self.finishedTurn + [skill, expanded])).state == .finished)
        #expect(try #require(TranscriptTail.restore(lines: Self.finishedTurn + [skill, expanded, thinkingText])).state == .thinking)
        #expect(try #require(TranscriptTail.restore(lines: [skill, expanded, Self.toolUse("t9", "Grep")])).state
            == .runningTool(name: "Grep", input: json(#"{"command":"npm test"}"#), toolUseID: "t9"))

        let notification = Self.userText("<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>")
        // 사용자가 멈춘 뒤 온 알림 (응답 없음): 끝난 그대로 (예전엔 "응답 중" 유령)
        let interrupted = Self.line(#""type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}"#)
        #expect(try #require(TranscriptTail.restore(lines: [Self.prompt, interrupted, notification])).state == .finished)
        #expect(TranscriptTail.restore(lines: [notification]) == nil)
        // 알림에 모델이 답하면 턴
        #expect(try #require(TranscriptTail.restore(lines: Self.finishedTurn + [notification, thinkingText])).state == .thinking)
        #expect(try #require(TranscriptTail.restore(lines: Self.finishedTurn + [notification, endTurn])).state == .finished)
        #expect(try #require(TranscriptTail.restore(lines: [notification, endTurn])).state == .finished)
        // 진짜 입력 (붙여넣기 태그로 시작해도) 은 새 턴
        #expect(try #require(TranscriptTail.restore(lines: Self.finishedTurn + [Self.userText("<pasted_content id=\"p\">x</pasted_content> 봐줘")])).state == .thinking)
    }

    @Test func userLineClassification() {
        func kind(_ text: String, _ extra: [String: JSONValue] = [:]) -> TranscriptTail.UserLine {
            TranscriptTail.UserLine(text: text, object: extra)
        }
        #expect(kind("테스트 돌려줘") == .prompt)
        #expect(kind("  <command-name>/Exit</command-name>") == .command(name: "exit"))
        #expect(kind("<command-message>simplify</command-message>\n<command-name>/simplify</command-name>") == .command(name: "simplify"))
        #expect(kind("<command-args>x</command-args>") == .command(name: ""))
        #expect(kind("<local-command-stdout>ok</local-command-stdout>") == .commandOutput)
        #expect(kind("<local-command-stderr>no</local-command-stderr>") == .commandOutput)
        #expect(kind("<bash-input>ls</bash-input>") == .ignored)
        #expect(kind("<bash-stdout></bash-stdout>") == .ignored)
        #expect(kind("<task-notification>x</task-notification>") == .notification)
        #expect(kind("[Request interrupted by user for tool use]") == .interrupted)
        #expect(kind("요약", ["isCompactSummary": .bool(true)]) == .ignored)
        #expect(kind("요약", ["isVisibleInTranscriptOnly": .bool(true)]) == .ignored)
    }

    // MARK: - 끝부분 안전하게 읽기

    @Test func readTailDropsOnlyCutFirstLine() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("agentnotch-tail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("s.jsonl").path
        try "가나다라\nbbbb\ncccc\n".write(toFile: file, atomically: true, encoding: .utf8)

        #expect(TranscriptTail.readTail(atPath: file, maxBytes: 1_000)?.map(String.init) == ["가나다라", "bbbb", "cccc"])
        // 잘린 첫 줄(한글 중간)은 버린다
        #expect(TranscriptTail.readTail(atPath: file, maxBytes: 12)?.map(String.init) == ["bbbb", "cccc"])
        // 줄 경계에서 잘렸으면 첫 줄도 온전하다
        #expect(TranscriptTail.readTail(atPath: file, maxBytes: 10)?.map(String.init) == ["bbbb", "cccc"])
        #expect(TranscriptTail.readTail(atPath: file, maxBytes: 9)?.map(String.init) == ["cccc"])
        #expect(TranscriptTail.readTail(atPath: file, maxBytes: 3)?.map(String.init) == [])
        #expect(TranscriptTail.readTail(atPath: file, maxBytes: 0) == nil)

        // 큰 파일도 maxBytes 까지만 읽는다
        let big = root.appendingPathComponent("big.jsonl").path
        try String(repeating: "0123456789\n", count: 100_000).write(toFile: big, atomically: true, encoding: .utf8)
        let tail = try #require(TranscriptTail.readTail(atPath: big, maxBytes: 1_000))
        #expect(tail.count == 90)
        #expect(tail.allSatisfy { $0 == "0123456789" })
    }

    /// 훅이 넘긴 경로가 FIFO · 장치 · 심볼릭 링크 · 폴더면 읽지 않는다 (메인 스레드가 멈추거나 메모리를 끝없이 먹지 않게)
    @Test(.timeLimit(.minutes(1))) func readTailRejectsSpecialFiles() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("agentnotch-tail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fifo = root.appendingPathComponent("fifo.jsonl").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let real = root.appendingPathComponent("real.jsonl").path
        try "{\"gitBranch\":\"main\"}\n".write(toFile: real, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("link.jsonl").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        let start = Date()
        #expect(TranscriptTail.readTail(atPath: fifo, maxBytes: 1_024) == nil)
        #expect(TranscriptTail.lastGitBranch(atPath: fifo) == nil)
        #expect(TranscriptTail.readTail(atPath: "/dev/zero", maxBytes: 1_024) == nil)
        #expect(TranscriptTail.lastGitBranch(atPath: "/dev/zero") == nil)
        #expect(TranscriptTail.readTail(atPath: "/dev/null", maxBytes: 1_024) == nil)
        #expect(TranscriptTail.readTail(atPath: link, maxBytes: 1_024) == nil)
        #expect(TranscriptTail.readTail(atPath: root.path, maxBytes: 1_024) == nil)
        #expect(TranscriptTail.readTail(atPath: root.appendingPathComponent("missing").path, maxBytes: 1_024) == nil)
        #expect(TranscriptTail.readTail(atPath: "", maxBytes: 1_024) == nil)
        #expect(Date().timeIntervalSince(start) < 5)
        // 일반 파일은 읽는다
        #expect(TranscriptTail.lastGitBranch(atPath: real) == "main")
    }

    @Test func storeRestoresWithoutSignalsAndKeepsKnownSessions() throws {
        let clock = TestClock()
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", session: "known", #"{"prompt":"이미 아는 세션"}"#))
        let signalBefore = store.latestSignal

        let at = clock.now.addingTimeInterval(-60)
        store.restore([
            RestoredSession(
                id: "sess-1", cwd: projectCwd, gitBranch: "main", entrypoint: "claude-desktop",
                state: .runningTool(name: "Bash", input: json(#"{"command":"npm test"}"#), toolUseID: "t1"), lastEventAt: at
            ),
            RestoredSession(id: "sess-2", cwd: otherCwd, state: .runningTool(name: "AskUserQuestion", input: nil, toolUseID: nil), lastEventAt: at),
            RestoredSession(id: "sess-3", cwd: otherCwd, state: .finished, lastEventAt: at),
            RestoredSession(id: "known", cwd: otherCwd, state: .finished, lastEventAt: at),
        ])

        let running = try #require(store.sessions["sess-1"])
        #expect(running.phase == .runningTool)
        #expect(running.projectName == "api-server")
        #expect(running.currentActivity?.id == "t1")
        #expect(running.currentActivity?.label == "Bash")
        #expect(running.lastEventAt == at)
        #expect(running.terminal.isClaudeDesktopApp)
        #expect(try #require(store.sessions["sess-2"]).phase == .waitingInput)
        let finished = try #require(store.sessions["sess-3"])
        #expect(finished.phase == .completed)
        #expect(!finished.hasUnseenCompletion)
        // 이벤트로 이미 아는 세션은 그대로, 알림 신호도 새로 내지 않음
        #expect(try #require(store.sessions["known"]).phase == .thinking)
        #expect(store.latestSignal == signalBefore)

        // 되살린 툴의 PostToolUse 가 오면 그 활동이 끝난다
        store.ingest(hook("PostToolUse", session: "sess-1", #"{"tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"npm test"},"tool_response":{}}"#))
        let after = try #require(store.sessions["sess-1"])
        #expect(after.activities.first { $0.id == "t1" }?.status == .succeeded)
        #expect(after.phase == .thinking)
    }
}
