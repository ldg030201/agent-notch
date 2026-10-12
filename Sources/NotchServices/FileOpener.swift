import AppKit
import Darwin
import UniformTypeIdentifiers

/// 아일랜드에서 파일을 연다.
///
/// 파일은 Claude 가 만든 것일 수 있으므로, 열었을 때 실행될 수 있는 파일(앱, 실행 파일, `.command` 등)은
/// 열지 않고 Finder 에서 위치만 보여준다. 스크립트는 기본 텍스트 편집기로 연다.
@MainActor
public final class FileOpener {
    enum Disposition: Equatable {
        /// 기본 앱으로 열기
        case open
        /// 텍스트 편집기로 열기 (스크립트: 기본 앱이 실행기일 수 있음)
        case openAsText
        /// Finder 에서 보여주기만 (실행 위험)
        case reveal
        /// 열 수 없음 (없는 파일, 상대 경로, 깨진·순환 링크)
        case unavailable
    }

    /// 열면 실행되거나 시스템 설정을 바꿀 수 있는 확장자
    nonisolated static let riskyExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "workflow", "action", "scpt", "scptd", "applescript",
        "pkg", "mpkg", "dmg", "prefpane", "saver", "shortcut", "jar", "webloc", "inetloc", "fileloc",
        "url", "mobileconfig", "osax", "kext", "plugin", "bundle", "definition",
    ]

    /// 기본 앱이 실행기일 수 있는 스크립트 확장자
    nonisolated static let scriptExtensions: Set<String> = [
        "sh", "bash", "zsh", "fish", "csh", "ksh", "py", "pyw", "rb", "pl", "php", "lua", "tcl",
        "js", "mjs", "cjs", "ps1",
    ]

    private let workspace: NSWorkspace
    private let fileManager: FileManager

    public init(workspace: NSWorkspace = .shared, fileManager: FileManager = .default) {
        self.workspace = workspace
        self.fileManager = fileManager
    }

    /// `line` 은 아직 쓰지 않는다 (에디터별 줄 이동은 추후 지원)
    ///
    /// 판정과 열기 모두 심볼릭 링크를 끝까지 따라간 실제 파일 기준이다.
    /// (`notes.md -> x.terminal` 처럼 이름만 안전한 링크로 실행형 파일이 열리는 것을 막는다)
    @discardableResult
    public func open(path: String, line: Int?) -> Bool {
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
            guard let editor = workspace.urlForApplication(toOpen: .plainText) else {
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

        let ext = (path as NSString).pathExtension.lowercased()
        if riskyExtensions.contains(ext) { return .reveal }
        if let type = UTType(filenameExtension: ext) {
            let risky: [UTType] = [.application, .applicationBundle, .executable, .package, .bundle, .diskImage]
            if risky.contains(where: { type.conforms(to: $0) }) { return .reveal }
            if type.conforms(to: .script) { return .openAsText }
        }
        if scriptExtensions.contains(ext) { return .openAsText }
        return .open
    }
}
