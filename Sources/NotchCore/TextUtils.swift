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
        truncate(compactJSON(value), max: max)
    }

    /// 한 줄 JSON (키 정렬) 전체. 값이 없으면 빈 문자열
    static func compactJSON(_ value: JSONValue?) -> String {
        guard let value, !value.isNull,
              let data = try? value.serialized(sortedKeys: true),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    // MARK: - 권한 카드 표시

    /// 이보다 길게 이어진 공백 · 탭은 "␣×N" 으로 보여준다 (공백으로 뒤쪽 내용을 밀어내지 못하게)
    static let maxVisibleWhitespaceRun = 8
    /// 줄바꿈 자리 표시
    static let lineBreakMarker = "⏎"

    /// 권한 카드에서 승인 대상이 빠짐없이 보이도록 숨은 문자를 드러낸다. 공백을 합치거나 지우지 않는다.
    /// - 줄바꿈("\n", "\r\n"): `keepLineBreaks` 면 "⏎" + 실제 줄바꿈, 아니면 "⏎" 만 (한 줄 유지)
    /// - `maxVisibleWhitespaceRun` 보다 길게 이어진 공백 · 탭 → "␣×N"
    /// - 그 밖의 제어 문자, 서식 문자(폭 0 공백 · 양방향 제어 등), 줄/문단 구분자, 특수 공백 → "\u{XXXX}"
    static func revealInvisibles(_ text: String, keepLineBreaks: Bool) -> String {
        var result = String.UnicodeScalarView()
        var run = String.UnicodeScalarView()

        func append(_ string: String) { result.append(contentsOf: string.unicodeScalars) }
        func flushRun() {
            if run.count > maxVisibleWhitespaceRun {
                append("␣×\(run.count)")
            } else {
                result.append(contentsOf: run)
            }
            run.removeAll()
        }

        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if scalar == " " || scalar == "\t" {
                run.append(scalar)
                continue
            }
            flushRun()
            if scalar == "\n" || (scalar == "\r" && index < scalars.count && scalars[index] == "\n") {
                if scalar == "\r" { index += 1 }
                append(keepLineBreaks ? lineBreakMarker + "\n" : lineBreakMarker)
            } else if isHidden(scalar) {
                append(scalar == "\r" ? "\\r" : "\\u{\(String(scalar.value, radix: 16, uppercase: true))}")
            } else {
                result.append(scalar)
            }
        }
        flushRun()
        return String(result)
    }

    /// 화면에 보이지 않거나 줄을 바꾸거나 글자 순서를 뒤집을 수 있는 문자
    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator:
            return true
        default:
            return false
        }
    }

    // MARK: - diff 줄

    static let maxDiffLineCharacters = 200

    /// 미리보기 줄 정리: 탭 → 공백 2칸, 끝 공백 제거, 최대 200자
    static func sanitizeDiffLine<S: StringProtocol>(_ line: S) -> String {
        var text = line.replacingOccurrences(of: "\t", with: "  ")
        while let last = text.last, last.isWhitespace || last.isNewline { text.removeLast() }
        return truncate(text, max: maxDiffLineCharacters)
    }

    /// 줄 구분자: "\n" 과 "\r\n" ("\r\n" 은 Character 하나라서 따로 비교해야 한다).
    /// `countLines` 가 세는 0x0A 와 같은 기준이라 단독 "\r" 이나 U+2028 에서는 나누지 않는다.
    static func isLineSeparator(_ character: Character) -> Bool {
        character == "\n" || character == "\r\n"
    }

    /// 줄 단위로 나눈다 (LF · CRLF). 마지막 줄바꿈 뒤의 빈 줄은 버린다.
    static func splitLines(_ text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: isLineSeparator)
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
