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
    /// 패널 높이 (메뉴바 + 가장 큰 카드 + 여유). 패널은 화면 폭 전체를 덮고 크기를 애니메이션하지 않는다.
    static let panelHeight: CGFloat = 420

    let screenID: ScreenID
    /// 화면 전체 프레임 (Cocoa 전역 좌표, 원점 왼쪽 아래)
    let frame: CGRect
    let hasNotch: Bool
    /// 노치 크기 (노치 없는 화면이면 .zero)
    let notchSize: CGSize
    let isBuiltIn: Bool
    let menuBarHeight: CGFloat
    /// visibleFrame 이 메뉴바 자리를 빼고 있는지 (창 목록으로 메뉴바를 못 찾을 때의 대체 판단)
    let reportsMenuBar: Bool

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
            menuBarHeight: menuBar > 0 ? menuBar : (hasNotch ? topInset : 24),
            reportsMenuBar: menuBar > 0
        )
    }

    init(
        screenID: ScreenID,
        frame: CGRect,
        hasNotch: Bool,
        notchSize: CGSize,
        isBuiltIn: Bool,
        menuBarHeight: CGFloat,
        reportsMenuBar: Bool = true
    ) {
        self.screenID = screenID
        self.frame = frame
        self.hasNotch = hasNotch
        self.notchSize = notchSize
        self.isBuiltIn = isBuiltIn
        self.menuBarHeight = menuBarHeight
        self.reportsMenuBar = reportsMenuBar
    }

    /// 아일랜드 상단 행(날개) 높이. 노치 화면은 노치 높이, 아니면 알약 높이.
    var headerHeight: CGFloat {
        hasNotch ? max(notchSize.height, 24) : Self.pillHeaderHeight
    }

    /// 화면 맨 위에 화면 폭 전체로 붙인 패널 프레임
    var panelFrame: CGRect {
        let height = min(Self.panelHeight, frame.height)
        return CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    /// 패널 기준 사각형(원점 화면 왼쪽 위, y 아래로) → Cocoa 전역 좌표
    func screenRect(fromPanel rect: CGRect) -> CGRect {
        CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 하드웨어 노치 사각형 (Cocoa 전역, 노치 없으면 nil)
    var notchRect: CGRect? {
        guard hasNotch else { return nil }
        return CGRect(
            x: frame.minX + (frame.width - notchSize.width) / 2,
            y: frame.maxY - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
    }
}

extension NSScreen {
    /// `NSScreenNumber` 로부터 얻는 디스플레이 ID
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}
