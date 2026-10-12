import Foundation
import NotchShared

/// 툴 실행 한 건으로 바뀐 내용 (턴 요약 누적 + 미니 diff)
public struct DiffOutcome: Hashable, Sendable {
    /// 노치에 보여줄 파일 한 개의 diff (미리보기가 불가능하면 nil)
    public var snippet: DiffSnippet?
    /// 바뀐 파일 경로 (중복 없음)
    public var changedFiles: [String]
    /// 모든 파일 합산 추가 줄 수
    public var added: Int
    /// 모든 파일 합산 삭제 줄 수
    public var removed: Int

    public init(snippet: DiffSnippet?, changedFiles: [String], added: Int, removed: Int) {
        self.snippet = snippet
        self.changedFiles = changedFiles
        self.added = added
        self.removed = removed
    }
}

/// PostToolUse 의 `tool_input` / `tool_response` 로 diff 를 계산한다.
///
/// - `tool_response.structuredPatch` (hunk 배열)가 있으면 우선 사용
/// - 없으면 Edit/MultiEdit 는 old/new 문자열, Write 는 originalFile 과 content 로 직접 계산
/// - Bash 는 `bashEditDiff` (베타) 를 방어적으로 파싱
public enum DiffEngine {
    /// 이보다 큰 텍스트는 줄 수만 센다 (미리보기 없음)
    static let maxTextBytes = 2 * 1024 * 1024
    /// 공통 앞/뒤를 잘라낸 뒤에도 이 줄 수를 넘으면 정밀 diff 대신 근사치
    static let maxDiffedLines = 20_000

    public static func outcome(toolName: String, toolInput: JSONValue?, toolResponse: JSONValue?) -> DiffOutcome? {
        let input = HookPayload(toolInput ?? .null)
        let response = HookPayload(toolResponse ?? .null)

        switch toolName {
        case "Edit":
            let path = filePath(input, response)
            if let hunks = nonEmptyHunks(response["structuredPatch"]) {
                return single(path: path, parsed: parseHunks(hunks), isNewFile: false)
            }
            guard let old = input["old_string"]?.stringValue, let new = input["new_string"]?.stringValue else { return nil }
            return single(path: path, parsed: diffTexts(old: old, new: new), isNewFile: false)

        case "MultiEdit":
            let path = filePath(input, response)
            if let hunks = nonEmptyHunks(response["structuredPatch"]) {
                return single(path: path, parsed: parseHunks(hunks), isNewFile: false)
            }
            var total = ParsedDiff()
            for edit in input["edits"]?.arrayValue ?? [] {
                guard let old = edit["old_string"]?.stringValue, let new = edit["new_string"]?.stringValue else { continue }
                total.merge(diffTexts(old: old, new: new))
            }
            return single(path: path, parsed: total, isNewFile: false)

        case "Write":
            let path = filePath(input, response)
            let type = response.string("type")
            if let hunks = nonEmptyHunks(response["structuredPatch"]) {
                return single(path: path, parsed: parseHunks(hunks), isNewFile: type == "create")
            }
            let content = input["content"]?.stringValue ?? ""
            if let original = response["originalFile"]?.stringValue {
                return single(path: path, parsed: diffTexts(old: original, new: content), isNewFile: false)
            }
            guard input["content"] != nil else { return nil }
            // 새 파일 (원본 정보 없음 → 전부 추가로 본다)
            return created(path: path, content: content, isNewFile: type != "update")

        case "NotebookEdit":
            let path = input.string("notebook_path") ?? response.string("notebook_path") ?? ""
            if input.string("edit_mode") == "delete" { return nil }
            guard let source = input["new_source"]?.stringValue, !source.isEmpty else { return nil }
            return single(path: path, parsed: diffTexts(old: "", new: source), isNewFile: false)

        case "Bash":
            guard let bashDiff = response["bashEditDiff"] else { return nil }
            return bash(bashDiff)

        default:
            // 알 수 없는 툴이라도 structuredPatch 가 있으면 사용
            guard let hunks = nonEmptyHunks(response["structuredPatch"]) else { return nil }
            return single(path: filePath(input, response), parsed: parseHunks(hunks), isNewFile: false)
        }
    }

    // MARK: - 파일 하나

    private static func filePath(_ input: HookPayload, _ response: HookPayload) -> String {
        input.string("file_path") ?? response.string("filePath") ?? response.string("file_path") ?? ""
    }

    private static func nonEmptyHunks(_ value: JSONValue?) -> [JSONValue]? {
        guard let hunks = value?.arrayValue, !hunks.isEmpty else { return nil }
        return hunks
    }

    private static func single(path: String, parsed: ParsedDiff, isNewFile: Bool) -> DiffOutcome? {
        guard parsed.added + parsed.removed > 0 || isNewFile else { return nil }
        let snippet = DiffSnippet(
            filePath: path,
            added: parsed.added,
            removed: parsed.removed,
            startLine: parsed.startLine,
            lines: parsed.preview,
            isNewFile: isNewFile
        )
        return DiffOutcome(
            snippet: snippet,
            changedFiles: path.isEmpty ? [] : [path],
            added: parsed.added,
            removed: parsed.removed
        )
    }

    /// 원본 없이 새로 쓴 파일: 모든 줄이 추가
    private static func created(path: String, content: String, isNewFile: Bool) -> DiffOutcome? {
        var parsed = ParsedDiff()
        if content.utf8.count > maxTextBytes {
            parsed.added = TextUtils.countLines(content)
        } else {
            let lines = TextUtils.splitLines(content)
            parsed.added = lines.count
            for line in lines.prefix(DiffSnippet.maxStoredLines) {
                parsed.preview.append(DiffLine(kind: .added, text: TextUtils.sanitizeDiffLine(line)))
            }
        }
        if parsed.added > 0 { parsed.startLine = 1 }
        return single(path: path, parsed: parsed, isNewFile: isNewFile)
    }

    // MARK: - Bash bashEditDiff

    private static func bash(_ bashDiff: JSONValue) -> DiffOutcome? {
        var changedFiles: [String] = []
        func appendUnique(_ path: String) {
            if !path.isEmpty, !changedFiles.contains(path) { changedFiles.append(path) }
        }
        for path in bashDiff["changedFiles"]?.arrayValue ?? [] {
            if let path = path.stringValue { appendUnique(path) }
        }

        var added = 0
        var removed = 0
        var snippet: DiffSnippet?
        var fallback: DiffSnippet?
        for file in bashDiff["files"]?.arrayValue ?? [] {
            guard let path = TextUtils.nonEmpty(file["filePath"]?.stringValue ?? file["file_path"]?.stringValue) else { continue }
            appendUnique(path)
            let parsed = parseHunks(file["hunks"]?.arrayValue ?? file["structuredPatch"]?.arrayValue ?? [])
            added += parsed.added
            removed += parsed.removed
            let fileSnippet = DiffSnippet(
                filePath: path,
                added: parsed.added,
                removed: parsed.removed,
                startLine: parsed.startLine,
                lines: parsed.preview,
                isNewFile: file["created"]?.boolValue == true
            )
            // 실제 변경 줄이 있는 첫 파일을 미리보기로 (없으면 생성된 첫 파일)
            if snippet == nil, parsed.added + parsed.removed > 0 {
                snippet = fileSnippet
            } else if fallback == nil, fileSnippet.isNewFile {
                fallback = fileSnippet
            }
        }

        let preview = snippet ?? fallback
        guard preview != nil || !changedFiles.isEmpty || added + removed > 0 else { return nil }
        return DiffOutcome(snippet: preview, changedFiles: changedFiles, added: added, removed: removed)
    }

    // MARK: - hunk 파싱

    /// 줄 수 집계 + 미리보기
    struct ParsedDiff: Hashable {
        var added = 0
        var removed = 0
        var startLine: Int?
        var preview: [DiffLine] = []

        mutating func appendPreview(_ kind: DiffLine.Kind, _ text: Substring) {
            guard preview.count < DiffSnippet.maxStoredLines else { return }
            preview.append(DiffLine(kind: kind, text: TextUtils.sanitizeDiffLine(text)))
        }

        mutating func merge(_ other: ParsedDiff) {
            added += other.added
            removed += other.removed
            if startLine == nil { startLine = other.startLine }
            for line in other.preview where preview.count < DiffSnippet.maxStoredLines {
                preview.append(line)
            }
        }
    }

    /// structuredPatch 형태 hunk 배열 (`{oldStart, oldLines, newStart, newLines, lines}`) 파싱.
    /// hunk 가 문자열(유니파이드 diff 조각)이어도 처리한다.
    static func parseHunks(_ hunks: [JSONValue]) -> ParsedDiff {
        var result = ParsedDiff()
        for hunk in hunks {
            var lines: [Substring]
            var cursor: Int?
            if let text = hunk.stringValue {
                lines = []
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    if line.hasPrefix("@@") {
                        cursor = cursor ?? newStart(fromHeader: line)
                    } else if !line.hasPrefix("+++"), !line.hasPrefix("---") {
                        lines.append(line)
                    }
                }
                if lines.last?.isEmpty == true { lines.removeLast() }
            } else {
                lines = (hunk["lines"]?.arrayValue ?? []).compactMap { $0.stringValue.map { Substring($0) } }
                cursor = hunk["newStart"]?.intValue
            }

            for line in lines {
                switch line.first {
                case "+":
                    result.added += 1
                    if result.startLine == nil { result.startLine = cursor }
                    result.appendPreview(.added, line.dropFirst())
                    cursor = cursor.map { $0 + 1 }
                case "-":
                    result.removed += 1
                    if result.startLine == nil { result.startLine = cursor }
                    result.appendPreview(.removed, line.dropFirst())
                case "\\":
                    // "\ No newline at end of file"
                    continue
                default:
                    cursor = cursor.map { $0 + 1 }
                }
            }
        }
        return result
    }

    /// "@@ -a,b +c,d @@" → c
    private static func newStart(fromHeader header: Substring) -> Int? {
        guard let plus = header.firstIndex(of: "+") else { return nil }
        let digits = header[header.index(after: plus)...].prefix(while: \.isNumber)
        return Int(digits)
    }

    // MARK: - 텍스트 diff

    /// 두 텍스트의 줄 단위 diff (CollectionDifference)
    static func diffTexts(old: String, new: String) -> ParsedDiff {
        var result = ParsedDiff()
        guard old != new else { return result }
        let tooLarge = old.utf8.count > maxTextBytes || new.utf8.count > maxTextBytes
        let oldLines = TextUtils.splitLines(old)
        let newLines = TextUtils.splitLines(new)

        // 공통 앞/뒤를 잘라 diff 범위를 줄인다
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }
        let oldMiddle = Array(oldLines[prefix..<(oldLines.count - suffix)])
        let newMiddle = Array(newLines[prefix..<(newLines.count - suffix)])

        if tooLarge || oldMiddle.count + newMiddle.count > maxDiffedLines {
            // 큰 파일: 줄 수만 (근사치)
            result.removed = oldMiddle.count
            result.added = newMiddle.count
            return result
        }

        let difference = newMiddle.difference(from: oldMiddle)
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }
        result.removed = removedOffsets.count
        result.added = insertedOffsets.count

        // 유니파이드 diff 순서로 미리보기 구성 (같은 위치에서는 삭제 → 추가)
        var i = 0
        var j = 0
        while i < oldMiddle.count || j < newMiddle.count {
            if result.preview.count >= DiffSnippet.maxStoredLines { break }
            if i < oldMiddle.count, removedOffsets.contains(i) {
                result.appendPreview(.removed, oldMiddle[i])
                i += 1
            } else if j < newMiddle.count, insertedOffsets.contains(j) {
                result.appendPreview(.added, newMiddle[j])
                j += 1
            } else {
                i += 1
                j += 1
            }
        }
        return result
    }
}
