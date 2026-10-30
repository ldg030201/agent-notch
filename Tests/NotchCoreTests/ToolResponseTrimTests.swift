import Foundation
import Testing
@testable import NotchCore
@testable import NotchShared

/// 헬퍼가 PostToolUse 의 `tool_response` 에서 앱이 쓰는 키만 남긴다 (`PayloadShrinker.trimmingToolResponse`).
/// 줄여도 diff 결과가 같고, 줄였다는 표시는 붙지 않는다
@Suite struct ToolResponseTrimTests {
    let path = "/Users/dev/projects/api-server/src/auth/session.ts"

    private func trimmed(_ payload: JSONValue, event: String = "PostToolUse") -> JSONValue {
        PayloadShrinker.trimmingToolResponse(payload, event: event)
    }

    private func outcome(_ payload: JSONValue) -> DiffOutcome? {
        DiffEngine.outcome(
            toolName: payload["tool_name"]?.stringValue ?? "",
            toolInput: payload["tool_input"],
            toolResponse: payload["tool_response"]
        )
    }

    @Test func editKeepsPatchAndDropsTheRest() {
        let payload = json(#"""
        {"tool_name":"Edit","tool_input":{"file_path":"\#(path)","old_string":"a","new_string":"b"},
         "tool_response":{"filePath":"\#(path)","oldString":"a","newString":"b","originalFile":"a\nc\n","replaceAll":false,
           "userModified":false,"structuredPatch":[{"oldStart":1,"oldLines":2,"newStart":1,"newLines":2,"lines":["-a","+b"," c"]}]}}
        """#)
        let result = trimmed(payload)
        #expect(result["tool_response"] == json(#"""
        {"filePath":"\#(path)","replaceAll":false,
         "structuredPatch":[{"oldStart":1,"oldLines":2,"newStart":1,"newLines":2,"lines":["-a","+b"," c"]}]}
        """#))
        // tool_input 은 그대로, 줄였다는 표시 없음
        #expect(result["tool_input"] == payload["tool_input"])
        #expect(result["_agent_notch_truncated"] == nil)
        #expect(outcome(result) == outcome(payload))
    }

    /// hunk 가 비면(내용이 같은 덮어쓰기) 원본 파일로 직접 센다: originalFile 을 남겨야 가짜 "+N" 이 나오지 않는다
    @Test func writeWithoutHunksKeepsOriginalFile() {
        let payload = json(#"""
        {"tool_name":"Write","tool_input":{"file_path":"\#(path)","content":"x\ny\n"},
         "tool_response":{"type":"update","filePath":"\#(path)","content":"x\ny\n","originalFile":"x\ny\n","structuredPatch":[]}}
        """#)
        let result = trimmed(payload)
        #expect(result["tool_response"]?["originalFile"]?.stringValue == "x\ny\n")
        #expect(result["tool_response"]?["content"] == nil)
        #expect(outcome(result) == outcome(payload))
    }

    @Test func readContentAndStringResponsesAreDropped() {
        let read = json(#"""
        {"tool_name":"Read","tool_input":{"file_path":"\#(path)"},
         "tool_response":{"type":"text","file":{"filePath":"\#(path)","content":"big file","numLines":1}}}
        """#)
        #expect(trimmed(read)["tool_response"] == json(#"{"type":"text"}"#))

        // Codex 툴 결과처럼 객체가 아닌 응답은 통째로 뺀다
        let codex = json(#"{"tool_name":"shell","tool_input":{"command":"ls"},"tool_response":"Success"}"#)
        #expect(trimmed(codex)["tool_response"] == nil)
        #expect(trimmed(codex)["tool_input"] == codex["tool_input"])
    }

    @Test func otherEventsAreUntouched() {
        let payload = json(#"{"tool_name":"Read","tool_input":{"file_path":"\#(path)"},"tool_response":{"file":{"content":"x"}}}"#)
        #expect(trimmed(payload, event: "PreToolUse") == payload)
        #expect(trimmed(payload, event: "PermissionRequest") == payload)
    }
}
