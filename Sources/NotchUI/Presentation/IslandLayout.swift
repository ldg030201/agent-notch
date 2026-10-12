import AppKit
import NotchCore

// MARK: - 레이아웃 결과

/// 접힌 상태 표시 방식 (뷰가 그대로 따라 그린다)
enum CompactVariant: Equatable {
    /// 노치 양옆 날개. 한쪽 폭이 0 이면 그쪽 날개는 없고, 한쪽 날개에 `items` 를 모은다.
    case wings(left: CGFloat, right: CGFloat, items: CompactItems)
    /// 노치 바로 아래로 내린 띠
    case strip
    /// 노치 아래 가장자리의 상태 색 선
    case line
    /// 알약 (메뉴바 안 또는 메뉴바 아래)
    case pill(items: CompactItems)
    /// 메뉴바 안 점
    case dot
}

/// 접힌 상태에 넣을 선택 요소 (상태 아이콘과 `+N −M`/상태 문구는 항상 표시)
struct CompactItems: OptionSet, Hashable {
    let rawValue: Int
    static let project = CompactItems(rawValue: 1 << 0)
    static let tool = CompactItems(rawValue: 1 << 1)
    static let all: CompactItems = [.project, .tool]
}

/// 카드 상단 행 자리 (프레임 기준)
struct HeaderSlot: Equatable {
    var top: CGFloat = 0
    var height: CGFloat = 0
    var leftInset: CGFloat = 0
    var rightInset: CGFloat = 0
    /// 가운데 비울 폭 (노치). 0 이면 비우지 않는다
    var notchGap: CGFloat = 0
}

/// 아일랜드 위치 · 크기 · 모양. SwiftUI 뷰와 클릭 영역 계산이 같은 값을 쓴다.
struct IslandLayout: Equatable {
    /// 프레임 크기 (귀 포함)
    var size: CGSize
    /// 패널(화면 맨 위, 화면 전체 폭) 기준 프레임 왼쪽 위
    var origin: CGPoint
    var shape: IslandShapeSpec
    /// 접힌 상태면 표시 방식, 펼친 카드면 nil
    var compact: CompactVariant?
    /// 카드 상단 행
    var header = HeaderSlot()
    /// 카드 몸통 폭 (본문 텍스트 줄 수 계산용)
    var cardWidth: CGFloat = 0
    /// 클릭을 받는 영역 (프레임 기준). 목 옆 메뉴바 아이템 위에서는 클릭을 통과시키기 위해 목과 몸통을 따로 둔다.
    var hitRects: [CGRect] = []

    private var hasBody: Bool { shape.neckHeight < size.height - 0.5 }

    /// 본문 시작 y. 상단 행이 목 안에 있으면 본문은 목(메뉴바 높이) 아래부터.
    var contentTop: CGFloat {
        let headerBottom = header.top + header.height
        guard hasBody, header.top < shape.neckHeight else { return headerBottom }
        return max(headerBottom, shape.neckHeight)
    }
    /// 본문 왼쪽/오른쪽 여백 (귀 때문에 프레임이 몸통보다 넓을 때)
    var contentLeftInset: CGFloat { hasBody ? min(shape.bodyLeft, shape.neckLeft) : shape.neckLeft }
    var contentRightInset: CGFloat { hasBody ? min(shape.bodyRight, shape.neckRight) : shape.neckRight }

    /// 패널(화면 맨 위) 기준 사각형 (원점 왼쪽 위)
    var panelRect: CGRect { CGRect(origin: origin, size: size) }
}

// MARK: - 접힌 상태 내용 크기

/// 접힌 상태에 보여줄 내용과 텍스트 폭 (레이아웃 선택용)
enum CompactContent: Equatable {
    case idle(count: Int)
    case session(CompactMetrics)
}

struct CompactMetrics: Equatable {
    var project: CGFloat
    var shortTool: CGFloat
    var fullTool: CGFloat
    /// `+N −M` 또는 상태 문구 (없으면 0)
    var trailing: CGFloat
    /// 상태 문구(승인 필요 등)를 보여주는 단계라 툴 이름이 없는지
    var isAttention: Bool

    init(project: CGFloat, shortTool: CGFloat, fullTool: CGFloat, trailing: CGFloat, isAttention: Bool) {
        self.project = project
        self.shortTool = shortTool
        self.fullTool = fullTool
        self.trailing = trailing
        self.isAttention = isAttention
    }

    @MainActor
    init(session: AgentSession) {
        let attention = CompactText.attentionText(session)
        project = CompactText.width(session.projectName, font: IslandFont.bodyNS)
        if let attention {
            shortTool = 0
            fullTool = 0
            trailing = CompactText.width(attention.text, font: IslandFont.bodyNS)
            isAttention = true
        } else {
            shortTool = CompactText.width(IslandFormat.shortToolTitle(session), font: IslandFont.bodyNS)
            fullTool = CompactText.width(IslandFormat.fullToolTitle(session), font: IslandFont.bodyNS)
            trailing = CompactText.statWidth(added: session.turn.added, removed: session.turn.removed)
            isAttention = false
        }
    }
}

/// 접힌 상태 문구 측정 · 결정 (뷰와 레이아웃이 같은 규칙을 쓴다)
enum CompactText {
    enum Tone { case amber, red, muted }

    /// 작업 중이 아닌 단계의 상태 문구 (승인 필요 등). 작업 중이면 nil
    static func attentionText(_ session: AgentSession) -> (text: String, tone: Tone)? {
        switch session.phase {
        case .waitingPermission: return ("승인 필요", .amber)
        case .waitingInput: return ("입력 필요", .amber)
        case .failed: return ("실패", .red)
        case .completed: return ("완료", .muted)
        default: return nil
        }
    }

    static func width(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// `+N −M` 폭 (둘 다 0 이면 표시 안 함)
    static func statWidth(added: Int, removed: Int) -> CGFloat {
        guard added > 0 || removed > 0 else { return 0 }
        return width("+\(added)", font: IslandFont.monoNS) + 4 + width("\u{2212}\(removed)", font: IslandFont.monoNS)
    }
}

// MARK: - 레이아웃 계산

/// 접힌 상태가 놓일 자리
enum CompactPlacement: Equatable {
    case wings(left: CGFloat, right: CGFloat, items: CompactItems)
    case strip(width: CGFloat)
    case line
    case menuBarPill(centerX: CGFloat, width: CGFloat, items: CompactItems)
    case menuBarDot(centerX: CGFloat)
    case belowMenuBarPill(width: CGFloat, items: CompactItems)
    /// 접힌 상태를 숨김 (알림 카드는 표시)
    case none
}

/// 화면 하나의 아일랜드 레이아웃 계산 (순수 계산 — 실제 패널과 스냅숏 렌더링이 함께 쓴다)
struct IslandLayoutEngine {
    let geometry: NotchGeometry
    /// 메뉴바 빈 공간 측정값 (아직 모르면 nil)
    let space: MenuBarSpace?
    let externalStyle: ExternalDisplayStyle
    let overlapStyle: CompactOverlapStyle
    /// 다른 노치 앱이 노치를 쓰는 중
    let notchConflict: Bool

    private typealias M = IslandMetrics

    // MARK: 화면 정보 (화면 왼쪽 기준 상대 x)

    var screenWidth: CGFloat { geometry.frame.width }
    var midX: CGFloat { (screenWidth / 2).rounded() }
    var menuBarHeight: CGFloat { space?.menuBarHeight ?? geometry.menuBarHeight }
    var menuBarVisible: Bool { space?.menuBarVisible ?? true }
    var notchWidth: CGFloat { geometry.notchSize.width }
    var notchMinX: CGFloat { midX - notchWidth / 2 }
    var notchMaxX: CGFloat { midX + notchWidth / 2 }
    /// 노치 화면 목 높이 (노치와 메뉴바 중 큰 쪽)
    var neckHeight: CGFloat { max(geometry.headerHeight, menuBarHeight) }

    /// 노치 양옆 빈 폭 (여백 제외). 모르거나 막혔으면 0.
    var notchFree: (left: CGFloat, right: CGFloat) {
        guard geometry.hasNotch, !notchConflict, let space else { return (0, 0) }
        // 앱 메뉴가 노치까지 이어지면(노치 오른쪽으로 넘어감) 노치 양옆 모두 막힌 것
        if space.appMenuMeasured, space.appMenuEnd > notchMinX { return (0, 0) }
        let left = space.appMenuMeasured ? max(0, notchMinX - M.menuBarMargin - space.appMenuEnd) : 0
        let right = space.statusMeasured ? max(0, space.statusStart - M.menuBarMargin - notchMaxX) : 0
        return (left, right)
    }

    /// 노치 없는 화면: 앱 메뉴 끝 ~ 상태 아이템 시작 구간 (여백 미포함)
    var menuBarGap: (start: CGFloat, end: CGFloat)? {
        let appEnd: CGFloat
        if let space, space.appMenuMeasured {
            appEnd = space.appMenuEnd
        } else {
            // 손쉬운 사용 권한이 없으면 앱 메뉴가 화면 폭의 45%(최대 900pt)까지 차 있다고 본다
            appEnd = min(screenWidth * 0.45, 900)
        }
        let statusStart: CGFloat
        if let space, space.statusMeasured {
            statusStart = space.statusStart
        } else {
            // 상태 아이템을 못 재면 오른쪽 40%(최대 760pt)를 차지한다고 본다
            statusStart = screenWidth - min(screenWidth * 0.4, 760)
        }
        guard statusStart > appEnd else { return nil }
        return (appEnd, statusStart)
    }

    // MARK: 접힌 상태 자리 고르기

    func compactPlacement(for content: CompactContent) -> CompactPlacement {
        geometry.hasNotch ? notchPlacement(content) : externalPlacement(content)
    }

    private func notchPlacement(_ content: CompactContent) -> CompactPlacement {
        let free = notchFree
        let appMenuMeasured = space?.appMenuMeasured ?? false

        switch content {
        case let .idle(count):
            let dots = M.idleDotsWidth(count: count)
            let both = max(28, dots + M.wingPadding + 8)
            if free.left >= both, free.right >= both {
                return .wings(left: both, right: both, items: .all)
            }
            let single = dots + M.wingPadding + 6
            if free.right >= single { return .wings(left: 0, right: single, items: []) }
            if appMenuMeasured, free.left >= single { return .wings(left: single, right: 0, items: []) }

        case let .session(metrics):
            let both = min(M.workingWing, free.left, free.right)
            if both >= M.minBothWing { return .wings(left: both, right: both, items: .all) }
            if let wing = singleWing(available: free.right, metrics) {
                return .wings(left: 0, right: wing.width, items: wing.items)
            }
            if appMenuMeasured, let wing = singleWing(available: free.left, metrics) {
                return .wings(left: wing.width, right: 0, items: wing.items)
            }
        }

        switch overlapStyle {
        case .belowNotch: return .strip(width: stripWidth(content))
        case .minimal: return .line
        }
    }

    /// 날개 하나에 모을 때 폭과 요소 (프로젝트명 → 툴 이름 순으로 생략)
    private func singleWing(available: CGFloat, _ metrics: CompactMetrics) -> (width: CGFloat, items: CompactItems)? {
        let cap = min(available, M.maxSingleWing)
        // 상태 문구(승인 필요 등)를 보여줄 땐 툴 이름이 없다
        let variants: [CompactItems] = metrics.isAttention ? [[.project], []] : [.all, [.tool], []]
        for items in variants {
            // SwiftUI 실제 배치가 측정값보다 조금 넓게 잡히는 것을 감안해 8pt 여유
            let need = M.wingPadding + 6 + 8 + Self.contentWidth(metrics, items: items, toolWidth: metrics.shortTool, toolCap: 90)
            if need <= cap { return (min(cap, (need / 8).rounded(.up) * 8), items) }
        }
        return nil
    }

    /// 상태 아이콘 + 선택 요소 + `+N −M` 폭
    static func contentWidth(_ metrics: CompactMetrics, items: CompactItems, toolWidth: CGFloat, toolCap: CGFloat) -> CGFloat {
        var width: CGFloat = 14
        if items.contains(.project) { width += 6 + min(metrics.project, 110) }
        if items.contains(.tool), toolWidth > 0 { width += 6 + min(toolWidth, toolCap) }
        if metrics.trailing > 0 { width += 6 + metrics.trailing }
        return width
    }

    private func stripWidth(_ content: CompactContent) -> CGFloat {
        let need: CGFloat
        switch content {
        case let .idle(count):
            need = M.idleDotsWidth(count: count) + 20
        case let .session(metrics):
            need = Self.contentWidth(metrics, items: [.tool], toolWidth: metrics.shortTool, toolCap: 120) + 20
        }
        return min(max(need, notchWidth), notchWidth + M.stripExtraWidth).rounded(.up)
    }

    private func externalPlacement(_ content: CompactContent) -> CompactPlacement {
        switch externalStyle {
        case .hidden:
            return .none
        case .belowMenuBar:
            switch content {
            case let .idle(count): return .belowMenuBarPill(width: M.idleDotsWidth(count: count) + 28, items: .all)
            case .session: return .belowMenuBarPill(width: M.pillWorkingWidth, items: .all)
            }
        case .inMenuBar:
            guard menuBarVisible, let gap = menuBarGap else { return .none }
            let margins = M.menuBarMargin * 2
            var center = ((gap.start + gap.end) / 2).rounded()
            var room = gap.end - gap.start - margins
            // 화면 가운데가 빈 구간 안이고 가운데에 둘 자리가 있으면 가운데
            if midX > gap.start, midX < gap.end {
                let centeredRoom = 2 * min(midX - gap.start, gap.end - midX) - margins
                if centeredRoom >= M.minMenuBarPill {
                    center = midX
                    room = centeredRoom
                }
            }
            if room < M.minMenuBarPill {
                return room >= M.menuBarDotSize ? .menuBarDot(centerX: center) : .none
            }
            switch content {
            case let .idle(count):
                return .menuBarPill(centerX: center, width: min(M.idleDotsWidth(count: count) + 28, room), items: .all)
            case let .session(metrics):
                let full = pillNeed(metrics, items: .all)
                let desired = min(max((full / 20).rounded(.up) * 20, 120), M.pillWorkingWidth)
                let width = min(desired, room).rounded(.down)
                let items = [CompactItems.all, [.tool], []].first { pillNeed(metrics, items: $0) <= width } ?? []
                return .menuBarPill(centerX: center, width: width, items: items)
            }
        }
    }

    /// 알약 내용 폭 (좌우 여백 12 포함). 프로젝트 · 툴 제목을 한 덩어리로 보여준다.
    private func pillNeed(_ metrics: CompactMetrics, items: CompactItems) -> CGFloat {
        var text: CGFloat = 0
        if items.contains(.project) { text += min(metrics.project, 110) }
        if items.contains(.tool), !metrics.isAttention, metrics.fullTool > 0 {
            text += (text > 0 ? 14 : 0) + min(metrics.fullTool, 200)
        }
        var width: CGFloat = 24 + 12
        if text > 0 { width += 6 + text }
        if metrics.trailing > 0 { width += 6 + metrics.trailing }
        return width
    }

    // MARK: 레이아웃

    /// 숨김 (투명하게 접히는 동안 쓰는 작은 모양)
    func hiddenLayout() -> IslandLayout {
        if geometry.hasNotch {
            let size = CGSize(width: notchWidth, height: geometry.headerHeight)
            return IslandLayout(
                size: size,
                origin: CGPoint(x: notchMinX, y: 0),
                shape: IslandShapeSpec(neckHeight: size.height, bottomRadius: 10),
                compact: nil
            )
        }
        let size = CGSize(width: 60, height: 22)
        let top = externalStyle == .inMenuBar && menuBarVisible ? max(0, (menuBarHeight - size.height) / 2) : menuBarHeight + NotchGeometry.pillTopGap
        return IslandLayout(
            size: size,
            origin: CGPoint(x: midX - size.width / 2, y: top),
            shape: IslandShapeSpec(neckHeight: size.height, topRadius: 11, bottomRadius: 11),
            compact: nil
        )
    }

    func compactLayout(for content: CompactContent) -> IslandLayout {
        let placement = compactPlacement(for: content)
        let isIdle: Bool
        if case .idle = content { isIdle = true } else { isIdle = false }

        switch placement {
        case let .wings(left, right, items):
            let height = geometry.headerHeight
            let earL: CGFloat = left > 0 ? 6 : 0
            let earR: CGFloat = right > 0 ? 6 : 0
            let width = earL + left + notchWidth + right + earR
            var layout = IslandLayout(
                size: CGSize(width: width, height: height),
                origin: CGPoint(x: notchMinX - left - earL, y: 0),
                shape: IslandShapeSpec(
                    neckLeft: earL, neckRight: earR, neckHeight: height,
                    leftEar: earL, rightEar: earR, bottomRadius: isIdle ? 10 : 12
                ),
                compact: .wings(left: left, right: right, items: items)
            )
            layout.hitRects = [CGRect(x: earL, y: 0, width: left + notchWidth + right, height: height)]
            return layout

        case let .strip(width):
            let neck = neckHeight
            let height = neck + M.stripHeight
            let inset = ((width - notchWidth) / 2).rounded(.down)
            var layout = IslandLayout(
                size: CGSize(width: width, height: height),
                origin: CGPoint(x: midX - width / 2, y: 0),
                shape: IslandShapeSpec(
                    neckLeft: inset, neckRight: inset, neckHeight: neck,
                    bodyTopRadius: 8, shoulderRadius: 6, bottomRadius: M.stripHeight / 2
                ),
                compact: .strip
            )
            layout.hitRects = [
                CGRect(x: inset, y: 0, width: width - inset * 2, height: neck),
                CGRect(x: 0, y: neck, width: width, height: M.stripHeight),
            ]
            return layout

        case .line:
            let height = neckHeight + M.lineThickness
            var layout = IslandLayout(
                size: CGSize(width: notchWidth, height: height),
                origin: CGPoint(x: notchMinX, y: 0),
                shape: IslandShapeSpec(neckHeight: height, bottomRadius: M.lineThickness),
                compact: .line
            )
            layout.hitRects = [CGRect(origin: .zero, size: layout.size)]
            return layout

        case let .menuBarPill(centerX, width, items):
            let height = max(16, menuBarHeight - 4)
            var layout = IslandLayout(
                size: CGSize(width: width, height: height),
                origin: CGPoint(x: (centerX - width / 2).rounded(), y: ((menuBarHeight - height) / 2).rounded(.down)),
                shape: IslandShapeSpec(neckHeight: height, topRadius: height / 2, bottomRadius: height / 2),
                compact: .pill(items: items)
            )
            layout.hitRects = [CGRect(origin: .zero, size: layout.size)]
            return layout

        case let .menuBarDot(centerX):
            let size = M.menuBarDotSize
            var layout = IslandLayout(
                size: CGSize(width: size, height: size),
                origin: CGPoint(x: (centerX - size / 2).rounded(), y: ((menuBarHeight - size) / 2).rounded(.down)),
                shape: IslandShapeSpec(neckHeight: size, topRadius: size / 2, bottomRadius: size / 2),
                compact: .dot
            )
            // 점은 작아서 클릭 영역을 조금 넓힌다
            layout.hitRects = [CGRect(x: -4, y: -4, width: size + 8, height: size + 8)]
            return layout

        case let .belowMenuBarPill(width, items):
            let height = NotchGeometry.pillHeaderHeight
            var layout = IslandLayout(
                size: CGSize(width: width, height: height),
                origin: CGPoint(x: midX - width / 2, y: menuBarHeight + NotchGeometry.pillTopGap),
                shape: IslandShapeSpec(neckHeight: height, topRadius: height / 2, bottomRadius: height / 2),
                compact: .pill(items: items)
            )
            layout.hitRects = [CGRect(origin: .zero, size: layout.size)]
            return layout

        case .none:
            return hiddenLayout()
        }
    }

    /// 펼친 카드. `bodyHeight` 는 카드 폭을 받아 상단 행 아래 본문 높이를 돌려준다.
    func cardLayout(
        preferredWidth: CGFloat,
        radius: CGFloat,
        compact: CompactPlacement,
        bodyHeight: (CGFloat) -> CGFloat
    ) -> IslandLayout {
        if geometry.hasNotch {
            return notchCard(preferredWidth: preferredWidth, radius: radius, bodyHeight: bodyHeight)
        }
        let maxWidth = preferredWidth > M.externalCardMaxWidth
            ? min(preferredWidth, screenWidth - 16)
            : min(preferredWidth, M.externalCardMaxWidth)
        let cardWidth = max(200, maxWidth)
        if case let .menuBarPill(centerX, pillWidth, _) = compact {
            return pillCard(cardWidth: cardWidth, pillCenter: centerX, pillWidth: pillWidth, radius: radius, bodyHeight: bodyHeight)
        }
        let anchor: CGFloat
        if case let .menuBarDot(centerX) = compact { anchor = centerX } else { anchor = midX }
        let top = (menuBarVisible ? menuBarHeight : 0) + NotchGeometry.pillTopGap
        return floatingCard(cardWidth: cardWidth, anchorX: anchor, top: top, radius: radius, bodyHeight: bodyHeight)
    }

    private func notchCard(preferredWidth: CGFloat, radius: CGFloat, bodyHeight: (CGFloat) -> CGFloat) -> IslandLayout {
        let free = notchFree
        let cardWidth = max(preferredWidth, notchWidth + 80)
        let neck = neckHeight
        let allowed = min(free.left, free.right)
        let headerInNeck = allowed >= M.headerWingMin
        let wing = headerInNeck ? min(allowed, (cardWidth - notchWidth) / 2) : 0
        let neckWidth = notchWidth + wing * 2
        let earL: CGFloat = headerInNeck || free.left >= 8 ? 8 : 0
        let earR: CGFloat = headerInNeck || free.right >= 8 ? 8 : 0
        let frameWidth = max(cardWidth, neckWidth + max(earL, earR) * 2)
        let neckInset = (frameWidth - neckWidth) / 2
        let bodyInset = (frameWidth - cardWidth) / 2
        let headerHeight = headerInNeck ? 0 : M.headerRowHeight
        let body = bodyHeight(cardWidth)
        let height = neck + headerHeight + body

        var layout = IslandLayout(
            size: CGSize(width: frameWidth, height: height),
            origin: CGPoint(x: midX - frameWidth / 2, y: 0),
            shape: IslandShapeSpec(
                neckLeft: neckInset, neckRight: neckInset, neckHeight: neck,
                bodyLeft: bodyInset, bodyRight: bodyInset,
                leftEar: earL, rightEar: earR,
                bodyTopRadius: 14, shoulderRadius: 10, bottomRadius: radius
            ),
            compact: nil,
            cardWidth: cardWidth
        )
        layout.header = headerInNeck
            ? HeaderSlot(top: 0, height: neck, leftInset: neckInset, rightInset: neckInset, notchGap: notchWidth + 8)
            : HeaderSlot(top: neck, height: M.headerRowHeight, leftInset: bodyInset, rightInset: bodyInset)
        layout.hitRects = [
            CGRect(x: neckInset, y: 0, width: neckWidth, height: neck),
            CGRect(x: bodyInset, y: neck, width: cardWidth, height: height - neck),
        ]
        return layout
    }

    /// 메뉴바 알약에서 내려오는 카드: 목 = 알약, 메뉴바 아래부터 넓어진다
    private func pillCard(
        cardWidth: CGFloat,
        pillCenter: CGFloat,
        pillWidth: CGFloat,
        radius: CGFloat,
        bodyHeight: (CGFloat) -> CGFloat
    ) -> IslandLayout {
        let pillHeight = max(16, menuBarHeight - 4)
        let top = ((menuBarHeight - pillHeight) / 2).rounded(.down)
        let pillX = (pillCenter - pillWidth / 2).rounded()
        var cardX = (pillCenter - cardWidth / 2).rounded()
        cardX = min(max(cardX, 8), screenWidth - 8 - cardWidth)
        // 알약이 카드 밖으로 삐져나오지 않게
        let frameX = min(cardX, pillX)
        let frameWidth = max(cardX + cardWidth, pillX + pillWidth) - frameX
        let neck = menuBarHeight - top
        let headerInNeck = pillWidth >= M.pillHeaderMin
        let body = bodyHeight(frameWidth)
        let height = neck + (headerInNeck ? 0 : M.headerRowHeight) + body
        let neckLeft = pillX - frameX
        let neckRight = frameX + frameWidth - (pillX + pillWidth)

        var layout = IslandLayout(
            size: CGSize(width: frameWidth, height: height),
            origin: CGPoint(x: frameX, y: top),
            shape: IslandShapeSpec(
                neckLeft: neckLeft, neckRight: neckRight, neckHeight: neck,
                topRadius: pillHeight / 2, bodyTopRadius: 14, shoulderRadius: 8, bottomRadius: radius
            ),
            compact: nil,
            cardWidth: frameWidth
        )
        layout.header = headerInNeck
            ? HeaderSlot(top: 0, height: pillHeight, leftInset: neckLeft, rightInset: neckRight)
            : HeaderSlot(top: neck, height: M.headerRowHeight)
        layout.hitRects = [
            CGRect(x: neckLeft, y: 0, width: pillWidth, height: neck),
            CGRect(x: 0, y: neck, width: frameWidth, height: height - neck),
        ]
        return layout
    }

    /// 메뉴바 아래 떠 있는 카드 (알약이 없을 때, 메뉴바 아래 방식)
    private func floatingCard(
        cardWidth: CGFloat,
        anchorX: CGFloat,
        top: CGFloat,
        radius: CGFloat,
        bodyHeight: (CGFloat) -> CGFloat
    ) -> IslandLayout {
        let header = NotchGeometry.pillHeaderHeight
        let height = header + bodyHeight(cardWidth)
        var x = (anchorX - cardWidth / 2).rounded()
        x = min(max(x, 8), screenWidth - 8 - cardWidth)
        var layout = IslandLayout(
            size: CGSize(width: cardWidth, height: height),
            origin: CGPoint(x: x, y: top),
            shape: IslandShapeSpec(neckHeight: height, topRadius: radius, bottomRadius: radius),
            compact: nil,
            cardWidth: cardWidth
        )
        layout.header = HeaderSlot(top: 0, height: header)
        layout.hitRects = [CGRect(origin: .zero, size: layout.size)]
        return layout
    }

    /// 열린 메뉴와 겹치는지 볼 영역: 카드가 펼쳐질 자리 (패널 기준)
    func cardZone() -> CGRect {
        let layout = cardLayout(
            preferredWidth: IslandMetrics.permissionWidth,
            radius: 22,
            compact: compactPlacement(for: .idle(count: 1)),
            bodyHeight: { _ in 150 }
        )
        return layout.panelRect
    }
}
