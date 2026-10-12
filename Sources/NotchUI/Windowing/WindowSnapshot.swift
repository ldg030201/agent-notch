import AppKit
import CoreGraphics

/// 화면에 보이는 창 목록 한 번 조회 결과.
/// 화면 기록 권한 없이 읽히는 정보(경계 · 레이어 · PID · 소유 앱 이름)만 쓴다. 창 제목은 읽지 않는다.
struct WindowSnapshot: Sendable {
    struct Window: Sendable, Hashable {
        var number: Int
        var pid: Int
        var layer: Int
        /// Cocoa 전역 좌표 (원점 왼쪽 아래)
        var frame: CGRect
        var alpha: Double
        var ownerName: String?
    }

    var windows: [Window]

    /// CGWindowList 조회 (보통 1ms 미만). `primaryHeight` 는 주 화면 높이 (CG 좌표 → Cocoa 좌표 변환용).
    static func capture(primaryHeight: CGFloat) -> WindowSnapshot {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return WindowSnapshot(windows: []) }

        var windows: [Window] = []
        windows.reserveCapacity(list.count)
        for info in list {
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            windows.append(Window(
                number: (info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0,
                pid: (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1,
                layer: layer,
                frame: CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height),
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                ownerName: info[kCGWindowOwnerName as String] as? String
            ))
        }
        return WindowSnapshot(windows: windows)
    }

    /// CG 좌표(원점 왼쪽 위, 주 화면 기준) → Cocoa 전역 좌표
    static func cocoaRect(fromGlobalTopLeft rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
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
