import Foundation
import NotchShared

/// 툴 호출 한 건을 타임라인/노치에 보여줄 요약
public struct ToolSummary: Hashable, Sendable {
    /// 짧은 제목 (예: "Edit session.ts", "Bash npm test")
    public var title: String
    /// 보조 설명 (전체 명령어, cwd 기준 경로 등)
    public var detail: String?
    /// SF Symbol 이름
    public var symbolName: String
    /// 접힌 상태에 쓰는 짧은 툴 이름 (예: "Bash", "Edit", MCP 는 서버 이름 "Claude_Browser")
    public var label: String

    /// - label: 없으면 제목 첫 단어
    public init(title: String, detail: String?, symbolName: String, label: String? = nil) {
        self.title = title
        self.detail = detail
        self.symbolName = symbolName
        self.label = label ?? title.split(separator: " ").first.map(String.init) ?? title
    }
}

/// 권한 요청 카드에 보여줄 요약
public struct PermissionSummary: Hashable, Sendable {
    /// 예: "Bash 실행 요청"
    public var title: String
    /// 예: 명령어, 파일 경로. 숨은 문자는 드러낸 상태 (줄바꿈 → "⏎")
    public var detail: String
    /// `detail` 이 원본 입력을 다 담지 못함 (글자 수 제한으로 잘림 · 일부만 표시)
    public var isTruncated: Bool

    public init(title: String, detail: String, isTruncated: Bool = false) {
        self.title = title
        self.detail = detail
        self.isTruncated = isTruncated
    }
}

/// 툴 이름 + `tool_input` → 사람이 읽는 요약
public enum ToolSummarizer {
    /// 제목에 들어가는 인자(명령어 첫 줄, 패턴 등) 최대 길이
    static let maxTitleArgument = 48
    /// 보조 설명 최대 길이
    static let maxDetail = 300
    /// 권한 요청 명령어 최대 길이
    static let maxPermissionCommand = 1_000

    public static func summarize(toolName: String, toolInput: JSONValue?, cwd: String?) -> ToolSummary {
        let input = HookPayload(toolInput ?? .null)

        func titled(_ verb: String, _ argument: String?) -> String {
            guard let argument = TextUtils.nonEmpty(argument.map(TextUtils.firstLine)) else { return verb }
            return "\(verb) \(TextUtils.truncate(argument, max: maxTitleArgument))"
        }
        func path(_ key: String) -> String? {
            input.string(key).map { TextUtils.truncate(TextUtils.displayPath($0, cwd: cwd), max: maxDetail) }
        }
        func file(_ key: String) -> String? {
            input.string(key).map(TextUtils.fileName)
        }

        switch toolName {
        case "Read":
            return ToolSummary(title: titled("Read", file("file_path")), detail: path("file_path"), symbolName: "doc.text", label: "Read")
        case "Edit", "MultiEdit":
            return ToolSummary(title: titled("Edit", file("file_path")), detail: path("file_path"), symbolName: "pencil", label: "Edit")
        case "Write":
            return ToolSummary(title: titled("Write", file("file_path")), detail: path("file_path"), symbolName: "doc.badge.plus", label: "Write")
        case "NotebookEdit":
            return ToolSummary(title: titled("Edit", file("notebook_path")), detail: path("notebook_path"), symbolName: "book", label: "Edit")
        case "Bash":
            let command = shellCommand(toolInput)
            let detail = input.string("description") ?? command
            return ToolSummary(
                title: titled("Bash", command),
                detail: detail.map { TextUtils.truncate($0, max: maxDetail) },
                symbolName: "terminal",
                label: "Bash"
            )
        case "Grep":
            return ToolSummary(title: titled("Grep", input.string("pattern")), detail: path("path"), symbolName: "magnifyingglass", label: "Grep")
        case "Glob":
            return ToolSummary(title: titled("Glob", input.string("pattern")), detail: path("path"), symbolName: "doc.text.magnifyingglass", label: "Glob")
        case "WebFetch":
            let url = input.string("url")
            return ToolSummary(
                title: titled("Fetch", url.flatMap(host(of:))),
                detail: url.map { TextUtils.truncate($0, max: maxDetail) },
                symbolName: "globe",
                label: "Fetch"
            )
        case "WebSearch":
            return ToolSummary(title: titled("Search", input.string("query")), detail: nil, symbolName: "magnifyingglass.circle", label: "Search")
        case "Agent", "Task":
            return ToolSummary(
                title: titled("Agent", input.string("description")),
                detail: input.string("subagent_type"),
                symbolName: "person.2",
                label: "Agent"
            )
        case "TodoWrite", "TaskCreate", "TaskUpdate":
            let count = input["todos"]?.arrayValue?.count
            return ToolSummary(title: "Todo", detail: count.map { "\($0)개 항목" }, symbolName: "checklist", label: "Todo")
        case "AskUserQuestion":
            return ToolSummary(
                title: "질문",
                detail: firstQuestion(in: toolInput).map { TextUtils.truncate($0, max: maxDetail) },
                symbolName: "questionmark.bubble",
                label: "질문"
            )
        case "ExitPlanMode":
            return ToolSummary(
                title: "Plan",
                detail: firstPlanLine(in: toolInput).map { TextUtils.truncate($0, max: maxDetail) },
                symbolName: "list.bullet.clipboard",
                label: "Plan"
            )
        // Codex 툴 (셸은 "Bash", MCP 는 mcp__<서버>__<툴> 로 와서 위와 같다)
        case ApplyPatch.toolName:
            let files = ApplyPatch.parse(toolInput: toolInput)?.files ?? []
            let title: String
            if files.count == 1 {
                title = titled(files[0].operation == .add ? "Write" : "Edit", TextUtils.fileName(files[0].resultPath))
            } else {
                title = files.isEmpty ? "Edit" : "Edit \(files.count)개 파일"
            }
            let paths = files.map { TextUtils.displayPath(ApplyPatch.absolutePath($0.resultPath, cwd: cwd), cwd: cwd) }
            return ToolSummary(
                title: title,
                detail: TextUtils.nonEmpty(paths.joined(separator: ", ")).map { TextUtils.truncate($0, max: maxDetail) },
                symbolName: files.count == 1 && files[0].operation == .add ? "doc.badge.plus" : "pencil",
                label: "Edit"
            )
        case "update_plan":
            let count = input["plan"]?.arrayValue?.count
            return ToolSummary(title: "Todo", detail: count.map { "\($0)개 항목" }, symbolName: "checklist", label: "Todo")
        case "spawn_agent":
            let name = input.string("task_name") ?? input.string("agent_type") ?? input.string("name")
            return ToolSummary(
                title: titled("Agent", name),
                detail: input.string("message").map { TextUtils.truncate(TextUtils.firstLine($0), max: maxDetail) },
                symbolName: "person.2",
                label: "Agent"
            )
        case "request_user_input", "request_user_input_async":
            return ToolSummary(
                title: "질문",
                detail: firstQuestion(in: toolInput).map { TextUtils.truncate($0, max: maxDetail) },
                symbolName: "questionmark.bubble",
                label: "질문"
            )
        case "view_image":
            return ToolSummary(title: titled("Read", file("path")), detail: path("path"), symbolName: "photo", label: "Read")
        case "exec", "js":
            // 코드 모드: 모델이 쓴 JS 안에서 다른 툴을 부른다 (안쪽 툴은 각자 따로 훅이 온다)
            return ToolSummary(title: titled("Code", input.string("title")), detail: nil, symbolName: "curlybraces", label: "Code")
        default:
            if let mcp = mcpParts(toolName) {
                // 접힌 상태엔 서버 이름만 (툴 이름은 펼친 타임라인에)
                return ToolSummary(title: "\(mcp.server) · \(mcp.tool)", detail: nil, symbolName: "puzzlepiece.extension", label: mcp.server)
            }
            let name = toolName.isEmpty ? "Tool" : toolName
            return ToolSummary(title: name, detail: nil, symbolName: "wrench.and.screwdriver", label: name)
        }
    }

    /// 권한 요청 카드용 제목/내용.
    /// 승인하면 `tool_input` 전체가 실행되므로 내용을 고치지 않고 숨은 문자만 드러낸다
    /// (줄바꿈 → "⏎" + 줄바꿈, 긴 공백 → "␣×N", 제어 · 서식 문자 → "\u{…}"). 다 못 담으면 `isTruncated`.
    public static func permissionSummary(toolName: String, toolInput: JSONValue?, cwd: String?) -> PermissionSummary {
        let input = HookPayload(toolInput ?? .null)

        /// 글자 수 제한으로 자르고 숨은 문자를 드러낸다
        func shown(_ text: String, max: Int, keepLineBreaks: Bool = false) -> (text: String, truncated: Bool) {
            let cut = TextUtils.truncate(text, max: max)
            return (TextUtils.revealInvisibles(cut, keepLineBreaks: keepLineBreaks), cut != text)
        }

        switch toolName {
        case "Bash":
            // 앞뒤 공백 · 줄바꿈만 정리 (실행 내용과 무관). 안쪽 공백 · 줄바꿈은 그대로 드러낸다
            let command = (shellCommand(toolInput) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = shown(command, max: maxPermissionCommand, keepLineBreaks: true)
            // 승인하면 명령만이 아니라 실행 방식도 같이 허락한다: 샌드박스 해제는 제목과 첫 줄에, 백그라운드는 제목에 드러낸다.
            // 값이 true 가 아니어도 비어 있지 않으면 켠 것으로 본다 (안 보이는 쪽보다 더 보이는 쪽이 안전)
            let unsandboxed = isSet(toolInput?["dangerouslyDisableSandbox"])
            let background = isSet(toolInput?["run_in_background"])
            var title = "Bash 실행 요청"
            if unsandboxed { title += " · 샌드박스 해제" }
            if background { title += " · 백그라운드" }
            let text = unsandboxed ? "\(sandboxWarning)\n\(detail.text)" : detail.text
            return PermissionSummary(title: title, detail: text, isTruncated: detail.truncated)
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            let raw = input.string("file_path") ?? input.string("notebook_path") ?? ""
            let detail = shown(TextUtils.displayPath(raw, cwd: cwd), max: maxPermissionCommand)
            return PermissionSummary(title: "파일 수정 요청", detail: detail.text, isTruncated: detail.truncated)
        case "WebFetch":
            let detail = shown(input.string("url") ?? "", max: maxDetail)
            return PermissionSummary(title: "웹 요청", detail: detail.text, isTruncated: detail.truncated)
        case ApplyPatch.toolName:
            // Codex 파일 수정: 파일마다 "추가 · 수정 · 삭제 · 이동" 한 줄. 패치를 읽지 못하면 입력 그대로 (다 안 보이면 허용을 막는다)
            guard let patch = ApplyPatch.parse(toolInput: toolInput) else {
                let raw = shown(ApplyPatch.text(in: toolInput) ?? TextUtils.compactJSON(toolInput), max: maxPermissionCommand, keepLineBreaks: true)
                return PermissionSummary(title: "파일 수정 요청", detail: raw.text, isTruncated: raw.truncated)
            }
            let lines = patch.files.map { file -> String in
                let path = TextUtils.displayPath(ApplyPatch.absolutePath(file.path, cwd: cwd), cwd: cwd)
                switch file.operation {
                case .add: return "추가 \(path)"
                case .delete: return "삭제 \(path)"
                case .update:
                    guard let moved = file.movedTo else { return "수정 \(path)" }
                    return "이동 \(path) → \(TextUtils.displayPath(ApplyPatch.absolutePath(moved, cwd: cwd), cwd: cwd))"
                }
            }
            let detail = shown(lines.joined(separator: "\n"), max: maxPermissionCommand, keepLineBreaks: true)
            return PermissionSummary(title: "파일 수정 요청", detail: detail.text, isTruncated: detail.truncated)
        default:
            if let mcp = mcpParts(toolName) {
                // 서버 · 툴 이름 다음 줄에 인자 JSON (인자가 없으면 이름만)
                let arguments = toolInput?.objectValue?.isEmpty == true ? nil : toolInput
                let json = shown(TextUtils.compactJSON(arguments), max: maxDetail)
                let header = TextUtils.revealInvisibles("\(mcp.server) · \(mcp.tool)", keepLineBreaks: false)
                let detail = json.text.isEmpty ? header : header + "\n" + json.text
                return PermissionSummary(title: "MCP 툴 요청", detail: detail, isTruncated: json.truncated)
            }
            let json = shown(TextUtils.compactJSON(toolInput), max: maxDetail)
            let name = toolName.isEmpty ? "툴" : toolName
            return PermissionSummary(title: "\(name) 사용 요청", detail: json.text, isTruncated: json.truncated)
        }
    }

    /// Bash 권한 카드 첫 줄: 샌드박스 밖에서 실행 (`dangerouslyDisableSandbox`)
    static let sandboxWarning = "⚠ 샌드박스 밖에서 실행"

    // MARK: - 헬퍼

    /// 셸 명령: `command` 문자열, 배열(`["bash", "-lc", "…"]`)이면 공백으로 이은 것
    static func shellCommand(_ toolInput: JSONValue?) -> String? {
        if let command = toolInput?["command"]?.stringValue { return command }
        if let parts = toolInput?["command"]?.arrayValue?.compactMap(\.stringValue), !parts.isEmpty {
            return parts.joined(separator: " ")
        }
        return toolInput?["cmd"]?.stringValue
    }

    /// 실행 옵션이 켜졌는지 (JS 처럼 false · 0 · 빈 문자열 · null 만 꺼짐)
    static func isSet(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null?: return false
        case .bool(let flag)?: return flag
        case .number(let number)?: return number != 0 && !number.isNaN
        case .string(let text)?: return !text.isEmpty
        case .array?, .object?: return true
        }
    }

    /// `mcp__<server>__<tool>` → (server, tool)
    static func mcpParts(_ toolName: String) -> (server: String, tool: String)? {
        guard toolName.hasPrefix("mcp__") else { return nil }
        let rest = toolName.dropFirst("mcp__".count)
        guard let separator = rest.range(of: "__") else { return nil }
        let server = String(rest[..<separator.lowerBound])
        let tool = String(rest[separator.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }

    /// AskUserQuestion 의 첫 질문 문구
    static func firstQuestion(in toolInput: JSONValue?) -> String? {
        guard let first = toolInput?["questions"]?[0] else { return nil }
        let text = first["question"]?.stringValue ?? first.stringValue ?? first["header"]?.stringValue
        return TextUtils.nonEmpty(text.map(TextUtils.collapseWhitespace))
    }

    /// ExitPlanMode 계획의 첫 줄 (마크다운 제목 기호 제거)
    static func firstPlanLine(in toolInput: JSONValue?) -> String? {
        guard let plan = toolInput?["plan"]?.stringValue else { return nil }
        for line in plan.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                .trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func host(of urlString: String) -> String? {
        if let host = URLComponents(string: urlString)?.host, !host.isEmpty { return host }
        return urlString
    }
}
