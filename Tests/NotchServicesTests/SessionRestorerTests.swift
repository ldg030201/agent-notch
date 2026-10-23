import Foundation
import Testing
import NotchCore
@testable import NotchServices

/// 최근 대화 기록 찾기 · 끝부분 읽기 (임시 폴더의 가짜 기록만 사용)
@Suite struct SessionRestorerTests {
    static func line(_ session: String, _ fields: String, at time: String) -> String {
        #"{"sessionId":"\#(session)","cwd":"/Users/dev/projects/api-server","isSidechain":false,"timestamp":"\#(time)",\#(fields)}"#
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// 프로젝트 폴더에 기록 하나를 쓰고 수정 시각을 맞춘다
    @discardableResult
    static func write(_ lines: [String], to directory: URL, name: String, modified: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    @Test func restoresRecentSessionsOnly() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let now = Date()
        let project = temp.url.appendingPathComponent("-Users-dev-projects-api-server")
        let recent = Self.iso(now.addingTimeInterval(-120))
        let prompt = #""type":"user","message":{"role":"user","content":"빌드해줘"}"#
        let tool = #""type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift build"}}]}"#
        let stop = #""type":"system","subtype":"stop_hook_summary""#

        // 돌고 있는 세션 (2분 전)
        try Self.write([Self.line("running", prompt, at: recent), Self.line("running", tool, at: recent)],
                       to: project, name: "running.jsonl", modified: now.addingTimeInterval(-120))
        // 끝난 지 오래된 세션: 파일은 최근에 바뀌었어도 끝난 시각이 finishedWindow 밖이면 건너뜀
        let old = Self.iso(now.addingTimeInterval(-20 * 60))
        try Self.write([Self.line("finished-old", prompt, at: old), Self.line("finished-old", stop, at: old)],
                       to: project, name: "finished-old.jsonl", modified: now.addingTimeInterval(-60))
        // 최근에 끝난 세션
        try Self.write([Self.line("finished", prompt, at: recent), Self.line("finished", stop, at: recent)],
                       to: project, name: "finished.jsonl", modified: now.addingTimeInterval(-120))
        // activeWindow 밖에서 바뀐 기록
        try Self.write([Self.line("stale", prompt, at: recent), Self.line("stale", tool, at: recent)],
                       to: project, name: "stale.jsonl", modified: now.addingTimeInterval(-2 * 60 * 60))
        // 서브에이전트 기록은 보지 않음
        try Self.write([Self.line("sub", prompt, at: recent), Self.line("sub", tool, at: recent)],
                       to: project.appendingPathComponent("running/subagents"), name: "agent-x.jsonl", modified: now)

        let restorer = SessionRestorer(projectsDirectory: temp.url, codexSessionsDirectory: nil)
        let restored = restorer.scan(now: now)
        #expect(Set(restored.map(\.id)) == ["running", "finished"])
        #expect(restored.first { $0.id == "running" }?.state == .runningTool(
            name: "Bash", input: .object(["command": .string("swift build")]), toolUseID: "t1"
        ))
    }

    @Test func tailDropsCutFirstLine() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let now = Date()
        let at = Self.iso(now)
        // 앞쪽에 긴 줄(한글 포함)을 두고 끝부분만 읽는다: 잘린 첫 줄은 버리고 나머지로 상태를 고른다
        let filler = Self.line("s", #""type":"attachment","note":"\#(String(repeating: "가나다", count: 400))""#, at: at)
        let lines = [filler, Self.line("s", #""type":"user","message":{"role":"user","content":"x"}"#, at: at),
                     Self.line("s", #""type":"system","subtype":"stop_hook_summary""#, at: at)]
        let url = try Self.write(lines, to: temp.url.appendingPathComponent("p"), name: "s.jsonl", modified: now)

        var restorer = SessionRestorer(projectsDirectory: temp.url, codexSessionsDirectory: nil)
        restorer.tailBytes = 600
        let tail = try #require(TranscriptTail.readTail(atPath: url.path, maxBytes: restorer.tailBytes))
        #expect(tail.count == 2)
        #expect(restorer.scan(now: now).first?.state == .finished)
    }

    /// `/clear` 만 있는 새 기록 · `/exit` 로 끝난 기록은 "응답 중" 유령으로 되살리지 않는다
    @Test func commandOnlyAndExitedSessionsAreSkipped() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let now = Date()
        let at = Self.iso(now.addingTimeInterval(-60))
        let project = temp.url.appendingPathComponent("-Users-dev-projects-api-server")
        let caveat = #""type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>c</local-command-caveat>"}"#
        func command(_ name: String) -> String {
            #""type":"user","message":{"role":"user","content":"<command-name>/\#(name)</command-name>\n<command-message>\#(name)</command-message>\n<command-args></command-args>"}"#
        }
        let cleared = #""type":"system","subtype":"local_command","content":"<command-name>/clear</command-name>""#
        let bye = #""type":"user","message":{"role":"user","content":"<local-command-stdout>Bye!</local-command-stdout>"}"#
        let prompt = #""type":"user","message":{"role":"user","content":"빌드해줘"}"#
        let tool = #""type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift build"}}]}"#

        try Self.write([caveat, command("clear"), cleared].map { Self.line("cleared", $0, at: at) },
                       to: project, name: "cleared.jsonl", modified: now)
        try Self.write([prompt, tool, caveat, command("exit"), bye].map { Self.line("exited", $0, at: at) },
                       to: project, name: "exited.jsonl", modified: now)
        try Self.write([prompt, tool].map { Self.line("running", $0, at: at) },
                       to: project, name: "running.jsonl", modified: now)

        let restored = SessionRestorer(projectsDirectory: temp.url, codexSessionsDirectory: nil).scan(now: now)
        #expect(restored.map(\.id) == ["running"])
    }

    /// 기록 파일 자리에 FIFO 가 있어도 멈추지 않는다
    @Test(.timeLimit(.minutes(1))) func fifoTranscriptDoesNotBlock() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let project = temp.url.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        #expect(mkfifo(project.appendingPathComponent("s.jsonl").path, 0o600) == 0)
        #expect(SessionRestorer(projectsDirectory: temp.url, codexSessionsDirectory: nil).scan().isEmpty)
    }

    // MARK: - Codex

    static func codexMeta(_ thread: String, session: String? = nil, subagent: Bool = false, originator: String = "Codex Desktop") -> String {
        let source = subagent ? #"{"subagent":{"parent":"x"}}"# : #""vscode""#
        return #"{"timestamp":"2026-10-22T03:13:54.486Z","type":"session_meta","payload":{"session_id":"\#(session ?? thread)","id":"\#(thread)","cwd":"/Users/dev/projects/web-app","originator":"\#(originator)","source":\#(source),"thread_source":"\#(subagent ? "subagent" : "user")","base_instructions":"\#(String(repeating: "규칙 ", count: 20_000))","git":{"branch":"main"}}}"#
    }

    static func codexLine(_ type: String, _ payload: String, at time: String) -> String {
        #"{"timestamp":"\#(time)","type":"\#(type)","payload":\#(payload)}"#
    }

    @Test func restoresCodexRollouts() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let now = Date()
        let at = Self.iso(now.addingTimeInterval(-60))
        let day = temp.url.appendingPathComponent("codex/2026/10/22")
        let started = Self.codexLine("event_msg", #"{"type":"task_started","turn_id":"t1"}"#, at: at)
        let call = Self.codexLine("response_item", #"{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"swift test\"}","call_id":"call_1"}"#, at: at)
        let output = Self.codexLine("response_item", #"{"type":"function_call_output","call_id":"call_1","output":"ok"}"#, at: at)
        let patch = Self.codexLine("response_item", #"{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch\n*** Add File: a.md\n+x\n*** End Patch","call_id":"call_2"}"#, at: at)
        let complete = Self.codexLine("event_msg", #"{"type":"task_complete","turn_id":"t1","last_agent_message":"끝"}"#, at: at)
        let aborted = Self.codexLine("event_msg", #"{"type":"turn_aborted","turn_id":"t1"}"#, at: at)
        let thread = "01a16199-d734-7d03-a3e3-b0d129131dcf"

        try Self.write([Self.codexMeta(thread), started, call], to: day, name: "rollout-a-\(thread).jsonl", modified: now)
        try Self.write([Self.codexMeta("thinking-1"), started, call, output], to: day, name: "rollout-b.jsonl", modified: now)
        try Self.write([Self.codexMeta("patching-1", originator: "codex_cli_rs"), started, patch], to: day, name: "rollout-c.jsonl", modified: now)
        try Self.write([Self.codexMeta("done-1"), started, complete], to: day, name: "rollout-d.jsonl", modified: now)
        try Self.write([Self.codexMeta("stopped-1"), started, call, aborted], to: day, name: "rollout-e.jsonl", modified: now)
        // 서브에이전트 스레드는 부모 세션의 훅으로 보이므로 되살리지 않는다
        try Self.write([Self.codexMeta("sub-1", session: thread, subagent: true), started, call], to: day, name: "rollout-f.jsonl", modified: now)
        // 오래전에 바뀐 기록
        try Self.write([Self.codexMeta("stale-1"), started, call], to: day, name: "rollout-g.jsonl", modified: now.addingTimeInterval(-2 * 60 * 60))

        let restorer = SessionRestorer(
            projectsDirectory: temp.url.appendingPathComponent("none"),
            codexSessionsDirectory: temp.url.appendingPathComponent("codex")
        )
        let restored = Dictionary(uniqueKeysWithValues: restorer.scan(now: now).map { ($0.id, $0) })
        #expect(Set(restored.keys) == [thread, "thinking-1", "patching-1", "done-1", "stopped-1"])

        let running = try #require(restored[thread])
        #expect(running.agent == .codex)
        #expect(running.cwd == "/Users/dev/projects/web-app")
        #expect(running.gitBranch == "main")
        #expect(running.state == .runningTool(name: "Bash", input: .object(["command": .string("swift test")]), toolUseID: "call_1"))
        // Codex 앱 기록이면 "Codex로" 가 그 스레드를 연다
        #expect(running.terminal.codexDesktopThreadURL?.absoluteString == "codex://threads/\(thread)")

        #expect(restored["thinking-1"]?.state == .thinking)
        #expect(restored["patching-1"]?.state == .runningTool(
            name: "apply_patch", input: .object(["command": .string("*** Begin Patch\n*** Add File: a.md\n+x\n*** End Patch")]), toolUseID: "call_2"
        ))
        #expect(restored["patching-1"]?.terminal.isCodexDesktopApp == false)
        #expect(restored["done-1"]?.state == .finished)
        #expect(restored["stopped-1"]?.state == .finished)
    }

    @Test func codexMetaNeedsSessionMetaLine() {
        #expect(CodexRolloutTail.meta(fromFirstLine: #"{"type":"event_msg","payload":{}}"#) == nil)
        let meta = CodexRolloutTail.meta(fromFirstLine: Self.codexMeta("t", session: "parent"))
        #expect(meta?.isSubagent == true)
        #expect(meta?.sessionID == "parent")
    }
}

