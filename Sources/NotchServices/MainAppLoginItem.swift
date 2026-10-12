import ServiceManagement

/// 로그인 시 실행 (`SMAppService.mainApp`). 시스템 설정 > 로그인 항목과 항상 일치한다.
///
/// `/Applications` 에 복사한 .app 번들에서 실행할 때만 동작한다 (`swift run` 등 번들이 아니면 `isAvailable == false`).
/// `LoginItemManager`(LaunchAgent plist)와 동시에 켜면 두 번 실행되므로 둘 중 하나만 쓴다.
@MainActor
public final class MainAppLoginItem {
    public init() {}

    private var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    public var isEnabled: Bool {
        status == .enabled
    }

    /// 등록은 됐지만 사용자가 시스템 설정에서 허용해야 하는 상태
    public var requiresApproval: Bool {
        status == .requiresApproval
    }

    /// 앱 번들로 실행 중이라 로그인 항목을 등록할 수 있는지
    public var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard status == .enabled || status == .requiresApproval else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    /// 시스템 설정의 로그인 항목 화면 열기 (승인이 필요할 때)
    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
