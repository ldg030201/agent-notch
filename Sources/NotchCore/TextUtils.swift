import Foundation
import NotchShared

/// 문자열 정리 · 자르기 · 경로 표시 등 공용 텍스트 유틸
enum TextUtils {
    static let ellipsis = "…"

    /// 최대 `max` 글자(말줄임표 포함)로 자른다
    static func truncate(_ text: String, max: Int) -> String {
        guard max > 0 else { return "" }
        guard text.count > max else { return text }
        return String(text.prefix(max - 1)) + ellipsis
    }

    /// 첫 번째 비어 있지 않은 줄 (앞뒤 공백 제거)
    static func firstLine(_ text: String) -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// 연속 공백·줄바꿈을 공백 하나로 합치고 앞뒤 공백 제거
    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// 빈 문자열이면 nil
    static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    // MARK: - 프롬프트

    static let maxPromptCharacters = 200
    static let pastedPlaceholder = "[붙여넣음]"

    /// `<pasted_content ...>…</pasted_content>` (닫는 태그 없는 경우·자기 닫는 태그 포함)
    private static let pastedPatterns: [NSRegularExpression] = [
        #"<pasted_content\b[^>]*/>"#,
        #"<pasted_content\b[^>]*>[\s\S]*?</pasted_content\s*>"#,
        #"<pasted_content\b[^>]*>[\s\S]*$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// 노치에 보여줄 프롬프트: 붙여넣은 내용은 "[붙여넣음]" 으로 바꾸고 공백 정리, 최대 200자
    static func cleanPrompt(_ prompt: String) -> String {
        var text = prompt
        for regex in pastedPatterns {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(
                in: text, range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: " \(pastedPlaceholder) ")
            )
        }
        return truncate(collapseWhitespace(text), max: maxPromptCharacters)
    }

    // MARK: - 경로

    /// cwd 안의 경로면 cwd 기준 상대 경로, 아니면 그대로
    static func displayPath(_ path: String, cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty, !path.isEmpty else { return path }
        let base = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        guard !base.isEmpty else { return path }
        if path == base { return "." }
        if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
        return path
    }

    /// 경로의 마지막 요소 (파일명)
    static func fileName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// cwd 의 마지막 경로 요소. 알 수 없으면 "unknown"
    static func projectName(forCwd cwd: String) -> String {
        var trimmed = cwd
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        let name = (trimmed as NSString).lastPathComponent
        if name.isEmpty || name == "/" { return "unknown" }
        return name
    }

    // MARK: - JSON

    /// 한 줄 JSON (키 정렬), 최대 `max` 글자
    static func compactJSON(_ value: JSONValue?, max: Int) -> String {
        guard let value, !value.isNull,
              let data = try? value.serialized(sortedKeys: true),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return truncate(text, max: max)
    }

    // MARK: - diff 줄

    static let maxDiffLineCharacters = 200

    /// 미리보기 줄 정리: 탭 → 공백 2칸, 끝 공백 제거, 최대 200자
    static func sanitizeDiffLine<S: StringProtocol>(_ line: S) -> String {
        var text = line.replacingOccurrences(of: "\t", with: "  ")
        while let last = text.last, last.isWhitespace || last.isNewline { text.removeLast() }
        return truncate(text, max: maxDiffLineCharacters)
    }

    /// 줄 단위로 나눈다. 마지막 줄바꿈 뒤의 빈 줄은 버린다.
    static func splitLines(_ text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// 줄 수만 센다 (큰 파일용, 마지막 줄바꿈 뒤 빈 줄 제외)
    static func countLines(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 0
        for byte in text.utf8 where byte == UInt8(ascii: "\n") { count += 1 }
        if text.utf8.last != UInt8(ascii: "\n") { count += 1 }
        return count
    }
}

/// 훅 payload 에서 필드를 꺼내는 얇은 래퍼 (모든 필드는 선택적)
struct HookPayload {
    let raw: JSONValue

    init(_ raw: JSONValue) { self.raw = raw }

    subscript(key: String) -> JSONValue? {
        guard let value = raw[key], !value.isNull else { return nil }
        return value
    }

    /// 비어 있지 않은 문자열만
    func string(_ key: String) -> String? {
        TextUtils.nonEmpty(raw[key]?.stringValue)
    }

    func int(_ key: String) -> Int? { raw[key]?.intValue }

    func bool(_ key: String) -> Bool? { raw[key]?.boolValue }
}
