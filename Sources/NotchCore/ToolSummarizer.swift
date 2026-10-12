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
    /// 예: 명령어, 파일 경로
    public var detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
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

    /// 권한 요청 카드용 제목/내용
    public static func permissionSummary(toolName: String, toolInput: JSONValue?, cwd: String?) -> PermissionSummary {
        let input = HookPayload(toolInput ?? .null)
        switch toolName {
        case "Bash":
            let command = (input.string("command") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return PermissionSummary(title: "Bash 실행 요청", detail: TextUtils.truncate(command, max: maxPermissionCommand))
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            let raw = input.string("file_path") ?? input.string("notebook_path") ?? ""
            return PermissionSummary(title: "파일 수정 요청", detail: TextUtils.displayPath(raw, cwd: cwd))
        case "WebFetch":
            return PermissionSummary(title: "웹 요청", detail: TextUtils.truncate(input.string("url") ?? "", max: maxDetail))
        case "ExitPlanMode":
            return PermissionSummary(
                title: "계획 승인 요청",
                detail: TextUtils.truncate(firstPlanLine(in: toolInput) ?? "", max: maxDetail)
            )
        default:
            if let mcp = mcpParts(toolName) {
                return PermissionSummary(title: "MCP 툴 요청", detail: "\(mcp.server) · \(mcp.tool)")
            }
            let name = toolName.isEmpty ? "툴" : toolName
            return PermissionSummary(title: "\(name) 사용 요청", detail: TextUtils.compactJSON(toolInput, max: maxDetail))
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
