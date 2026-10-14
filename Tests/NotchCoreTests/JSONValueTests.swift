import Foundation
import Testing
@testable import NotchShared

/// JSON 해석: 짝 없는 UTF-16 서로게이트 하나 때문에 payload 전체를 잃지 않는다
@Suite struct JSONValueTests {
    /// Node 의 JSON.stringify 는 이모지 중간에서 잘린 문자열을 `\ud83d` 처럼 짝 없이 이스케이프한다
    @Test func loneSurrogateEscapesAreReplaced() throws {
        let payload = Data(#"{"session_id":"s1","prompt":"웃음 \ud83d","tail":"\ude00끝","both":"\ud83d\ud83d\ude00"}"#.utf8)
        let value = try JSONValue.parse(payload)
        #expect(value["session_id"]?.stringValue == "s1")
        #expect(value["prompt"]?.stringValue == "웃음 \u{FFFD}")
        #expect(value["tail"]?.stringValue == "\u{FFFD}끝")
        // 짝 없는 앞쪽만 바꾸고 올바른 짝은 그대로
        #expect(value["both"]?.stringValue == "\u{FFFD}😀")
        // 고치지 않기로 하면 예전처럼 실패
        #expect(throws: (any Error).self) { try JSONValue.parse(payload, repairingLoneSurrogates: false) }
    }

    @Test func validEscapesAreUntouched() throws {
        // 올바른 짝 · 역슬래시 글자 뒤의 "ud83d" · 키 안의 이스케이프 · 문자열 밖은 그대로
        let text = #"{"emoji":"\ud83d\ude00","literal":"\\ud83d","quote":"a\"\ud83d\"b","\ud83d":1}"#
        let value = try JSONValue.parse(Data(text.utf8))
        #expect(value["emoji"]?.stringValue == "😀")
        #expect(value["literal"]?.stringValue == #"\ud83d"#)
        #expect(value["quote"]?.stringValue == "a\"\u{FFFD}\"b")
        #expect(value["\u{FFFD}"]?.intValue == 1)
        #expect(JSONValue.repairedForDecoding(Data(#"{"a":"\ud83d\ude00","b":"\\ud800"}"#.utf8)) == nil)
    }

    @Test func invalidUTF8IsReplacedAndGarbageStillFails() throws {
        var bytes = Array(#"{"session_id":"s1","x":""#.utf8)
        bytes += [0xF0, 0x9F]  // 잘린 4바이트 글자
        bytes += Array(#""}"#.utf8)
        let value = try JSONValue.parse(Data(bytes))
        #expect(value["session_id"]?.stringValue == "s1")
        #expect(value["x"]?.stringValue?.contains("\u{FFFD}") == true)

        #expect(throws: (any Error).self) { try JSONValue.parse(Data("not json".utf8)) }
        #expect(throws: (any Error).self) { try JSONValue.parse(Data(#"{"a":"\ud83d"#.utf8)) }
    }

    /// 사전 리터럴(데모 · 스냅숏 payload) → JSON 값
    @Test func initFromAnyLiteral() {
        let fields: [String: Any] = [
            "text": "a", "flag": true, "count": 3, "ratio": 0.5,
            "list": ["x", 1], "nested": ["k": false], "raw": JSONValue.null, "other": Date(),
        ]
        #expect(JSONValue(any: fields) == .object([
            "text": .string("a"), "flag": .bool(true), "count": .number(3), "ratio": .number(0.5),
            "list": .array([.string("x"), .number(1)]), "nested": .object(["k": .bool(false)]), "raw": .null, "other": .null,
        ]))
    }
}
