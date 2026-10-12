// AgentNotch 앱 진입점: 메뉴바(액세서리) 앱으로 띄우고 AppDelegate 가 모듈을 조립한다.
import AppKit

let options = LaunchOptions(arguments: CommandLine.arguments)

if options.printVersion {
    print("agent-notch \(AppInfo.version)")
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    // NSApplication.delegate 는 약한 참조라 run() 이 끝날 때까지 여기서 붙잡아 둔다
    let delegate = AppDelegate(options: options)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    withExtendedLifetime(delegate) {}
}
