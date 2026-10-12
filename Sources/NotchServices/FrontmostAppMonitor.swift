import AppKit
import NotchCore
import Observation

/// 지금 맨 앞에 있는 앱을 추적한다.
/// (세션 터미널이 이미 앞에 있으면 권한 요청을 터미널로 넘기는 데 사용)
@MainActor
@Observable
public final class FrontmostAppMonitor {
    /// 맨 앞 앱의 번들 ID
    public internal(set) var frontmostBundleID: String?

    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?

    public init(workspace: NSWorkspace = .shared) {
        notificationCenter = workspace.notificationCenter
        frontmostBundleID = workspace.frontmostApplication?.bundleIdentifier
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                self?.frontmostBundleID = bundleID
            }
        }
    }

    deinit {
        if let observer { notificationCenter.removeObserver(observer) }
    }

    /// 세션을 실행한 터미널/앱이 맨 앞에 있는지
    public func isFrontmost(_ context: TerminalContext) -> Bool {
        guard let frontmost = frontmostBundleID,
              let target = TerminalJumper.resolveBundleIdentifier(for: context) else { return false }
        return frontmost.caseInsensitiveCompare(target) == .orderedSame
    }
}
