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

    @Test func iTermScriptHasTimeoutAndOnlyValidatedUUID() throws {
        let uuid = "9F1C2B3A-1234-4ABC-9DEF-0123456789AB"
        let script = try #require(TerminalJumper.iTermSelectScript(uuid))
        // 멈춘 iTerm2 를 끝없이 기다리지 않는다
        #expect(script.hasPrefix("with timeout of \(TerminalJumper.scriptTimeoutSeconds) seconds"))
        #expect(script.contains("end timeout"))
        #expect(script.contains("is \"\(uuid)\""))
        #expect(TerminalJumper.iTermSelectScript("\" & (do shell script \"id\") & \"") == nil)
    }

    /// AppleScript 가 멈춰 있어도 `jump` 는 바로 돌아오고, 스크립트는 메인 밖에서 돈다
    @MainActor
    @Test func iTermSelectionRunsOffMainThread() async throws {
        let uuid = "9F1C2B3A-1234-4ABC-9DEF-0123456789AB"
        let gate = DispatchSemaphore(value: 0)
        let ranOnMain = LockedValue<Bool?>(nil)
        var activated: [String] = []
        let jumper = TerminalJumper(
            selectITermSession: { selected in
                ranOnMain.set(pthread_main_np() != 0)
                gate.wait()
                return selected == uuid
            },
            isRunning: { $0 == TerminalJumper.iTermBundleID },
            activate: { activated.append($0); return true }
        )

        #expect(jumper.jump(to: TerminalContext(termProgram: "iTerm.app", itermSessionID: "w0t1p0:\(uuid)")))
        // 스크립트가 끝나기 전에는 아무것도 활성화하지 않는다
        #expect(activated.isEmpty)
        gate.signal()
        #expect(await waitUntil { activated == [TerminalJumper.iTermBundleID] })
        #expect(ranOnMain.get() == false)
    }

    @MainActor
    @Test func iTermSelectionFailureFallsBackToApp() async throws {
        let uuid = "9F1C2B3A-1234-4ABC-9DEF-0123456789AB"
        var activated: [String] = []
        let jumper = TerminalJumper(
            selectITermSession: { _ in false },
            isRunning: { _ in true },
            activate: { activated.append($0); return true }
        )
        // TERM_PROGRAM 이 iTerm2 면 세션을 못 골라도 앱은 앞으로 가져온다
        #expect(jumper.jump(to: TerminalContext(termProgram: "iTerm.app", itermSessionID: uuid)))
        #expect(await waitUntil { activated == [TerminalJumper.iTermBundleID] })

        // 어느 앱인지 모르면 세션을 못 골랐을 때 할 일이 없다
        activated = []
        #expect(jumper.jump(to: TerminalContext(itermSessionID: uuid)))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(activated.isEmpty)

        // iTerm2 가 아니면 AppleScript 없이 바로 그 앱을
        #expect(jumper.jump(to: TerminalContext(termProgram: "ghostty", itermSessionID: uuid)))
        #expect(activated == ["com.mitchellh.ghostty"])
    }
}

/// 여러 스레드에서 쓰는 값 (테스트 기록용)
private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
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
    /// 텍스트로 열 파일은 기본 앱이 코드 편집기일 때만 그 앱으로 (실행기 · 설치기는 아님)
    @Test func onlyKnownEditorsOpenTextFiles() {
        for editor in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.jetbrains.intellij",
                       "com.jetbrains.goland", "dev.zed.Zed", "com.apple.dt.Xcode", "com.apple.TextEdit"] {
            #expect(FileOpener.isKnownEditor(bundleIdentifier: editor), "\(editor)")
        }
        for runner in ["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.ScriptEditor2", "com.apple.shortcuts",
                       "com.apple.installer", "org.python.PythonLauncher", "com.apple.ScreenSharing", "com.jetbrainsx.fake"] {
            #expect(!FileOpener.isKnownEditor(bundleIdentifier: runner), "\(runner)")
        }
    }

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
        #expect(FileOpener.disposition(for: try make("Info.term")) == .reveal)
        #expect(FileOpener.disposition(for: try make("evil.mobileconfig")) == .reveal)
        #expect(FileOpener.disposition(for: try make("page.html")) == .openAsText)
        #expect(FileOpener.disposition(for: try make("unknown.xyz")) == .openAsText)
        #expect(FileOpener.disposition(for: try make("build.py")) == .openAsText)
        #expect(FileOpener.disposition(for: try make("deploy.sh")) == .openAsText)
        #expect(FileOpener.disposition(for: try make("run.command")) == .reveal)
        #expect(FileOpener.disposition(for: try make("Install.pkg")) == .reveal)
        #expect(FileOpener.disposition(for: try make("tool", executable: true)) == .reveal)
        #expect(FileOpener.disposition(for: temp.url.path) == .reveal)
        #expect(FileOpener.disposition(for: temp.url.appendingPathComponent("missing.txt").path) == .unavailable)
        #expect(FileOpener.disposition(for: "relative/path.txt") == .unavailable)
    }

    /// 형식이 `public.data` 뿐이거나 XML 을 따르지만 열면 실행 · 설치 · 접속하는 형식은 보여주기만
    @Test func revealsTypesThatRunOrInstallWhenOpened() {
        let risky = [
            "term", "terminal", "command", "tool", "scpt", "applescript", "workflow", "wflow", "shortcut",
            "configprofile", "provisionprofile", "mobileprovision", "mobileconfig",
            "vncloc", "afploc", "ftploc", "smbloc", "webloc", "inetloc", "fileloc", "url", "webbookmark",
            "jnlp", "jar", "pkg", "dmg", "prefpane",
            // 대문자 확장자도 같다
            "TERM", "ConfigProfile",
        ]
        for ext in risky {
            #expect(FileOpener.classify(extension: ext) == .reveal, "\(ext)")
        }
    }

    /// 허용 목록: 기본 앱으로 열어도 되는 형식
    @Test func opensSafeTypesWithDefaultApp() {
        for ext in ["swift", "md", "markdown", "txt", "json", "yaml", "yml", "xml", "plist", "csv", "c", "h", "java",
                    "png", "jpg", "gif", "heic", "pdf", "mp4", "mov", "mp3"] {
            #expect(FileOpener.classify(extension: ext) == .open, "\(ext)")
        }
    }

    /// 그 밖은 텍스트 편집기로: 스크립트, 브라우저가 스크립트를 돌리는 형식, 시스템이 다르게 아는 소스, 모르는 형식
    @Test func opensEverythingElseAsText() {
        let asText = [
            // 스크립트 (`.js` 는 형식이 실행 파일로도 등록돼 있지만 텍스트로 연다)
            "sh", "py", "rb", "js", "mjs", "ps1",
            // HTML · SVG · 웹 아카이브는 기본 앱(브라우저)이 안의 스크립트를 돌린다
            "html", "htm", "xhtml", "svg", "webarchive",
            // `.ts` 는 시스템이 MPEG-2 동영상으로 안다
            "ts", "mts", "cts",
            // 모르는 형식 · 확장자 없음 · 따로 열리는 앱이 있는 텍스트 형식
            "xyz", "tsx", "toml", "", "ics", "vcf", "zip",
        ]
        for ext in asText {
            #expect(FileOpener.classify(extension: ext) == .openAsText, "\(ext)")
        }
    }

    @Test func xmlSubtypesAreNotTrustedAsPlainXML() throws {
        // 구성 프로필 · JNLP 는 XML 을 따르지만 기본 앱이 설치 · 실행한다. 정확히 XML 일 때만 기본 앱으로
        let profile = try #require(UTType(filenameExtension: "configprofile"))
        #expect(profile.conforms(to: .xml))
        #expect(!FileOpener.isSafeToOpenWithDefaultApp(profile))
        let jnlp = try #require(UTType(filenameExtension: "jnlp"))
        #expect(!FileOpener.isSafeToOpenWithDefaultApp(jnlp))
        #expect(FileOpener.isSafeToOpenWithDefaultApp(.xml))
        // 단축어 파일은 속성 목록을 따른다
        let shortcut = try #require(UTType(filenameExtension: "wflow"))
        #expect(!FileOpener.isSafeToOpenWithDefaultApp(shortcut))
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
