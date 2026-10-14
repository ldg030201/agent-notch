import Foundation
import NotchServices

/// 번들 정보와 실행 파일 경로
enum AppInfo {
    /// 첫 실행 안내(훅 설치 · 로그인 시 실행)를 한 번 보여줬는지 (UserDefaults 키. 예전 이름 그대로 두어 이미 본 사람에게 다시 묻지 않는다)
    static let didOfferHookInstallKey = "didOfferHookInstall"

    /// 실행 중인 버전. 번들 밖(`swift run`)에서는 소스의 `agentNotchVersion`.
    static var version: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let value, !value.isEmpty else { return agentNotchVersion }
        return value
    }

    /// 테스트판(`VARIANT=test`, 번들 ID `…-test`)인지. 새 버전 확인 · 자체 업데이트를 하지 않는다.
    static let isTestBuild = BuildVariant.isTest(bundleIdentifier: Bundle.main.bundleIdentifier)

    /// 설정 화면 표기. 테스트판은 정식판 번호처럼 읽히지 않게 표시를 붙인다.
    static var displayVersion: String {
        isTestBuild ? "\(version) (테스트판)" : version
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
}
