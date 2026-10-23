import Foundation
import NotchShared

/// Codex 의 파일 수정 툴(`apply_patch`) 입력 해석.
///
/// 훅은 패치 글을 `tool_input.command` 로 넘긴다 (Bash 처럼). 패치는 줄 번호가 없는 Codex 고유 모양이다:
/// ```
/// *** Begin Patch
/// *** Add File: path      (뒤 줄은 모두 "+")
/// *** Delete File: path
/// *** Update File: path
/// *** Move to: new/path   (선택)
/// @@ 맥락 (선택)
///  맥락 줄 · -지운 줄 · +더한 줄
/// *** End of File         (선택)
/// *** End Patch
/// ```
/// 셸 heredoc(`apply_patch <<'EOF' …`)으로 감싸 와도 `*** Begin Patch` 부터 읽는다. 모르는 줄은 건너뛴다.
struct ApplyPatch: Equatable {
    enum Operation: Equatable {
        case add
        case update
        case delete
    }

    struct File: Equatable {
        /// 패치에 적힌 경로 (보통 작업 폴더 기준 상대 경로)
        var path: String
        /// `*** Move to:` 로 옮긴 새 경로
        var movedTo: String?
        var operation: Operation
        /// 앞 글자(" " · "+" · "-")를 붙인 그대로의 내용 줄
        var lines: [Substring]

        /// 수정 뒤 경로 (옮겼으면 새 경로)
        var resultPath: String { movedTo ?? path }
    }

    var files: [File]

    /// Codex 의 툴 이름
    static let toolName = "apply_patch"

    /// 툴 입력에서 패치 글을 꺼낸다: `command` (훅이 넘기는 모양), `input` · `patch`, 입력이 글 자체인 경우
    static func text(in toolInput: JSONValue?) -> String? {
        guard let toolInput else { return nil }
        if let text = toolInput.stringValue { return text }
        for key in ["command", "input", "patch"] {
            if let text = toolInput[key]?.stringValue { return text }
            // 셸 명령 배열(["apply_patch", "<패치>"])로 오면 패치가 든 마지막 조각
            if let parts = toolInput[key]?.arrayValue?.compactMap(\.stringValue),
               let patch = parts.last(where: { $0.contains(fileHeaderPrefix) }) {
                return patch
            }
        }
        return nil
    }

    static func parse(toolInput: JSONValue?) -> ApplyPatch? {
        text(in: toolInput).flatMap(parse)
    }

    /// 파일이 하나도 없으면 nil
    static func parse(_ text: String) -> ApplyPatch? {
        var lines = TextUtils.splitLines(text)[...]
        if let begin = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "*** Begin Patch" }) {
            lines = lines[lines.index(after: begin)...]
        }
        var files: [File] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "*** End Patch" { break }
            if let path = header(trimmed, "*** Add File:") {
                files.append(File(path: path, operation: .add, lines: []))
            } else if let path = header(trimmed, "*** Delete File:") {
                files.append(File(path: path, operation: .delete, lines: []))
            } else if let path = header(trimmed, "*** Update File:") {
                files.append(File(path: path, operation: .update, lines: []))
            } else if let path = header(trimmed, "*** Move to:") {
                if !files.isEmpty { files[files.count - 1].movedTo = path }
            } else if line.hasPrefix("***") || line.hasPrefix("@@") {
                // *** End of File · 맥락 머리
                continue
            } else if let first = line.first, first == "+" || first == "-" || first == " ", !files.isEmpty {
                files[files.count - 1].lines.append(line)
            }
        }
        return files.isEmpty ? nil : ApplyPatch(files: files)
    }

    private static let fileHeaderPrefix = "*** "

    private static func header(_ line: String, _ prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return TextUtils.nonEmpty(String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
    }

    /// 상대 경로를 작업 폴더 기준 절대 경로로 (이미 절대 경로거나 작업 폴더를 모르면 그대로)
    static func absolutePath(_ path: String, cwd: String?) -> String {
        guard !path.hasPrefix("/"), !path.hasPrefix("~"), let cwd, cwd.hasPrefix("/") else { return path }
        return (URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(path).standardizedFileURL.path)
    }
}
