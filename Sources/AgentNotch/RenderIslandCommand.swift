// `--render-island`: 아일랜드 장면을 PNG 로 저장하고 끝낸다 (NSApplication 실행 없이, 가짜 데이터만 사용).
import Foundation
import NotchUI

enum RenderIslandCommand {
    /// 종료 코드: 0 성공, 1 렌더링 실패, 64 인자 오류
    @MainActor
    static func run(_ request: LaunchOptions.RenderIsland) -> Int32 {
        let styles: [IslandSnapshotRenderer.Style]
        switch request.style.lowercased() {
        case "notch": styles = [.notch]
        case "menubar": styles = [.menuBar]
        case "both": styles = IslandSnapshotRenderer.Style.allCases
        default:
            printError("알 수 없는 스타일: \(request.style) (notch|menubar|both)")
            return 64
        }

        let available = IslandSnapshotRenderer.scenarios
        let names = request.scenario == "all" ? available : [request.scenario]
        guard names.allSatisfy(available.contains) else {
            printError("알 수 없는 장면: \(request.scenario)\n가능한 장면: all, \(available.joined(separator: ", "))")
            return 64
        }

        let directory = URL(fileURLWithPath: request.outputDirectory, isDirectory: true)
        var failed = false
        for name in names {
            for style in styles {
                // 파일 이름: <장면>-<notch|menubar>.png
                let url = directory.appendingPathComponent("\(name)-\(style.rawValue.lowercased()).png")
                do {
                    try IslandSnapshotRenderer.renderPNG(scenario: name, style: style, to: url)
                    print(url.path)
                } catch {
                    printError("\(name) (\(style.rawValue)): \(error.localizedDescription)")
                    failed = true
                }
            }
        }
        return failed ? 1 : 0
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
