import Foundation

/// 번들 정보와 실행 파일 경로
enum AppInfo {
    /// 번들 밖(`swift run`)에서 실행할 때 쓰는 버전
    static let developmentVersion = "0.1.0-dev"

    /// 첫 실행 때 훅 설치를 한 번 제안했는지 (UserDefaults 키)
    static let didOfferHookInstallKey = "didOfferHookInstall"

    static var version: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let value, !value.isEmpty, !value.hasPrefix("__") else { return developmentVersion }
        return value
    }

    /// 앱과 함께 빌드된 훅 헬퍼 (`Contents/MacOS/notch-hook`, 번들 밖이면 실행 파일 옆)
    static func helperURL(fileManager: FileManager = .default) -> URL? {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "notch-hook"), fileManager.isExecutableFile(atPath: url.path) {
            return url
        }
        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath()
        let sibling = executable.deletingLastPathComponent().appendingPathComponent("notch-hook")
        return fileManager.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    /// 로그인 시 실행에 등록할 실행 파일 경로.
    /// Homebrew Cellar 경로(`…/Cellar/agent-notch/0.1.0/…`)는 업그레이드하면 바뀌므로 `…/opt/agent-notch/…` 로 바꾼다.
    static func stableExecutablePath(fileManager: FileManager = .default) -> String {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let marker = "/Cellar/agent-notch/"
        guard let range = path.range(of: marker) else { return path }
        let rest = path[range.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return path }
        let candidate = String(path[..<range.lowerBound]) + "/opt/agent-notch" + String(rest[slash...])
        return fileManager.isExecutableFile(atPath: candidate) ? candidate : path
    }
}

/// 명령줄 인자 (`open AgentNotch.app --args --demo`)
struct LaunchOptions {
    /// `--render-island <장면|all> <폴더> [--style notch|menubar|both]`
    struct RenderIsland: Equatable {
        var scenario: String
        var outputDirectory: String
        var style = "notch"
    }

    var demo = false
    var printVersion = false
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
        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "--demo": demo = true
            case "--version", "-v": printVersion = true
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
