import AppKit
import Foundation
import NotchCore
import Testing
import UniformTypeIdentifiers
@testable import NotchServices

@Suite("TerminalJumper")
struct TerminalJumperTests {
    @Test func extractsValidITermSessionUUID() {
        let uuid = "9F1C2B3A-1234-4ABC-9DEF-0123456789AB"
        #expect(TerminalJumper.iTermSessionUUID(from: "w0t1p0:\(uuid)") == uuid)
        #expect(TerminalJumper.iTermSessionUUID(from: uuid) == uuid)
        #expect(TerminalJumper.iTermSessionUUID(from: "w12t3p1:\(uuid.lowercased())") == uuid.lowercased())
    }

    @Test func rejectsUnsafeITermSessionIDs() {
        let invalid = [
            "",
            "w0t1p0:",
            "w0t1p0:not-a-uuid",
            "w0t1p0:9F1C2B3A-1234-4ABC-9DEF-0123456789ABX",
            "w0t1p0:9F1C2B3A-1234-4ABC-9DEF-0123456789A\"",
            "w0t1p0:\" & (do shell script \"echo pwned\") & \"",
            "w0t1p0:9F1C2B3A_1234_4ABC_9DEF_0123456789AB",
            "w0t1p0:9F1C2B3A-1234-4ABC-9DEF-0123456789AG",
        ]
        for raw in invalid {
            #expect(TerminalJumper.iTermSessionUUID(from: raw) == nil, "\(raw)")
        }
    }

    @Test func resolvesBundleIdentifier() {
        func resolve(_ context: TerminalContext) -> String? {
            TerminalJumper.resolveBundleIdentifier(for: context)
        }
        #expect(resolve(TerminalContext(termProgram: "iTerm.app")) == "com.googlecode.iterm2")
        #expect(resolve(TerminalContext(termProgram: "Apple_Terminal")) == "com.apple.Terminal")
        #expect(resolve(TerminalContext(termProgram: "vscode")) == "com.microsoft.VSCode")
        #expect(resolve(TerminalContext(termProgram: "WarpTerminal")) == "dev.warp.Warp-Stable")
        #expect(resolve(TerminalContext(termProgram: "ghostty")) == "com.mitchellh.ghostty")
        #expect(resolve(TerminalContext(termProgram: "WezTerm")) == "com.github.wez.wezterm")
        #expect(resolve(TerminalContext(termProgram: "zed")) == "dev.zed.Zed")
        #expect(resolve(TerminalContext(entrypoint: "claude-desktop")) == "com.anthropic.claudefordesktop")
        // 번들 ID 가 있으면 그것을 우선
        #expect(resolve(TerminalContext(termProgram: "tmux", bundleIdentifier: "com.googlecode.iterm2")) == "com.googlecode.iterm2")
        #expect(resolve(TerminalContext(termProgram: "vscode", bundleIdentifier: "com.todesktop.230313mzl4w4u92")) == "com.todesktop.230313mzl4w4u92")
        #expect(resolve(TerminalContext(termProgram: "tmux")) == nil)
        #expect(resolve(TerminalContext()) == nil)
    }

    @MainActor
    @Test func instanceMethodMatchesStatic() {
        let context = TerminalContext(termProgram: "ghostty")
        #expect(TerminalJumper().bundleIdentifier(for: context) == "com.mitchellh.ghostty")
    }
}

@MainActor
@Suite("FrontmostAppMonitor")
struct FrontmostAppMonitorTests {
    @Test func comparesWithSessionTerminal() {
        let monitor = FrontmostAppMonitor()
        monitor.frontmostBundleID = "com.googlecode.iterm2"
        #expect(monitor.isFrontmost(TerminalContext(termProgram: "iTerm.app")))
        #expect(!monitor.isFrontmost(TerminalContext(termProgram: "Apple_Terminal")))
        #expect(!monitor.isFrontmost(TerminalContext()))

        monitor.frontmostBundleID = nil
        #expect(!monitor.isFrontmost(TerminalContext(termProgram: "iTerm.app")))
    }
}

@Suite("FileOpener")
struct FileOpenerTests {
    @Test func classifiesFilesBeforeOpening() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        func make(_ name: String, executable: Bool = false) throws -> String {
            let url = temp.url.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            if executable {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            return url.path
        }

        #expect(FileOpener.disposition(for: try make("notes.md")) == .open)
        #expect(FileOpener.disposition(for: try make("session.swift")) == .open)
        #expect(FileOpener.disposition(for: try make("build.py")) == .openAsText)
        #expect(FileOpener.disposition(for: try make("deploy.sh")) == .openAsText)
        #expect(FileOpener.disposition(for: try make("run.command")) == .reveal)
        #expect(FileOpener.disposition(for: try make("Install.pkg")) == .reveal)
        #expect(FileOpener.disposition(for: try make("tool", executable: true)) == .reveal)
        #expect(FileOpener.disposition(for: temp.url.path) == .reveal)
        #expect(FileOpener.disposition(for: temp.url.appendingPathComponent("missing.txt").path) == .unavailable)
        #expect(FileOpener.disposition(for: "relative/path.txt") == .unavailable)
    }

    @Test func symlinksAreJudgedByRealTarget() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let files = FileFixture(temp)
        try files.make("evil.terminal")
        try files.make("evil.command")
        try files.make("evil.url")
        try files.make("tool", executable: true)
        try files.make("deploy.sh")
        try files.make("real.md")
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("Foo.app"), withIntermediateDirectories: true)

        // 이름은 안전해 보여도 실제 대상이 실행형이면 보여주기만
        #expect(FileOpener.disposition(for: try files.link("notes.md", to: "evil.terminal")) == .reveal)
        #expect(FileOpener.disposition(for: try files.link("readme.txt", to: "evil.command")) == .reveal)
        #expect(FileOpener.disposition(for: try files.link("plain.md", to: "evil.url")) == .reveal)
        #expect(FileOpener.disposition(for: try files.link("doc.txt", to: "tool")) == .reveal)
        #expect(FileOpener.disposition(for: try files.link("photo.png", to: "Foo.app")) == .reveal)
        // 스크립트 대상은 텍스트 편집기로
        #expect(FileOpener.disposition(for: try files.link("todo.md", to: "deploy.sh")) == .openAsText)
        // 링크를 여러 번 거쳐도 끝까지 따라간다
        try files.link("chain2.md", to: "notes.md")
        #expect(FileOpener.disposition(for: try files.link("chain1.md", to: "chain2.md")) == .reveal)
        // 상위 폴더가 링크여도 실제 경로로 판정
        try files.link("docs", to: temp.url.path)
        #expect(FileOpener.disposition(for: temp.url.appendingPathComponent("docs/notes.md").path) == .reveal)

        // 깨진 링크·순환 링크는 열 수 없음
        #expect(FileOpener.disposition(for: try files.link("gone.md", to: "missing.txt")) == .unavailable)
        try files.link("loop-a.md", to: "loop-b.md")
        #expect(FileOpener.disposition(for: try files.link("loop-b.md", to: "loop-a.md")) == .unavailable)

        // 안전한 대상을 가리키는 링크는 대상 기준으로 연다 (링크 이름은 판정에 쓰지 않음)
        let real = try #require(FileOpener.resolvedTarget(for: temp.url.appendingPathComponent("real.md").path))
        #expect(real.hasSuffix("/real.md"))
        let alias = try files.link("alias.md", to: "real.md")
        #expect(FileOpener.disposition(for: alias) == .open)
        #expect(FileOpener.resolvedTarget(for: alias) == real)
        #expect(FileOpener.disposition(for: try files.link("run.command", to: "real.md")) == .open)
    }

    @MainActor
    @Test func openActsOnResolvedTargetNotLink() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let files = FileFixture(temp)
        try files.make("evil.terminal")
        try files.make("tool", executable: true)
        try files.make("deploy.sh")
        try files.make("real.md")
        let notes = try files.link("notes.md", to: "evil.terminal")
        let doc = try files.link("doc.txt", to: "tool")
        let todo = try files.link("todo.md", to: "deploy.sh")
        let alias = try files.link("alias.md", to: "real.md")
        let gone = try files.link("gone.md", to: "missing.txt")
        func target(_ name: String) throws -> URL {
            URL(fileURLWithPath: try #require(FileOpener.resolvedTarget(for: temp.url.appendingPathComponent(name).path)))
        }
        let terminalTarget = try target("evil.terminal")
        let toolTarget = try target("tool")
        let scriptTarget = try target("deploy.sh")
        let realTarget = try target("real.md")

        let workspace = RecordingWorkspace()
        let opener = FileOpener(workspace: workspace)

        // 실행형 대상은 직접 열지 않고 Finder 에서 실제 파일을 보여주기만
        #expect(opener.open(path: notes, line: nil))
        // 대역이 호출을 가로채지 못하면 실제로 열리지 않도록 여기서 멈춘다
        try #require(workspace.revealed.count == 1)
        #expect(opener.open(path: doc, line: nil))
        #expect(workspace.revealed == [[terminalTarget], [toolTarget]])
        #expect(workspace.opened.isEmpty)
        #expect(workspace.openedWithApp.isEmpty)

        // 스크립트 대상은 텍스트 편집기로, 링크가 아닌 실제 파일을 연다
        #expect(opener.open(path: todo, line: nil))
        #expect(workspace.openedWithApp.map(\.urls) == [[scriptTarget]])
        #expect(workspace.openedWithApp.map(\.app) == [RecordingWorkspace.editorURL])
        #expect(workspace.opened.isEmpty)

        // 안전한 대상은 기본 앱으로 열되 링크가 아닌 실제 파일을 넘긴다
        #expect(opener.open(path: alias, line: nil))
        #expect(workspace.opened == [realTarget])

        // 깨진 링크는 아무것도 하지 않는다
        #expect(!opener.open(path: gone, line: nil))
        #expect(workspace.revealed.count == 2)
        #expect(workspace.opened.count == 1)
    }
}

/// 임시 폴더에 테스트 파일과 심볼릭 링크를 만든다
private struct FileFixture {
    let temp: TempDirectory

    init(_ temp: TempDirectory) {
        self.temp = temp
    }

    /// 내용은 무해한 한 글자 (대역이 실패해 실제로 열려도 실행될 것이 없음)
    @discardableResult
    func make(_ name: String, executable: Bool = false) throws -> String {
        let url = temp.url.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url.path
    }

    /// `name` → `destination` 심볼릭 링크 (상대 대상은 같은 폴더 기준)
    @discardableResult
    func link(_ name: String, to destination: String) throws -> String {
        let path = temp.url.appendingPathComponent(name).path
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
        return path
    }
}

/// NSWorkspace 호출을 기록만 하고 실제로는 아무것도 열지 않는 대역
private final class RecordingWorkspace: NSWorkspace {
    static let editorURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")

    var opened: [URL] = []
    var openedWithApp: [(urls: [URL], app: URL)] = []
    var revealed: [[URL]] = []

    override func open(_ url: URL) -> Bool {
        opened.append(url)
        return true
    }

    override func activateFileViewerSelecting(_ fileURLs: [URL]) {
        revealed.append(fileURLs)
    }

    override func urlForApplication(toOpen contentType: UTType) -> URL? {
        Self.editorURL
    }

    override func open(
        _ urls: [URL],
        withApplicationAt applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completionHandler: ((NSRunningApplication?, Error?) -> Void)? = nil
    ) {
        openedWithApp.append((urls, applicationURL))
    }
}
