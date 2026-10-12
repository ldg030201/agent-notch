import Foundation
import Testing
@testable import NotchCore
import NotchShared

@Suite struct ToolSummarizerTests {
    @Test(arguments: [
        ("Read", #"{"file_path":"/Users/dev/projects/api-server/src/a.ts"}"#, "Read a.ts", "doc.text"),
        ("Edit", #"{"file_path":"/Users/dev/projects/api-server/src/session.ts"}"#, "Edit session.ts", "pencil"),
        ("MultiEdit", #"{"file_path":"/Users/dev/projects/api-server/src/session.ts"}"#, "Edit session.ts", "pencil"),
        ("Write", #"{"file_path":"/Users/dev/projects/api-server/new.ts"}"#, "Write new.ts", "doc.badge.plus"),
        ("NotebookEdit", #"{"notebook_path":"/Users/dev/projects/api-server/n.ipynb"}"#, "Edit n.ipynb", "book"),
        ("Bash", #"{"command":"npm test"}"#, "Bash npm test", "terminal"),
        ("Grep", #"{"pattern":"TODO"}"#, "Grep TODO", "magnifyingglass"),
        ("Glob", #"{"pattern":"**/*.ts"}"#, "Glob **/*.ts", "doc.text.magnifyingglass"),
        ("WebFetch", #"{"url":"https://docs.example.com/a/b?c=1"}"#, "Fetch docs.example.com", "globe"),
        ("WebSearch", #"{"query":"swift testing"}"#, "Search swift testing", "magnifyingglass.circle"),
        ("Agent", #"{"description":"코드 탐색","subagent_type":"Explore"}"#, "Agent 코드 탐색", "person.2"),
        ("Task", #"{"description":"리뷰"}"#, "Agent 리뷰", "person.2"),
        ("TodoWrite", #"{"todos":[{"content":"a"},{"content":"b"}]}"#, "Todo", "checklist"),
        ("TaskCreate", "{}", "Todo", "checklist"),
        ("TaskUpdate", "{}", "Todo", "checklist"),
        ("AskUserQuestion", #"{"questions":[{"question":"어느 쪽?"}]}"#, "질문", "questionmark.bubble"),
        ("ExitPlanMode", #"{"plan":"계획"}"#, "Plan", "list.bullet.clipboard"),
        ("mcp__github__create_issue", "{}", "github · create_issue", "puzzlepiece.extension"),
        ("mcp__plugin_design_figma__get_file", "{}", "plugin_design_figma · get_file", "puzzlepiece.extension"),
        ("LSP", "{}", "LSP", "wrench.and.screwdriver"),
        ("Read", "{}", "Read", "doc.text"),
    ])
    func titles(tool: String, input: String, title: String, symbol: String) {
        let summary = ToolSummarizer.summarize(toolName: tool, toolInput: json(input), cwd: projectCwd)
        #expect(summary.title == title)
        #expect(summary.symbolName == symbol)
    }

    @Test func bashTitleAndDetail() {
        let longCommand = "npm run build && npm run test -- --coverage --watch=false --reporter=verbose\necho done"
        let input = JSONValue.object(["command": .string(longCommand)])
        let summary = ToolSummarizer.summarize(toolName: "Bash", toolInput: input, cwd: projectCwd)
        #expect(summary.title.hasPrefix("Bash npm run build"))
        #expect(summary.title.count == "Bash ".count + ToolSummarizer.maxTitleArgument)
        #expect(summary.title.hasSuffix("…"))
        #expect(summary.detail == longCommand)

        let described = ToolSummarizer.summarize(
            toolName: "Bash",
            toolInput: json(#"{"command":"rm -rf node_modules","description":"Remove node_modules"}"#),
            cwd: projectCwd
        )
        #expect(described.detail == "Remove node_modules")
    }

    @Test func detailPathsRelativeToCwd() {
        let inside = ToolSummarizer.summarize(toolName: "Read", toolInput: json(#"{"file_path":"/Users/dev/projects/api-server/src/a.ts"}"#), cwd: projectCwd)
        #expect(inside.detail == "src/a.ts")
        let outside = ToolSummarizer.summarize(toolName: "Read", toolInput: json(#"{"file_path":"/Users/dev/projects/api-server-old/a.ts"}"#), cwd: projectCwd)
        #expect(outside.detail == "/Users/dev/projects/api-server-old/a.ts")
        let noCwd = ToolSummarizer.summarize(toolName: "Read", toolInput: json(#"{"file_path":"/a/b.ts"}"#), cwd: nil)
        #expect(noCwd.detail == "/a/b.ts")
        let grep = ToolSummarizer.summarize(toolName: "Grep", toolInput: json(#"{"pattern":"x","path":"/Users/dev/projects/api-server/src"}"#), cwd: projectCwd)
        #expect(grep.detail == "src")
    }

    @Test func otherDetails() {
        let todo = ToolSummarizer.summarize(toolName: "TodoWrite", toolInput: json(#"{"todos":[{},{},{}]}"#), cwd: nil)
        #expect(todo.detail == "3개 항목")
        let ask = ToolSummarizer.summarize(toolName: "AskUserQuestion", toolInput: json(#"{"questions":[{"question":"어느 DB?"}]}"#), cwd: nil)
        #expect(ask.detail == "어느 DB?")
        let plan = ToolSummarizer.summarize(toolName: "ExitPlanMode", toolInput: json(##"{"plan":"# 세션 TTL\n- 설정"}"##), cwd: nil)
        #expect(plan.detail == "세션 TTL")
        let missing = ToolSummarizer.summarize(toolName: "", toolInput: nil, cwd: nil)
        #expect(missing.title == "Tool")
    }

    @Test func mcpParts() {
        #expect(ToolSummarizer.mcpParts("mcp__server__tool")?.server == "server")
        #expect(ToolSummarizer.mcpParts("mcp__server__tool__x")?.tool == "tool__x")
        #expect(ToolSummarizer.mcpParts("mcp__server") == nil)
        #expect(ToolSummarizer.mcpParts("Bash") == nil)
    }
}

@Suite struct TextUtilsTests {
    @Test func cleanPrompt() {
        #expect(TextUtils.cleanPrompt("  hello \n\n  world\t ") == "hello world")
        #expect(TextUtils.cleanPrompt(#"이거 봐 <pasted_content id="p1">line1\#nline2</pasted_content> 고쳐줘"#) == "이거 봐 [붙여넣음] 고쳐줘")
        #expect(TextUtils.cleanPrompt(#"<pasted_content id="a">x</pasted_content><pasted_content id="b">y</pasted_content>"#) == "[붙여넣음] [붙여넣음]")
        // 닫는 태그가 없으면 끝까지 붙여넣은 내용으로 본다
        #expect(TextUtils.cleanPrompt(#"앞부분 <pasted_content id="p">secret"#) == "앞부분 [붙여넣음]")
        let long = String(repeating: "가", count: 500)
        let cleaned = TextUtils.cleanPrompt(long)
        #expect(cleaned.count == 200)
        #expect(cleaned.hasSuffix("…"))
    }

    @Test func truncate() {
        #expect(TextUtils.truncate("abc", max: 3) == "abc")
        #expect(TextUtils.truncate("abcd", max: 3) == "ab…")
        #expect(TextUtils.truncate("abc", max: 0) == "")
    }

    @Test func projectName() {
        #expect(TextUtils.projectName(forCwd: "/Users/dev/projects/api-server") == "api-server")
        #expect(TextUtils.projectName(forCwd: "/Users/dev/projects/api-server/") == "api-server")
        #expect(TextUtils.projectName(forCwd: "") == "unknown")
        #expect(TextUtils.projectName(forCwd: "/") == "unknown")
    }

    @Test func displayPath() {
        #expect(TextUtils.displayPath("/Users/dev/p", cwd: "/Users/dev/p") == ".")
        #expect(TextUtils.displayPath("/Users/dev/p/a/b", cwd: "/Users/dev/p/") == "a/b")
        #expect(TextUtils.displayPath("/Users/dev/pp/a", cwd: "/Users/dev/p") == "/Users/dev/pp/a")
    }

    @Test func countLines() {
        #expect(TextUtils.countLines("") == 0)
        #expect(TextUtils.countLines("a") == 1)
        #expect(TextUtils.countLines("a\n") == 1)
        #expect(TextUtils.countLines("a\nb") == 2)
        #expect(TextUtils.splitLines("a\n\nb\n").count == 3)
    }

    /// Int 범위 밖 숫자는 트랩 대신 nil (#13)
    @Test func intValueRange() {
        #expect(json(#"{"n":42.9}"#)["n"]?.intValue == 42)
        #expect(json(#"{"n":-42.9}"#)["n"]?.intValue == -42)
        #expect(json(#"{"n":1e18}"#)["n"]?.intValue == 1_000_000_000_000_000_000)
        #expect(json(#"{"n":1e19}"#)["n"]?.intValue == nil)
        #expect(json(#"{"n":-1e19}"#)["n"]?.intValue == nil)
        #expect(json(#"{"n":9223372036854775807}"#)["n"]?.intValue == nil)
        #expect(JSONValue.number(.nan).intValue == nil)
        #expect(JSONValue.number(.infinity).intValue == nil)
        #expect(JSONValue.string("1").intValue == nil)
    }

    @Test func revealInvisiblesKeepsShortWhitespace() {
        #expect(TextUtils.revealInvisibles("a\tb    c", keepLineBreaks: true) == "a\tb    c")
        #expect(TextUtils.revealInvisibles("a" + String(repeating: " ", count: 8) + "b", keepLineBreaks: false) == "a        b")
        #expect(TextUtils.revealInvisibles("a" + String(repeating: "\t", count: 9) + "b", keepLineBreaks: false) == "a␣×9b")
        #expect(TextUtils.revealInvisibles("a\nb", keepLineBreaks: false) == "a⏎b")
        #expect(TextUtils.revealInvisibles("한글 경로/파일.ts", keepLineBreaks: false) == "한글 경로/파일.ts")
        #expect(TextUtils.revealInvisibles("\u{1B}[31m", keepLineBreaks: false) == "\\u{1B}[31m")
    }
}
