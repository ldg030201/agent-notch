import Foundation
import NotchServices
import NotchShared

/// 명령줄에서 훅을 설치 · 제거 · 확인한다 (`agent-notch --install-hooks [--codex]` 등).
/// 메뉴바의 "Claude Code 훅 설치" · "Codex 훅 설치" 와 같은 HookInstaller 를 쓰므로 결과가 같다.
enum HookCommand {
    enum Action: Equatable {
        case install(includeMessageDisplay: Bool)
        case uninstall
        case status
    }

    /// 종료 코드를 돌려준다 (0 성공, 1 실패). `agent` 는 설치 · 제거 대상 (상태는 모두 보여준다)
    static func run(_ action: Action, agent: AgentKind = .claude) -> Int32 {
        let installer = HookInstaller(agent: agent)
        let name = agent.displayName
        do {
            switch action {
            case .install(let includeMessageDisplay):
                guard let helper = AppInfo.helperURL() else {
                    printToStandardError("notch-hook 헬퍼를 찾지 못했어요. scripts/build.sh 로 만든 앱에서 실행해 주세요.")
                    return 1
                }
                let backup = try installer.install(helperSource: helper, includeMessageDisplay: includeMessageDisplay)
                print("\(name) 훅 설치: \(installer.status()) (\(installer.settingsURL.path))")
                if let backup { print("설정 백업: \(backup.path)") }
                if agent == .codex {
                    print("Codex 에 새 훅 검토가 뜨면 한 번 허용해 주세요 (CLI 는 /hooks). 허용한 뒤 새로 시작하는 Codex 세션부터 노치에 표시돼요.")
                } else {
                    print("새로 시작하는 Claude Code 세션부터 노치에 표시돼요.")
                }
            case .uninstall:
                let backup = try installer.uninstall()
                print("\(name) 훅 제거: \(installer.status())")
                if let backup { print("설정 백업: \(backup.path)") }
            case .status:
                for kind in AgentKind.allCases {
                    let installer = HookInstaller(agent: kind)
                    print("\(kind.displayName) 훅 상태: \(installer.status()) (\(installer.settingsURL.path))")
                    let events = installer.installedEvents().sorted()
                    if !events.isEmpty { print("  설치된 이벤트: \(events.joined(separator: ", "))") }
                }
            }
            return 0
        } catch {
            printToStandardError("실패: \(error.localizedDescription)")
            return 1
        }
    }
}
