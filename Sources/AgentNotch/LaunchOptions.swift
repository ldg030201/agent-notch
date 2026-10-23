import NotchShared

/// 명령줄 인자 (`open AgentNotch.app --args --demo`, `agent-notch --version`)
///
/// | 인자 | 하는 일 |
/// |---|---|
/// | `--help`, `-h` | 이 사용법 출력 후 종료 |
/// | `--version`, `-v` | `agent-notch <버전>` 출력 후 종료 |
/// | `--dump-changelog [경로]` | 변경 내역 JSON 출력 (경로가 없으면 stdout) |
/// | `--render-island <장면\|all> <폴더> [--style notch\|menubar\|both] [--crop]` | 아일랜드 장면을 PNG 로 저장 (`--crop`: 아일랜드 둘레만, README 용) |
/// | `--probe-upgrade` | brew 위치와 업데이트 스크립트 문법 점검 (실행하지 않음) |
/// | `--install-hooks [--codex] [--no-message-display]` | Claude Code 훅 설치 (settings.json 백업 후 AgentNotch 항목만 추가). `--codex` 면 Codex 훅 (~/.codex/hooks.json) |
/// | `--uninstall-hooks [--codex]` | AgentNotch 훅만 제거 |
/// | `--hook-status` | 훅 설치 상태 출력 (Claude Code · Codex) |
/// | `--demo` | 데모 시나리오로 시작 |
/// | `--dock` | (개발용) Dock 아이콘을 보이게 띄움 — 화면 캡처 도구가 앱으로 인식하게 |
struct LaunchOptions {
    /// `--render-island <장면|all> <폴더> [--style notch|menubar|both] [--crop]`
    struct RenderIsland: Equatable {
        var scenario: String
        var outputDirectory: String
        var style = "notch"
        /// 아일랜드 둘레만 잘라 저장 (README 스크린샷)
        var crop = false
    }

    /// `--dump-changelog [경로]`
    struct DumpChangelog: Equatable {
        /// nil 이면 stdout
        var path: String?
    }

    var demo = false
    /// 개발용: Dock 아이콘을 보이게 (일반 앱으로) 띄운다
    var showInDock = false
    var printVersion = false
    var printHelp = false
    var probeUpgrade = false
    var dumpChangelog: DumpChangelog?
    var renderIsland: RenderIsland?
    var hookAction: HookCommand.Action?
    /// 훅 설치 · 제거 대상 (`--codex` 면 Codex, 아니면 Claude Code)
    var hookAgent: AgentKind = .claude
    /// 인자 형식 오류 (값이 빠진 경우 등)
    var usageError: String?

    init(arguments: [String]) {
        var style: String?
        var crop = false
        var includeMessageDisplay = true
        var index = arguments.index(after: arguments.startIndex)
        // 값을 하나 받는 인자: 다음 인자를 꺼내고, 없으면 nil
        func nextValue() -> String? {
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else { return nil }
            index = next
            return arguments[next]
        }
        // 값이 있어도 되고 없어도 되는 인자: 다음 인자가 옵션(-로 시작)이 아니면 꺼낸다
        func optionalValue() -> String? {
            let next = arguments.index(after: index)
            guard next < arguments.endIndex, !arguments[next].hasPrefix("-") else { return nil }
            index = next
            return arguments[next]
        }
        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "--demo": demo = true
            case "--dock": showInDock = true
            case "--version", "-v": printVersion = true
            case "--help", "-h": printHelp = true
            case "--probe-upgrade": probeUpgrade = true
            case "--install-hooks": hookAction = .install(includeMessageDisplay: true)
            case "--no-message-display": includeMessageDisplay = false
            case "--uninstall-hooks": hookAction = .uninstall
            case "--codex": hookAgent = .codex
            case "--hook-status": hookAction = .status
            case "--dump-changelog":
                dumpChangelog = DumpChangelog(path: optionalValue())
            case "--render-island":
                guard let scenario = nextValue(), let directory = nextValue() else {
                    usageError = "사용법: --render-island <장면|all> <폴더> [--style notch|menubar|both]"
                    break
                }
                renderIsland = RenderIsland(scenario: scenario, outputDirectory: directory)
            case "--style":
                guard let value = nextValue() else {
                    usageError = "--style 값이 필요해요 (notch|menubar|both)"
                    break
                }
                style = value
            case "--crop": crop = true
            default: break  // -NSDocumentRevisionsDebugMode 같은 시스템 인자는 무시
            }
            index = arguments.index(after: index)
        }
        if let style { renderIsland?.style = style }
        if crop { renderIsland?.crop = true }
        // 모르는 `--` 인자를 앱 실행으로 넘기지 않는다 (오타가 앱을 하나 더 띄워 "이미 실행 중" 창을 내지 않게).
        // `-NSDocumentRevisionsDebugMode` 처럼 시스템이 붙이는 인자는 대시가 하나라 그대로 둔다
        if usageError == nil, let unknown = arguments.dropFirst().first(where: { $0.hasPrefix("--") && !Self.knownFlags.contains($0) }) {
            usageError = "모르는 인자: \(unknown)\n\(Self.usage)"
        }
        if case .install = hookAction { hookAction = .install(includeMessageDisplay: includeMessageDisplay) }
    }

    static let knownFlags: Set<String> = [
        "--demo", "--dock", "--version", "--help", "--probe-upgrade", "--install-hooks", "--no-message-display", "--codex",
        "--uninstall-hooks", "--hook-status", "--dump-changelog", "--render-island", "--style", "--crop",
    ]

    static let usage = """
        사용법: agent-notch [인자]
          (인자 없음)                         메뉴바 앱으로 실행
          --demo                              데모 시나리오로 실행
          --version, -v                       버전 출력
          --help, -h                          이 사용법 출력
          --install-hooks [--no-message-display]  Claude Code 훅 설치 (settings.json 백업 후 AgentNotch 항목만)
          --install-hooks --codex             Codex 훅 설치 (~/.codex/hooks.json 백업 후 AgentNotch 항목만)
          --uninstall-hooks [--codex]         AgentNotch 훅만 제거
          --hook-status                       훅 설치 상태 출력 (Claude Code · Codex)
          --dump-changelog [경로]             변경 내역 JSON 출력
          --render-island <장면|all> <폴더> [--style notch|menubar|both] [--crop]  아일랜드 장면 PNG 저장 (--crop: 아일랜드 둘레만)
          --probe-upgrade                     brew 위치 · 업데이트 스크립트 문법 점검 (실행 안 함)
        """
}
