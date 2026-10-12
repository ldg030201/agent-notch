import AppKit
import SwiftUI

/// 노치 위에 떠 있는 투명 패널.
///
/// - 활성화하지 않는 패널이라 알림이 와도 다른 앱의 키보드 포커스를 뺏지 않는다.
/// - 아일랜드가 펼쳐졌거나 권한 요청을 보여줄 때만 키 윈도우가 될 수 있다 (클릭 후 단축키용).
/// - 창 크기는 고정. 아일랜드 크기 변화는 SwiftUI 내용에서 애니메이션한다.
final class NotchPanel: NSPanel {
    /// 메뉴바(.statusBar) 위, 팝업 메뉴/경고창 아래
    static let islandLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)

    /// 지금 키 윈도우가 될 수 있는지 (표시 모드에 따라 동적으로 결정)
    var allowsKey: @MainActor () -> Bool = { false }

    convenience init(frame: CGRect) {
        self.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure()
    }

    private func configure() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = Self.islandLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        // 처음엔 클릭 통과. 마우스가 아일랜드 위에 올라오면 ScreenManager 가 끈다.
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { allowsKey() }
    override var canBecomeMain: Bool { false }

    /// 메뉴바 영역에도 놓일 수 있게 화면 제약을 끈다.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// 처리하지 않은 키 입력에 경고음을 내지 않는다.
    override func noResponder(for eventSelector: Selector) {}
}

/// 키 반납용 보이지 않는 패널 (1×1, 투명, 클릭 통과).
/// 키 윈도우였던 아일랜드 패널을 내렸다 다시 올리면(orderOut → orderFront) 그 사이 한 프레임 아일랜드가 비어 보일 수 있어서,
/// 이 패널을 잠깐 키 윈도우로 만든 뒤 내려 키보드 포커스를 원래 앱으로 돌려준다.
final class KeyReleasePanel: NSPanel {
    convenience init() {
        self.init(
            contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NotchPanel.islandLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func noResponder(for eventSelector: Selector) {}
}

/// 첫 클릭부터 바로 SwiftUI 로 전달되는 호스팅 뷰.
/// 비활성 앱에서도 마우스 이동 이벤트를 받도록 항상 활성 트래킹 영역을 둔다.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    private var moveTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let moveTrackingArea { removeTrackingArea(moveTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        moveTrackingArea = area
    }
}
