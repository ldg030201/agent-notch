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

    public init(title: String, detail: String?, symbolName: String) {
        self.title = title
        self.detail = detail
        self.symbolName = symbolName
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
            return ToolSummary(title: titled("Read", file("file_path")), detail: path("file_path"), symbolName: "doc.text")
        case "Edit", "MultiEdit":
            return ToolSummary(title: titled("Edit", file("file_path")), detail: path("file_path"), symbolName: "pencil")
        case "Write":
            return ToolSummary(title: titled("Write", file("file_path")), detail: path("file_path"), symbolName: "doc.badge.plus")
        case "NotebookEdit":
            return ToolSummary(title: titled("Edit", file("notebook_path")), detail: path("notebook_path"), symbolName: "book")
        case "Bash":
            let command = input.string("command")
            let detail = input.string("description") ?? command
            return ToolSummary(
                title: titled("Bash", command),
                detail: detail.map { TextUtils.truncate($0, max: maxDetail) },
                symbolName: "terminal"
            )
        case "Grep":
            return ToolSummary(title: titled("Grep", input.string("pattern")), detail: path("path"), symbolName: "magnifyingglass")
        case "Glob":
            return ToolSummary(title: titled("Glob", input.string("pattern")), detail: path("path"), symbolName: "doc.text.magnifyingglass")
        case "WebFetch":
            let url = input.string("url")
            return ToolSummary(
                title: titled("Fetch", url.flatMap(host(of:))),
                detail: url.map { TextUtils.truncate($0, max: maxDetail) },
                symbolName: "globe"
            )
        case "WebSearch":
            return ToolSummary(title: titled("Search", input.string("query")), detail: nil, symbolName: "magnifyingglass.circle")
        case "Agent", "Task":
            return ToolSummary(
                title: titled("Agent", input.string("description")),
                detail: input.string("subagent_type"),
                symbolName: "person.2"
            )
        case "TodoWrite", "TaskCreate", "TaskUpdate":
            let count = input["todos"]?.arrayValue?.count
            return ToolSummary(title: "Todo", detail: count.map { "\($0)개 항목" }, symbolName: "checklist")
        case "AskUserQuestion":
            return ToolSummary(
                title: "질문",
                detail: firstQuestion(in: toolInput).map { TextUtils.truncate($0, max: maxDetail) },
                symbolName: "questionmark.bubble"
            )
        case "ExitPlanMode":
            return ToolSummary(
                title: "Plan",
                detail: firstPlanLine(in: toolInput).map { TextUtils.truncate($0, max: maxDetail) },
                symbolName: "list.bullet.clipboard"
            )
        default:
            if let mcp = mcpParts(toolName) {
                return ToolSummary(title: "\(mcp.server) · \(mcp.tool)", detail: nil, symbolName: "puzzlepiece.extension")
            }
            return ToolSummary(title: toolName.isEmpty ? "Tool" : toolName, detail: nil, symbolName: "wrench.and.screwdriver")
        }
    }

    /// 권한 요청 카드용 제목/내용.
    /// 승인하면 `tool_input` 전체가 실행되므로 내용을 고치지 않고 숨은 문자만 드러낸다
    /// (줄바꿈 → "⏎" + 줄바꿈, 긴 공백 → "␣×N", 제어 · 서식 문자 → "\u{…}"). 다 못 담으면 `isTruncated`.
    public static func permissionSummary(toolName: String, toolInput: JSONValue?, cwd: String?) -> PermissionSummary {
        let input = HookPayload(toolInput ?? .null)

        /// 글자 수 제한으로 자르고 숨은 문자를 드러낸다
        func shown(_ text: String, max: Int, keepLineBreaks: Bool = false) -> (text: String, truncated: Bool) {
            let truncated = text.count > max
            let cut = truncated ? String(text.prefix(max - 1)) + TextUtils.ellipsis : text
            return (TextUtils.revealInvisibles(cut, keepLineBreaks: keepLineBreaks), truncated)
        }

        switch toolName {
        case "Bash":
            // 앞뒤 공백 · 줄바꿈만 정리 (실행 내용과 무관). 안쪽 공백 · 줄바꿈은 그대로 드러낸다
            let command = (input.string("command") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = shown(command, max: maxPermissionCommand, keepLineBreaks: true)
            return PermissionSummary(title: "Bash 실행 요청", detail: detail.text, isTruncated: detail.truncated)
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            let raw = input.string("file_path") ?? input.string("notebook_path") ?? ""
            let detail = shown(TextUtils.displayPath(raw, cwd: cwd), max: maxPermissionCommand)
            return PermissionSummary(title: "파일 수정 요청", detail: detail.text, isTruncated: detail.truncated)
        case "WebFetch":
            let detail = shown(input.string("url") ?? "", max: maxDetail)
            return PermissionSummary(title: "웹 요청", detail: detail.text, isTruncated: detail.truncated)
        case "ExitPlanMode":
            // 계획은 첫 줄만 보여준다 → 나머지가 있으면 잘린 것
            let plan = toolInput?["plan"]?.stringValue ?? ""
            let lineCount = plan.split(whereSeparator: \.isNewline)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            let detail = shown(firstPlanLine(in: toolInput) ?? "", max: maxDetail)
            return PermissionSummary(title: "계획 승인 요청", detail: detail.text, isTruncated: detail.truncated || lineCount > 1)
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

    // MARK: - 헬퍼

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
