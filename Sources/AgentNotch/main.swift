// AgentNotch 앱 진입점: 명령줄 도구 인자를 먼저 처리하고, 아니면 메뉴바(액세서리) 앱으로 띄운다.
// 인자 목록은 LaunchOptions 참고.
import AppKit
import NotchServices

let options = LaunchOptions(arguments: CommandLine.arguments)

func printToStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

if options.printVersion {
    print("agent-notch \(AppInfo.version)")
    exit(0)
}

if let message = options.usageError {
    printToStandardError(message)
    exit(64)
}

// 변경 내역 JSON: agent-notch --dump-changelog [경로]
// docs/changelog.json 은 이걸로만 만든다 (`source scripts/lib.sh && dump_changelog`).
if let dump = options.dumpChangelog {
    do {
        let data = try Changelog.jsonData()
        if let path = dump.path {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            print(path)
        } else {
            FileHandle.standardOutput.write(data)
        }
        exit(0)
    } catch {
        printToStandardError("변경 내역을 쓰지 못했어요: \(error.localizedDescription)")
        exit(1)
    }
}

// 업데이트 점검: brew 위치와 두 스크립트의 문법만 본다 (실행하지 않음)
if options.probeUpgrade {
    exit(Upgrader.probe() ? 0 : 1)
}

// 훅 관리: agent-notch --install-hooks | --uninstall-hooks | --hook-status
if let action = options.hookAction {
    exit(HookCommand.run(action))
}

if let request = options.renderIsland {
    exit(MainActor.assumeIsolated { RenderIslandCommand.run(request) })
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    // NSApplication.delegate 는 약한 참조라 run() 이 끝날 때까지 여기서 붙잡아 둔다
    let delegate = AppDelegate(options: options)
    app.delegate = delegate
    // 메뉴바 앱(Dock 아이콘 없음). --dock 이면 개발 중 화면 캡처 도구가 인식하도록 일반 앱으로
    app.setActivationPolicy(options.showInDock ? .regular : .accessory)
    app.run()
    withExtendedLifetime(delegate) {}
}
