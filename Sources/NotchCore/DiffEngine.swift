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
/// - Codex `apply_patch` 는 입력의 패치 글을 직접 센다 (`ApplyPatch`, 상대 경로는 작업 폴더 기준)
public enum DiffEngine {
    /// 이보다 큰 텍스트는 줄 수만 센다 (미리보기 없음)
    static let maxTextBytes = 2 * 1024 * 1024
    /// 정밀 diff(`CollectionDifference`)에 넣을 수 있는 줄 수 (공통 앞/뒤를 잘라낸 뒤 양쪽 합, 한 번의 계산에서 편집 전체 합).
    /// 넘으면 근사치. 표준 라이브러리 diff(Myers)는 시간이 (줄 수 × 바뀐 줄 수)이고, macOS 14 · 15 런타임(Swift 6.2 이하)은
    /// 단계마다 배열을 남겨 메모리도 (바뀐 줄 수)² 에 비례한다 (18,000 대 200 줄이면 약 1.4 GB). 메인 액터에서 돌므로
    /// 최악(모든 줄이 다름)이 약 36 MB · 수십 ms 안에 끝나도록 묶는다
    static let maxDiffedLines = 3_000

    /// - cwd: 세션 작업 폴더 (Codex `apply_patch` 의 상대 경로를 절대 경로로 바꿀 때만 쓴다)
    public static func outcome(
        toolName: String,
        toolInput: JSONValue?,
        toolResponse: JSONValue?,
        cwd: String? = nil
    ) -> DiffOutcome? {
        let input = HookPayload(toolInput ?? .null)
        let response = HookPayload(toolResponse ?? .null)

        switch toolName {
        case ApplyPatch.toolName:
            guard let patch = ApplyPatch.parse(toolInput: toolInput) else { return nil }
            return applyPatch(patch, cwd: cwd)

        case "Edit":
            let path = filePath(input, response)
            if let hunks = nonEmptyHunks(response["structuredPatch"]) {
                return single(path: path, parsed: parseHunks(hunks), isNewFile: false)
            }
            guard let old = input["old_string"]?.stringValue, let new = input["new_string"]?.stringValue else { return nil }
            let edit = TextEdit(old: old, new: new, replaceAll: input.bool("replace_all") == true || response.bool("replaceAll") == true)
            // 원본이 있으면 실제로 바꾼 결과와 비교 (replace_all 은 바뀐 곳이 여러 군데)
            if edit.replaceAll, let original = response["originalFile"]?.stringValue,
               let parsed = diffApplying([edit], to: original) {
                return single(path: path, parsed: parsed, isNewFile: false)
            }
            return single(path: path, parsed: diffTexts(old: old, new: new), isNewFile: false)

        case "MultiEdit":
            let path = filePath(input, response)
            if let hunks = nonEmptyHunks(response["structuredPatch"]) {
                return single(path: path, parsed: parseHunks(hunks), isNewFile: false)
            }
            let edits = (input["edits"]?.arrayValue ?? []).compactMap { edit -> TextEdit? in
                guard let old = edit["old_string"]?.stringValue, let new = edit["new_string"]?.stringValue else { return nil }
                return TextEdit(old: old, new: new, replaceAll: edit["replace_all"]?.boolValue == true)
            }
            if edits.contains(where: \.replaceAll), let original = response["originalFile"]?.stringValue,
               let parsed = diffApplying(edits, to: original) {
                return single(path: path, parsed: parsed, isNewFile: false)
            }
            var total = ParsedDiff()
            var budget = maxDiffedLines
            for edit in edits {
                total.merge(diffTexts(old: edit.old, new: edit.new, budget: &budget))
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
                return single(path: path, parsed: diffTexts(old: original, new: content, wholeFile: true), isNewFile: false)
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

    // MARK: - Codex apply_patch

    /// 파일마다 줄 수를 세고, 실제 변경 줄이 있는 첫 파일을 미리보기로 (없으면 새로 만든 첫 파일).
    /// 지운 파일은 줄 수를 알 수 없어(패치에 내용이 없다) 바뀐 파일로만 센다. 패치에는 줄 번호가 없어 첫 변경 줄 번호는 모른다
    /// (새 파일만 1)
    private static func applyPatch(_ patch: ApplyPatch, cwd: String?) -> DiffOutcome? {
        var changedFiles: [String] = []
        var added = 0
        var removed = 0
        var snippet: DiffSnippet?
        var fallback: DiffSnippet?
        for file in patch.files {
            let path = ApplyPatch.absolutePath(file.resultPath, cwd: cwd)
            if !changedFiles.contains(path) { changedFiles.append(path) }
            guard file.operation != .delete else { continue }
            var parsed = ParsedDiff()
            for line in file.lines {
                switch line.first {
                case "+":
                    parsed.added += 1
                    parsed.appendPreview(.added, line.dropFirst())
                case "-" where file.operation == .update:
                    parsed.removed += 1
                    parsed.appendPreview(.removed, line.dropFirst())
                default:
                    continue
                }
            }
            if file.operation == .add, parsed.added > 0 { parsed.startLine = 1 }
            added += parsed.added
            removed += parsed.removed
            let fileSnippet = DiffSnippet(
                filePath: path,
                added: parsed.added,
                removed: parsed.removed,
                startLine: parsed.startLine,
                lines: parsed.preview,
                isNewFile: file.operation == .add
            )
            if snippet == nil, parsed.added + parsed.removed > 0 {
                snippet = fileSnippet
            } else if fallback == nil, fileSnippet.isNewFile {
                fallback = fileSnippet
            }
        }
        guard !changedFiles.isEmpty else { return nil }
        return DiffOutcome(snippet: snippet ?? fallback, changedFiles: changedFiles, added: added, removed: removed)
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
                for line in TextUtils.splitLines(text) {
                    if line.hasPrefix("@@") {
                        cursor = cursor ?? newStart(fromHeader: line)
                    } else if !line.hasPrefix("+++"), !line.hasPrefix("---") {
                        lines.append(line)
                    }
                }
            } else {
                lines = (hunk["lines"]?.arrayValue ?? []).compactMap { $0.stringValue.map { Substring($0) } }
                cursor = hunk["newStart"]?.intValue.flatMap(saneLineNumber)
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
        return Int(digits).flatMap(saneLineNumber)
    }

    /// 줄 번호로 쓸 수 있는 값만 (음수 · 비정상적으로 큰 값은 버린다 → 이후 `+ 1` 이 넘치지 않는다)
    private static func saneLineNumber(_ value: Int) -> Int? {
        (0...Int(Int32.max)).contains(value) ? value : nil
    }

    // MARK: - 텍스트 diff

    /// 두 텍스트의 줄 단위 diff (CollectionDifference).
    /// `wholeFile` 이면 두 텍스트가 파일 전체라서 첫 변경 줄 번호(`startLine`)도 알 수 있다.
    static func diffTexts(old: String, new: String, wholeFile: Bool = false) -> ParsedDiff {
        var budget = maxDiffedLines
        return diffTexts(old: old, new: new, wholeFile: wholeFile, budget: &budget)
    }

    /// - budget: 정밀 diff 에 쓸 수 있는 남은 줄 수. 정밀 diff 를 하면 그만큼 줄어든다
    ///   (MultiEdit 처럼 여러 편집을 한 번에 계산할 때 전체를 묶어서, 편집이 많아도 메인 액터가 오래 멈추지 않게)
    static func diffTexts(old: String, new: String, wholeFile: Bool = false, budget: inout Int) -> ParsedDiff {
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

        if tooLarge {
            // 큰 파일: 줄 수만 (근사치)
            result.removed = oldMiddle.count
            result.added = newMiddle.count
            if wholeFile, result.added + result.removed > 0 { result.startLine = prefix + 1 }
            return result
        }
        if oldMiddle.isEmpty || newMiddle.isEmpty {
            // 한쪽이 비면 diff 가 필요 없다: 전부 추가 또는 전부 삭제 (NotebookEdit 새 셀 등. 줄 수와 상관없이 정확하고 빠름)
            result.removed = oldMiddle.count
            result.added = newMiddle.count
            if wholeFile, result.added + result.removed > 0 { result.startLine = prefix + 1 }
            for line in oldMiddle.prefix(DiffSnippet.maxStoredLines) { result.appendPreview(.removed, line) }
            for line in newMiddle.prefix(DiffSnippet.maxStoredLines) { result.appendPreview(.added, line) }
            return result
        }
        guard oldMiddle.count + newMiddle.count <= budget else {
            // 정밀 diff 예산 초과: 줄 수만 (근사치)
            result.removed = oldMiddle.count
            result.added = newMiddle.count
            if wholeFile { result.startLine = prefix + 1 }
            return result
        }
        budget -= oldMiddle.count + newMiddle.count

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
            let changed = (i < oldMiddle.count && removedOffsets.contains(i))
                || (j < newMiddle.count && insertedOffsets.contains(j))
            if wholeFile, changed, result.startLine == nil { result.startLine = prefix + j + 1 }
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

    // MARK: - 편집 다시 적용 (replace_all)

    /// Edit/MultiEdit 한 건 (old → new, replace_all 이면 모든 곳)
    struct TextEdit {
        var old: String
        var new: String
        var replaceAll: Bool
    }

    /// 원본 파일에 편집을 순서대로 적용한 결과와 원본을 비교한다. 적용할 수 없으면(못 찾음) nil.
    /// 원본이 커서 정밀 diff 를 못 하면 (바뀐 곳 수 × 한 곳의 diff) 로 줄 수를 어림한다.
    static func diffApplying(_ edits: [TextEdit], to original: String) -> ParsedDiff? {
        guard !edits.isEmpty, !edits.contains(where: { $0.old.isEmpty }) else { return nil }
        if original.utf8.count > maxTextBytes || TextUtils.countLines(original) > maxDiffedLines {
            var total = ParsedDiff()
            var budget = maxDiffedLines
            for edit in edits {
                let count = edit.replaceAll ? occurrences(of: edit.old, in: original) : 1
                guard count > 0 else { return nil }
                var one = diffTexts(old: edit.old, new: edit.new, budget: &budget)
                one.added *= count
                one.removed *= count
                total.merge(one)
            }
            return total
        }
        var updated = original
        for edit in edits {
            guard let range = updated.range(of: edit.old, options: .literal) else { return nil }
            if edit.replaceAll {
                updated = updated.replacingOccurrences(of: edit.old, with: edit.new, options: .literal)
            } else {
                updated.replaceSubrange(range, with: edit.new)
            }
        }
        return diffTexts(old: original, new: updated, wholeFile: true)
    }

    /// 겹치지 않게 센 등장 횟수
    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while let found = haystack.range(of: needle, options: .literal, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }
}
