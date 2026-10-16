import AppKit
import Darwin
import UniformTypeIdentifiers

/// 아일랜드에서 파일을 연다.
///
/// 파일은 Claude 가 만든 것일 수 있다(프롬프트 주입 등). 그래서 **허용 목록** 으로 판정한다:
/// - 실행될 수 있는 파일(실행 비트, 앱 · `.command` · `.term` · 구성 프로필 등)은 열지 않고 Finder 에서 위치만 보여준다.
/// - 기본 앱으로 열어도 안전한 형식(텍스트 · 소스 코드 · JSON · YAML · XML · 이미지 · PDF · 오디오/비디오)만 기본 앱으로 연다.
/// - 그 밖의 모든 것(스크립트, HTML · SVG 처럼 브라우저가 스크립트를 돌리는 형식, 모르는 형식)은 텍스트 편집기로 연다.
@MainActor
public final class FileOpener {
    enum Disposition: Equatable {
        /// 기본 앱으로 열기
        case open
        /// 텍스트 편집기로 열기 (스크립트 · 모르는 형식: 기본 앱이 실행기일 수 있음)
        case openAsText
        /// Finder 에서 보여주기만 (실행 위험)
        case reveal
        /// 열 수 없음 (없는 파일, 상대 경로, 깨진·순환 링크)
        case unavailable
    }

    /// 열면 실행되거나 시스템 설정을 바꾸거나 다른 곳에 접속하는 확장자 (형식 판정보다 먼저 본다).
    /// 대부분 형식이 `public.data` 뿐이라 허용 목록에도 안 걸리지만, 텍스트 편집기로 열 일도 없어 위치만 보여준다.
    nonisolated static let riskyExtensions: Set<String> = [
        // 앱 · 실행 파일 · 스크립트 실행기 (Terminal 은 .term · .terminal 의 실행 명령을 그대로 돌린다)
        "app", "command", "tool", "terminal", "term", "workflow", "wflow", "action", "scpt", "scptd", "applescript",
        "jar", "jnlp", "shortcut",
        // 설치 · 시스템 설정 (구성 · 프로비저닝 프로필은 XML 형식이라 아래 허용 목록보다 먼저 막는다)
        "pkg", "mpkg", "dmg", "prefpane", "saver", "osax", "kext", "plugin", "bundle", "definition",
        "mobileconfig", "configprofile", "provisionprofile", "mobileprovision",
        // 열면 다른 곳에 접속 · 마운트하는 위치 파일
        "webloc", "inetloc", "fileloc", "url", "vncloc", "afploc", "ftploc", "smbloc", "webbookmark",
    ]

    /// 기본 앱이 실행기일 수 있는 스크립트 확장자 (형식이 스크립트로 등록되지 않은 것까지)
    nonisolated static let scriptExtensions: Set<String> = [
        "sh", "bash", "zsh", "fish", "csh", "ksh", "py", "pyw", "rb", "pl", "php", "lua", "tcl",
        "js", "mjs", "cjs", "ps1",
    ]

    /// 소스 코드인데 시스템이 다른 형식으로 아는 확장자 (`.ts` 는 MPEG-2 동영상으로 등록돼 있다)
    nonisolated static let misidentifiedSourceExtensions: Set<String> = ["ts", "mts", "cts"]

    /// 브라우저 등이 열면 안의 스크립트를 돌리는 형식. 기본 앱 대신 텍스트로 연다
    nonisolated static let textOnlyTypes: [UTType] = [.html, .svg, .webArchive]

    private let workspace: NSWorkspace
    private let fileManager: FileManager

    public init(workspace: NSWorkspace = .shared, fileManager: FileManager = .default) {
        self.workspace = workspace
        self.fileManager = fileManager
    }

    /// 판정과 열기 모두 심볼릭 링크를 끝까지 따라간 실제 파일 기준이다.
    /// (`notes.md -> x.terminal` 처럼 이름만 안전한 링크로 실행형 파일이 열리는 것을 막는다)
    @discardableResult
    public func open(path: String) -> Bool {
        // 한 번만 해석해 판정과 열기에 같은 경로를 쓴다 (링크를 다시 따라가지 않음)
        guard let target = Self.resolvedTarget(for: path) else { return false }
        let url = URL(fileURLWithPath: target)
        switch Self.classify(resolvedPath: target, fileManager: fileManager) {
        case .unavailable:
            return false
        case .reveal:
            workspace.activateFileViewerSelecting([url])
            return true
        case .openAsText:
            // 이 파일의 기본 앱이 알려진 코드 편집기면 그 앱으로 (VS Code 등 사용자가 정한 연결 유지, 편집기는 실행하지 않는다).
            // 아니면 텍스트 편집기로
            let defaultApp = workspace.urlForApplication(toOpen: url)
            let editor = defaultApp.flatMap { app in
                Bundle(url: app)?.bundleIdentifier.flatMap { Self.isKnownEditor(bundleIdentifier: $0) ? app : nil }
            } ?? workspace.urlForApplication(toOpen: .plainText)
            guard let editor else {
                workspace.activateFileViewerSelecting([url])
                return true
            }
            workspace.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            return true
        case .open:
            return workspace.open(url)
        }
    }

    nonisolated static func disposition(for path: String, fileManager: FileManager = .default) -> Disposition {
        guard let target = resolvedTarget(for: path) else { return .unavailable }
        return classify(resolvedPath: target, fileManager: fileManager)
    }

    /// 심볼릭 링크를 모두 해석한 실제 절대 경로. 상대 경로·없는 파일·깨진(순환) 링크면 nil.
    nonisolated static func resolvedTarget(for path: String) -> String? {
        guard path.hasPrefix("/"), let raw = realpath(path, nil) else { return nil }
        defer { free(raw) }
        return String(cString: raw)
    }

    /// 해석이 끝난 실제 경로로 처리 방식을 정한다
    private nonisolated static func classify(resolvedPath path: String, fileManager: FileManager) -> Disposition {
        var info = stat()
        // lstat: 해석 직후 링크로 바뀌었다면(경쟁) 따라가지 않는다
        guard lstat(path, &info) == 0 else { return .unavailable }
        // 폴더·패키지(.app 등), 링크, 장치·FIFO 등 일반 파일이 아니면 보여주기만
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .reveal }
        // 실행 비트가 하나라도 있거나 ACL 등으로 실행 가능하면 보여주기만
        if (info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0 || fileManager.isExecutableFile(atPath: path) {
            return .reveal
        }
        return classify(extension: (path as NSString).pathExtension)
    }

    /// 확장자만으로 정하는 처리 방식 (일반 파일 · 실행 비트 없음을 확인한 뒤)
    nonisolated static func classify(extension rawExtension: String) -> Disposition {
        let ext = rawExtension.lowercased()
        if riskyExtensions.contains(ext) { return .reveal }
        // 스크립트는 기본 앱이 실행기일 수 있어 텍스트로 연다 (형식이 실행 파일로도 등록된 `.js` 포함)
        if scriptExtensions.contains(ext) || misidentifiedSourceExtensions.contains(ext) { return .openAsText }
        // 확장자가 없거나 시스템이 모르는 형식(동적 형식)은 기본 앱이 무엇일지 몰라 텍스트로
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic else { return .openAsText }

        if type.conforms(to: .script) { return .openAsText }
        let risky: [UTType] = [.application, .applicationBundle, .executable, .package, .bundle, .diskImage]
        if risky.contains(where: { type.conforms(to: $0) }) { return .reveal }
        if textOnlyTypes.contains(where: { type.conforms(to: $0) }) { return .openAsText }
        return isSafeToOpenWithDefaultApp(type) ? .open : .openAsText
    }

    /// 파일을 실행하지 않고 편집만 하는 코드 편집기 · IDE (텍스트로 열 파일의 기본 앱이 이 중 하나면 그 앱으로 연다)
    nonisolated static let knownEditorBundleIDs: Set<String> = [
        "com.apple.TextEdit", "com.apple.dt.Xcode",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf", "dev.zed.Zed", "dev.zed.Zed-Preview",
        "com.sublimetext.4", "com.sublimetext.3", "com.panic.Nova", "com.barebones.bbedit",
        "com.coteditor.CotEditor", "com.macromates.TextMate", "org.vim.MacVim", "org.gnu.Emacs",
    ]
    /// JetBrains IDE 는 제품마다 번들 ID 가 달라 접두사로 본다 (IntelliJ IDEA, PyCharm, WebStorm, GoLand, Fleet 등)
    nonisolated static let knownEditorBundlePrefixes = ["com.jetbrains."]

    nonisolated static func isKnownEditor(bundleIdentifier: String) -> Bool {
        knownEditorBundleIDs.contains(bundleIdentifier)
            || knownEditorBundlePrefixes.contains { bundleIdentifier.hasPrefix($0) }
    }

    /// 기본 앱으로 열어도 안전한 형식인지 (허용 목록).
    ///
    /// XML · 속성 목록은 **정확히 그 형식** 일 때만 허용한다. 구성 프로필(`.mobileconfig`) · Java Web Start(`.jnlp`) ·
    /// 단축어(`.wflow`)처럼 XML · 속성 목록을 따르는 하위 형식은 기본 앱이 설치 · 실행을 하기 때문이다.
    /// 일반 텍스트를 따르는 형식은 스크립트를 앞에서 걸렀으므로 편집기 · 뷰어가 연다 (소스 코드, Markdown, CSV, 로그 등).
    nonisolated static func isSafeToOpenWithDefaultApp(_ type: UTType) -> Bool {
        if type == .xml || type == .propertyList { return true }
        let safe: [UTType] = [.plainText, .json, .yaml, .image, .pdf, .audiovisualContent]
        return safe.contains { type.conforms(to: $0) }
    }
}
