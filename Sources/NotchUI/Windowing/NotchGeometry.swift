import AppKit
import CoreGraphics

/// 화면 식별자 (CGDirectDisplayID). 연결이 유지되는 동안 안정적이다.
typealias ScreenID = CGDirectDisplayID

/// 화면 하나에 대한 노치/메뉴바 기하 정보
struct NotchGeometry: Equatable {
    /// 노치 크기를 알 수 없을 때 쓰는 기본값 (14"/16" 맥북 프로 기준 근사치)
    static let fallbackNotchSize = CGSize(width: 185, height: 32)
    /// 노치 없는 화면에서 알약 상단 행 높이
    static let pillHeaderHeight: CGFloat = 32
    /// 메뉴바와 알약 사이 간격
    static let pillTopGap: CGFloat = 6
    /// 패널 고정 크기 (아일랜드 최대 크기 + 여유). 창 크기는 애니메이션하지 않는다.
    static let panelWidth: CGFloat = 680
    static let maxIslandHeight: CGFloat = 320

    let screenID: ScreenID
    /// 화면 전체 프레임 (Cocoa 전역 좌표, 원점 왼쪽 아래)
    let frame: CGRect
    let hasNotch: Bool
    /// 노치 크기 (노치 없는 화면이면 .zero)
    let notchSize: CGSize
    let isBuiltIn: Bool
    let menuBarHeight: CGFloat

    @MainActor
    init(screen: NSScreen) {
        let id = screen.displayID
        let frame = screen.frame
        let topInset = screen.safeAreaInsets.top
        let hasNotch = topInset > 0

        var notchSize = CGSize.zero
        if hasNotch {
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                let width = frame.width - left.width - right.width
                notchSize = CGSize(
                    width: width > 0 ? width : Self.fallbackNotchSize.width,
                    height: topInset
                )
            } else {
                notchSize = CGSize(width: Self.fallbackNotchSize.width, height: topInset)
            }
        }

        let menuBar = frame.maxY - screen.visibleFrame.maxY

        self.init(
            screenID: id,
            frame: frame,
            hasNotch: hasNotch,
            notchSize: notchSize,
            isBuiltIn: CGDisplayIsBuiltin(id) != 0,
            menuBarHeight: menuBar > 0 ? menuBar : 24
        )
    }

    init(screenID: ScreenID, frame: CGRect, hasNotch: Bool, notchSize: CGSize, isBuiltIn: Bool, menuBarHeight: CGFloat) {
        self.screenID = screenID
        self.frame = frame
        self.hasNotch = hasNotch
        self.notchSize = notchSize
        self.isBuiltIn = isBuiltIn
        self.menuBarHeight = menuBarHeight
    }

    /// 아일랜드 상단 행(날개) 높이. 노치 화면은 노치 높이, 아니면 알약 높이.
    var headerHeight: CGFloat {
        hasNotch ? max(notchSize.height, 24) : Self.pillHeaderHeight
    }

    /// 패널 상단에서 아일랜드 상단까지의 거리. 노치 화면은 화면 맨 위에 붙는다.
    var islandTopInset: CGFloat {
        hasNotch ? 0 : menuBarHeight + Self.pillTopGap
    }

    /// 화면 상단 가운데에 고정된 패널 프레임
    var panelFrame: CGRect {
        let width = min(Self.panelWidth, frame.width)
        let height = min(islandTopInset + Self.maxIslandHeight, frame.height)
        return CGRect(
            x: (frame.midX - width / 2).rounded(),
            y: frame.maxY - height,
            width: width,
            height: height
        )
    }

    /// 주어진 아일랜드 크기(귀 포함)의 화면 좌표 사각형
    func islandRect(size: CGSize) -> CGRect {
        let top = frame.maxY - islandTopInset
        return CGRect(x: frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }
}

extension NSScreen {
    /// `NSScreenNumber` 로부터 얻는 디스플레이 ID
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}
