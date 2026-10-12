import Foundation
import Testing
@testable import NotchCore
import NotchShared

@Suite struct DiffEngineTests {
    let path = "/Users/dev/projects/api-server/src/auth/session.ts"

    private func outcome(_ tool: String, input: String, response: String = "{}") -> DiffOutcome? {
        DiffEngine.outcome(toolName: tool, toolInput: json(input), toolResponse: json(response))
    }

    @Test func editLineDiff() throws {
        let result = try #require(outcome("Edit", input: #"{"file_path":"\#(path)","old_string":"a\nb\nc","new_string":"a\nB\nc\nd"}"#))
        let snippet = try #require(result.snippet)
        #expect(snippet.added == 2)
        #expect(snippet.removed == 1)
        #expect(snippet.startLine == nil)
        #expect(!snippet.isNewFile)
        #expect(snippet.fileName == "session.ts")
        #expect(snippet.lines == [
            DiffLine(kind: .removed, text: "b"),
            DiffLine(kind: .added, text: "B"),
            DiffLine(kind: .added, text: "d"),
        ])
        #expect(result.changedFiles == [path])
        #expect(result.added == 2)
        #expect(result.removed == 1)
    }

    @Test func unchangedEditIsNil() {
        #expect(outcome("Edit", input: #"{"file_path":"\#(path)","old_string":"same","new_string":"same"}"#) == nil)
        #expect(outcome("Edit", input: #"{"file_path":"\#(path)"}"#) == nil)
        #expect(outcome("Read", input: #"{"file_path":"\#(path)"}"#) == nil)
    }

    @Test func structuredPatchPreferred() throws {
        let response = #"{"filePath":"\#(path)","structuredPatch":[{"oldStart":40,"oldLines":3,"newStart":40,"newLines":4,"lines":[" import x"," const a = 1","-const ttl = 3600","+const ttl = env.SESSION_TTL ?? 3600","+if (!token) return null","\\ No newline at end of file"]}]}"#
        let result = try #require(outcome("Edit", input: #"{"file_path":"\#(path)","old_string":"x","new_string":"y"}"#, response: response))
        let snippet = try #require(result.snippet)
        #expect(snippet.startLine == 42)
        #expect(snippet.added == 2)
        #expect(snippet.removed == 1)
        #expect(snippet.lines.map(\.kind) == [.removed, .added, .added])
        #expect(snippet.lines.first?.text == "const ttl = 3600")
    }

    @Test func writeCreate() throws {
        let result = try #require(outcome("Write", input: #"{"file_path":"\#(path)","content":"line1\nline2\nline3\n"}"#, response: #"{"filePath":"\#(path)","type":"create"}"#))
        let snippet = try #require(result.snippet)
        #expect(snippet.isNewFile)
        #expect(snippet.added == 3)
        #expect(snippet.removed == 0)
        #expect(snippet.startLine == 1)
        #expect(snippet.lines.map(\.text) == ["line1", "line2", "line3"])
        #expect(snippet.lines.allSatisfy { $0.kind == .added })
    }

    @Test func writeWithOriginalFile() throws {
        let result = try #require(outcome(
            "Write",
            input: #"{"file_path":"\#(path)","content":"a\nb2\nc\n"}"#,
            response: #"{"type":"update","originalFile":"a\nb\nc\n","structuredPatch":[]}"#
        ))
        let snippet = try #require(result.snippet)
        #expect(!snippet.isNewFile)
        #expect(snippet.added == 1)
        #expect(snippet.removed == 1)
        #expect(snippet.lines == [DiffLine(kind: .removed, text: "b"), DiffLine(kind: .added, text: "b2")])
    }

    @Test func writeStructuredPatch() throws {
        let response = #"{"type":"update","structuredPatch":[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":1,"lines":["-old","+new"]},{"oldStart":10,"oldLines":0,"newStart":10,"newLines":1,"lines":["+tail"]}]}"#
        let result = try #require(outcome("Write", input: #"{"file_path":"\#(path)","content":"..."}"#, response: response))
        #expect(result.snippet?.startLine == 1)
        #expect(result.added == 2)
        #expect(result.removed == 1)
        #expect(result.snippet?.lines.map(\.text) == ["old", "new", "tail"])
    }

    @Test func multiEditAggregates() throws {
        let input = #"{"file_path":"\#(path)","edits":[{"old_string":"a","new_string":"b"},{"old_string":"x\ny","new_string":"x"},{"bogus":1}]}"#
        let result = try #require(outcome("MultiEdit", input: input))
        #expect(result.added == 1)
        #expect(result.removed == 2)
        #expect(result.snippet?.lines == [
            DiffLine(kind: .removed, text: "a"),
            DiffLine(kind: .added, text: "b"),
            DiffLine(kind: .removed, text: "y"),
        ])
    }

    @Test func notebookEdit() throws {
        let result = try #require(outcome("NotebookEdit", input: #"{"notebook_path":"/Users/dev/projects/api-server/n.ipynb","new_source":"import pandas\nprint(1)"}"#))
        #expect(result.added == 2)
        #expect(result.snippet?.fileName == "n.ipynb")
        #expect(outcome("NotebookEdit", input: #"{"notebook_path":"/x.ipynb","edit_mode":"delete"}"#) == nil)
    }

    @Test func bashEditDiff() throws {
        let response = #"""
        {"stdout":"","stderr":"","interrupted":false,"isImage":false,
         "bashEditDiff":{
           "changedFiles":["/Users/dev/projects/api-server/a.ts","/Users/dev/projects/api-server/b.ts","/Users/dev/projects/api-server/c.ts"],
           "files":[
             {"filePath":"/Users/dev/projects/api-server/a.ts","hunks":[{"oldStart":3,"oldLines":1,"newStart":3,"newLines":2,"lines":["-foo","+bar","+baz"]}]},
             {"filePath":"/Users/dev/projects/api-server/d.ts","created":true,"hunks":[{"oldStart":0,"oldLines":0,"newStart":1,"newLines":1,"lines":["+new"]}]}
           ],
           "moreFiles":1}}
        """#
        let result = try #require(outcome("Bash", input: #"{"command":"sed -i '' s/foo/bar/ *.ts"}"#, response: response))
        let snippet = try #require(result.snippet)
        #expect(snippet.filePath == "/Users/dev/projects/api-server/a.ts")
        #expect(snippet.added == 2)
        #expect(snippet.removed == 1)
        #expect(snippet.startLine == 3)
        #expect(result.added == 3)
        #expect(result.removed == 1)
        #expect(result.changedFiles == [
            "/Users/dev/projects/api-server/a.ts",
            "/Users/dev/projects/api-server/b.ts",
            "/Users/dev/projects/api-server/c.ts",
            "/Users/dev/projects/api-server/d.ts",
        ])
        // bashEditDiff 가 없으면 nil
        #expect(outcome("Bash", input: #"{"command":"ls"}"#, response: #"{"stdout":"a"}"#) == nil)
    }

    @Test func bashChangedFilesOnly() throws {
        let result = try #require(outcome("Bash", input: "{}", response: #"{"bashEditDiff":{"changedFiles":["/Users/dev/projects/api-server/x.bin"],"unavailable":true}}"#))
        #expect(result.snippet == nil)
        #expect(result.changedFiles == ["/Users/dev/projects/api-server/x.bin"])
    }

    @Test func unifiedDiffStringHunk() {
        let parsed = DiffEngine.parseHunks([.string("@@ -5,2 +7,2 @@\n ctx\n-old\n+new\n")])
        #expect(parsed.startLine == 8)
        #expect(parsed.added == 1)
        #expect(parsed.removed == 1)
    }

    @Test func previewLineSanitizing() throws {
        let long = String(repeating: "x", count: 300)
        let result = try #require(outcome("Edit", input: #"{"file_path":"\#(path)","old_string":"\tindent  \t","new_string":"\#(long)"}"#))
        let lines = try #require(result.snippet?.lines)
        #expect(lines[0].text == "  indent")
        #expect(lines[1].text.count == 200)
        #expect(lines[1].text.hasSuffix("…"))
    }

    @Test func previewIsCapped() throws {
        let content = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let payload = JSONValue.object(["file_path": .string(path), "content": .string(content)])
        let result = try #require(DiffEngine.outcome(toolName: "Write", toolInput: payload, toolResponse: json(#"{"type":"create"}"#)))
        #expect(result.added == 30)
        #expect(result.snippet?.lines.count == DiffSnippet.maxStoredLines)
    }

    @Test func largeFileCountsOnly() throws {
        let content = String(repeating: "x\n", count: 1_100_000)
        let payload = JSONValue.object(["file_path": .string(path), "content": .string(content)])
        let created = try #require(DiffEngine.outcome(toolName: "Write", toolInput: payload, toolResponse: json(#"{"type":"create"}"#)))
        #expect(created.added == 1_100_000)
        #expect(created.snippet?.lines.isEmpty == true)

        let updated = try #require(DiffEngine.outcome(
            toolName: "Write",
            toolInput: payload,
            toolResponse: .object(["originalFile": .string(content + "y\n")])
        ))
        #expect(updated.removed == 1)
        #expect(updated.added == 0)
        #expect(updated.snippet?.lines.isEmpty == true)
    }

    // MARK: - CRLF (#11)

    @Test func crlfLines() throws {
        #expect(TextUtils.splitLines("a\r\nb\r\nc\r\n").map(String.init) == ["a", "b", "c"])
        #expect(TextUtils.splitLines("a\r\nb\nc").count == TextUtils.countLines("a\r\nb\nc"))
        #expect(TextUtils.splitLines("a\r\n\r\nb").map(String.init) == ["a", "", "b"])
        // 단독 \r 은 countLines 와 같이 줄 구분자가 아님
        #expect(TextUtils.splitLines("a\rb").count == 1)

        // CRLF 파일에 한 줄 추가 → +1 −0
        let response = JSONValue.object(["originalFile": .string("line1\r\nline2\r\n")])
        let input = JSONValue.object(["file_path": .string(path), "content": .string("line1\r\nline2\r\nline3\r\n")])
        let result = try #require(DiffEngine.outcome(toolName: "Write", toolInput: input, toolResponse: response))
        #expect(result.added == 1)
        #expect(result.removed == 0)
        #expect(result.snippet?.lines == [DiffLine(kind: .added, text: "line3")])
        #expect(result.snippet?.startLine == 3)

        let created = try #require(DiffEngine.outcome(
            toolName: "Write",
            toolInput: .object(["file_path": .string(path), "content": .string("a\r\nb\r\nc\r\n")]),
            toolResponse: json(#"{"type":"create"}"#)
        ))
        #expect(created.added == 3)
        #expect(created.snippet?.lines.map(\.text) == ["a", "b", "c"])

        let hunk = DiffEngine.parseHunks([.string("@@ -1 +1 @@\r\n-a\r\n+b\r\n")])
        #expect(hunk.added == 1)
        #expect(hunk.removed == 1)
        #expect(hunk.startLine == 1)
    }

    // MARK: - replace_all (#12)

    @Test func editReplaceAllUsesOriginalFile() throws {
        let original = "let foo = 1\nprint(foo)\nbar()\nfoo += 1\n"
        let input = JSONValue.object([
            "file_path": .string(path), "old_string": .string("foo"), "new_string": .string("count"), "replace_all": .bool(true),
        ])
        let result = try #require(DiffEngine.outcome(toolName: "Edit", toolInput: input, toolResponse: .object(["originalFile": .string(original)])))
        #expect(result.added == 3)
        #expect(result.removed == 3)
        #expect(result.snippet?.startLine == 1)
        #expect(result.snippet?.lines.first == DiffLine(kind: .removed, text: "let foo = 1"))

        // 응답의 replaceAll 도 인정
        let responseFlag = JSONValue.object(["originalFile": .string(original), "replaceAll": .bool(true)])
        var plain = input
        if case .object(var object) = plain { object["replace_all"] = nil; plain = .object(object) }
        #expect(DiffEngine.outcome(toolName: "Edit", toolInput: plain, toolResponse: responseFlag)?.added == 3)

        // 원본이 없으면(헬퍼가 줄인 경우 등) 한 곳 기준 그대로
        #expect(DiffEngine.outcome(toolName: "Edit", toolInput: input, toolResponse: json("{}"))?.added == 1)
        // 원본에서 못 찾으면(정규화 차이 등) 한 곳 기준
        let missing = JSONValue.object(["originalFile": .string("nothing here\n")])
        #expect(DiffEngine.outcome(toolName: "Edit", toolInput: input, toolResponse: missing)?.added == 1)
        // replace_all 이 아니면 원본이 있어도 기존 계산
        if case .object(var object) = input {
            object["replace_all"] = .bool(false)
            let single = DiffEngine.outcome(toolName: "Edit", toolInput: .object(object), toolResponse: .object(["originalFile": .string(original)]))
            #expect(single?.added == 1)
        }
    }

    @Test func multiEditReplaceAllUsesOriginalFile() throws {
        let original = "a = 1\nb = a\nc = a + b\n"
        let input = json(#"""
        {"file_path":"\#(path)","edits":[
          {"old_string":"a","new_string":"x","replace_all":true},
          {"old_string":"c = ","new_string":"total = "}
        ]}
        """#)
        let result = try #require(DiffEngine.outcome(toolName: "MultiEdit", toolInput: input, toolResponse: .object(["originalFile": .string(original)])))
        #expect(result.added == 3)
        #expect(result.removed == 3)
        #expect(result.snippet?.lines.last == DiffLine(kind: .added, text: "total = x + b"))
    }

    @Test func replaceAllLargeFileApproximates() {
        // 줄이 많아 정밀 diff 를 못 하면 바뀐 곳 수 × 한 곳의 diff
        let original = String(repeating: "keep\nfoo\n", count: 15_000)
        let parsed = DiffEngine.diffApplying([.init(old: "foo", new: "bar", replaceAll: true)], to: original)
        #expect(parsed?.added == 15_000)
        #expect(parsed?.removed == 15_000)
        // 바이트가 커도 같은 방식
        let large = String(repeating: "keep\nfoo\n", count: 250_000)
        #expect(DiffEngine.diffApplying([.init(old: "foo", new: "bar", replaceAll: true)], to: large)?.added == 250_000)
        #expect(DiffEngine.occurrences(of: "aa", in: "aaaa") == 2)
        #expect(DiffEngine.occurrences(of: "", in: "abc") == 0)
    }

    // MARK: - 비정상 숫자 (#13)

    @Test func hugeLineNumbersDoNotTrap() {
        let huge = DiffEngine.parseHunks([json(#"{"newStart":9223372036854775807,"lines":["+a"," b","+c"]}"#)])
        #expect(huge.added == 2)
        #expect(huge.startLine == nil)
        let nearMax = DiffEngine.parseHunks([.object(["newStart": .number(9_223_372_036_854_774_784), "lines": .array(Array(repeating: .string(" x"), count: 2_000) + [.string("+y")])])])
        #expect(nearMax.added == 1)
        #expect(nearMax.startLine == nil)
        let negative = DiffEngine.parseHunks([json(#"{"newStart":-5,"lines":["+a"]}"#)])
        #expect(negative.startLine == nil)
        let header = DiffEngine.parseHunks([.string("@@ -1 +99999999999999999999 @@\n+a\n")])
        #expect(header.startLine == nil)
        #expect(header.added == 1)
    }

    @MainActor
    @Test func storeAccumulatesTurnFromBash() throws {
        let store = makeStore(TestClock())
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"go"}"#))
        let before = store.latestSignal?.seq
        store.ingest(hook("PostToolUse", #"{"tool_name":"Bash","tool_use_id":"b1","tool_input":{"command":"make"},"tool_response":{"bashEditDiff":{"changedFiles":["/Users/dev/projects/api-server/out.o"]}}}"#))
        let s = try #require(store.sessions["s1"])
        #expect(s.turn.changedFiles == ["/Users/dev/projects/api-server/out.o"])
        #expect(s.lastDiff == nil)
        // diff 미리보기가 없으면 edited 신호 없음
        #expect(store.latestSignal?.seq == before)
    }
}
