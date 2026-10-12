/// 명령줄 인자 (`open AgentNotch.app --args --demo`, `agent-notch --version`)
///
/// | 인자 | 하는 일 |
/// |---|---|
/// | `--version`, `-v` | `agent-notch <버전>` 출력 후 종료 |
/// | `--dump-changelog [경로]` | 변경 내역 JSON 출력 (경로가 없으면 stdout) |
/// | `--render-island <장면\|all> <폴더> [--style notch\|menubar\|both]` | 아일랜드 장면을 PNG 로 저장 |
/// | `--probe-upgrade` | brew 위치와 업데이트 스크립트 문법 점검 (실행하지 않음) |
/// | `--demo` | 데모 시나리오로 시작 |
struct LaunchOptions {
    /// `--render-island <장면|all> <폴더> [--style notch|menubar|both]`
    struct RenderIsland: Equatable {
        var scenario: String
        var outputDirectory: String
        var style = "notch"
    }

    /// `--dump-changelog [경로]`
    struct DumpChangelog: Equatable {
        /// nil 이면 stdout
        var path: String?
    }

    var demo = false
    var printVersion = false
    var probeUpgrade = false
    var dumpChangelog: DumpChangelog?
    var renderIsland: RenderIsland?
    /// 인자 형식 오류 (값이 빠진 경우 등)
    var usageError: String?

    init(arguments: [String]) {
        var style: String?
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
            case "--version", "-v": printVersion = true
            case "--probe-upgrade": probeUpgrade = true
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
            default: break  // -NSDocumentRevisionsDebugMode 같은 시스템 인자는 무시
            }
            index = arguments.index(after: index)
        }
        if let style { renderIsland?.style = style }
    }
}
