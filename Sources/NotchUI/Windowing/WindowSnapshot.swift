import AppKit
import CoreGraphics
import os

/// 화면에 보이는 창 목록 한 번 조회 결과.
/// 화면 기록 권한 없이 읽히는 정보(경계 · 레이어 · PID)만 쓴다. 창 제목 · 앱 이름은 읽지 않는다.
struct WindowSnapshot: Sendable {
    struct Window: Sendable, Hashable {
        var number: Int
        var pid: Int
        var layer: Int
        /// Cocoa 전역 좌표 (원점 왼쪽 아래)
        var frame: CGRect
        var alpha: Double
    }

    var windows: [Window]

    /// CGWindowList 조회 (보통 1ms 미만). `primaryHeight` 는 주 화면 높이 (CG 좌표 → Cocoa 좌표 변환용).
    static func capture(primaryHeight: CGFloat) -> WindowSnapshot {
        // 창마다 Swift 사전으로 바꾸지 않고 NSDictionary 그대로 필요한 값만 읽는다
        // (`[[String: Any]]` 로 받으면 보통 수십~수백 개 창을 하나하나 새 사전으로 옮기는데, 0.25초마다 조회한다)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [NSDictionary]
        else { return WindowSnapshot(windows: []) }

        var windows: [Window] = []
        windows.reserveCapacity(list.count)
        for info in list {
            guard let layer = (info[kCGWindowLayer] as? NSNumber)?.intValue,
                  let boundsDict = info[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            windows.append(Window(
                number: (info[kCGWindowNumber] as? NSNumber)?.intValue ?? 0,
                pid: (info[kCGWindowOwnerPID] as? NSNumber)?.intValue ?? -1,
                layer: layer,
                frame: cocoaRect(fromGlobalTopLeft: bounds, primaryHeight: primaryHeight),
                alpha: (info[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1
            ))
        }
        return WindowSnapshot(windows: windows)
    }

    /// 다른 감시의 조회 결과를 이만큼(초) 안이면 같이 쓴다. 열린 메뉴 감시 주기(`OverlapMonitor`, 0.25초)보다 짧아야 한다:
    /// 그 감시는 같은 창을 연달아 두 번 봐야 겹침으로 인정하므로, 한 조회를 두 번 세면 안 된다
    static let shareWindow: TimeInterval = 0.2

    /// 방금 다른 감시가 조회한 결과(`shareWindow` 안)가 있으면 그걸 쓰고, 없으면 새로 조회해 남긴다.
    /// 열린 메뉴 감시(0.25초) · 메뉴바 측정(1초) · 풀스크린 확인(2초)이 같은 순간 따로 조회하지 않게 한다
    /// (앱을 바꿀 때마다 셋이 한꺼번에 조회하던 것도 하나로 준다)
    static func captureShared(primaryHeight: CGFloat) -> WindowSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = recent.withLock({ $0 }), cached.primaryHeight == primaryHeight, now - cached.at <= shareWindow {
            return cached.snapshot
        }
        let snapshot = capture(primaryHeight: primaryHeight)
        recent.withLock { $0 = (now, primaryHeight, snapshot) }
        return snapshot
    }

    /// 마지막 조회 결과 (조회는 메인 밖 여러 작업에서 하므로 잠금으로 지킨다)
    private static let recent = OSAllocatedUnfairLock<(at: TimeInterval, primaryHeight: CGFloat, snapshot: WindowSnapshot)?>(
        initialState: nil
    )

    /// CG 좌표(원점 왼쪽 위, 주 화면 기준) → Cocoa 전역 좌표
    static func cocoaRect(fromGlobalTopLeft rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// 이 로그인 세션의 화면을 지금 볼 수 없는지: 화면이 잠겼거나(잠금 화면 · 잠그는 화면 보호기) 다른 사용자로 전환됨.
/// 그동안엔 창 목록에서 우리 패널 · 메뉴바가 빠지므로, 패널이 사라졌다고 보거나 메뉴바 빈 공간 · 열린 메뉴를 재지 않는다.
/// 잠금 키(`CGSSessionScreenIsLocked`)는 문서에 없는 값이라, 없으면 잠기지 않은 것으로 본다
enum SessionScreen {
    static var isUnavailable: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let onConsole = info[kCGSessionOnConsoleKey] as? Bool, !onConsole { return true }
        return info["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

/// 창 레벨 상수 (CGWindowLevelForKey 값)
enum WindowLevels {
    static let mainMenu = Int(CGWindowLevelForKey(.mainMenuWindow))
    static let status = Int(CGWindowLevelForKey(.statusWindow))
    static let popUpMenu = Int(CGWindowLevelForKey(.popUpMenuWindow))
    /// 커서 등 시스템 최상위 창은 제외 (이 값 이상)
    static let systemTop = Int(CGWindowLevelForKey(.cursorWindow)) - 64
}
