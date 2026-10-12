import AppKit
import NotchCore

// MARK: - 레이아웃 결과

/// 접힌 상태 표시 방식 (뷰가 그대로 따라 그린다)
enum CompactVariant: Equatable {
    /// 노치 양옆 날개 (폭 · 내용 자리 · 아이콘 구멍 · 비켜준 쪽)
    case wings(WingsSpec)
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
    /// 메뉴바 아이콘이 비쳐 보이도록 검은 배경에 뚫은 구멍 (프레임 기준)
    var holes: [CGRect] = []
    /// 클릭 · 마우스를 아래 메뉴바 아이템으로 통과시키는 영역 (프레임 기준, `hitRects` 보다 우선)
    var passThroughRects: [CGRect] = []

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
    case wings(WingsSpec)
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
    /// 노치 화면 표시 방식 (넓은 노치 / 노치 아래)
    let notchStyle: NotchStyle
    let overlapStyle: CompactOverlapStyle
    /// 다른 노치 앱이 노치를 쓰는 중
    let notchConflict: Bool
    /// 넓은 노치에서 마우스를 올려 비켜준 날개 (아이콘 위치를 모를 때만 쓴다)
    var retracted: WingSides = []

    private typealias M = IslandMetrics
    private typealias C = WingCutouts

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

    /// 넓은 노치(날개) 방식을 쓰는지. 다른 노치 앱이 있으면 노치 아래 방식으로 물러난다.
    var usesWings: Bool { geometry.hasNotch && notchStyle == .wings && !notchConflict }

    /// 넓은 노치에서 메뉴바 아이콘 위치를 알아(손쉬운 사용) 날개에 아이콘 구멍을 뚫는지.
    /// 모르면 날개가 아이콘을 덮고, 마우스를 올리면 비켜준다.
    var cutsIconHoles: Bool { usesWings && (space?.itemsMeasured ?? false) }

    /// 노치 오른쪽 · 왼쪽 메뉴바 아이템 (노치에서 가까운 순)
    private var rightItems: [WingCutouts.Item] {
        C.items(space?.itemFrames ?? [], side: .right, notchMinX: notchMinX, notchMaxX: notchMaxX)
    }
    private var leftItems: [WingCutouts.Item] {
        C.items(space?.itemFrames ?? [], side: .left, notchMinX: notchMinX, notchMaxX: notchMaxX)
    }

    /// 넓은 노치: 한쪽 날개가 쓸 수 있는 최대 폭.
    /// 메뉴바 아이템이 있어도 덮으므로 화면의 노치 옆 영역까지 쓰되,
    /// 앞 앱 메뉴를 손쉬운 사용으로 쟀으면 왼쪽은 메뉴 끝 + 여백까지만 쓴다.
    var wingLimit: (left: CGFloat, right: CGFloat) {
        var left = max(0, notchMinX - M.menuBarMargin)
        let right = max(0, screenWidth - notchMaxX - M.menuBarMargin)
        if let space, space.appMenuMeasured {
            left = space.appMenuEnd > notchMinX ? 0 : min(left, max(0, notchMinX - M.menuBarMargin - space.appMenuEnd))
        }
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
        if usesWings, let placement = wingsPlacement(content) { return placement }
        let free = notchFree
        let appMenuMeasured = space?.appMenuMeasured ?? false

        switch content {
        case let .idle(count):
            let dots = M.idleDotsWidth(count: count)
            let both = max(28, dots + M.wingPadding + 8)
            if free.left >= both, free.right >= both {
                return .wings(.plain(left: both, right: both, items: .all))
            }
            let single = dots + M.wingPadding + 6
            if free.right >= single { return .wings(.plain(left: 0, right: single, items: [])) }
            if appMenuMeasured, free.left >= single { return .wings(.plain(left: single, right: 0, items: [])) }

        case let .session(metrics):
            let both = min(M.workingWing, free.left, free.right)
            if both >= M.minBothWing { return .wings(.plain(left: both, right: both, items: .all)) }
            if let wing = singleWing(available: free.right, metrics) {
                return .wings(.plain(left: 0, right: wing.width, items: wing.items))
            }
            if appMenuMeasured, let wing = singleWing(available: free.left, metrics) {
                return .wings(.plain(left: wing.width, right: 0, items: wing.items))
            }
        }

        switch overlapStyle {
        case .belowNotch: return .strip(width: notchWidth)
        case .minimal: return .line
        }
    }

    /// 넓은 노치: 빈 공간 측정과 관계없이 양쪽 날개 (목업 기본형). 그것도 안 되면 nil (노치 아래 방식).
    /// - 아이콘 위치를 모르면 날개가 아이콘을 덮고, 마우스를 올린 쪽(`retracted`)은 비켜준다.
    /// - 아이콘 위치를 알면 날개에 아이콘 구멍을 뚫고 내용은 구멍을 피해 둔다 (`iconWings`).
    private func wingsPlacement(_ content: CompactContent) -> CompactPlacement? {
        guard let base = baseWings(content) else { return nil }
        if cutsIconHoles { return .wings(iconWings(content, base: base)) }
        return .wings(.plain(left: base.left, right: base.right, items: base.items, hidden: retracted))
    }

    /// 넓은 노치 기본 폭: 내용에 맞추되 한쪽 `wideWingMax` 이하, 노치를 가운데 두도록 양쪽을 같게.
    /// 왼쪽이 앞 앱 메뉴로 모자라면 왼쪽 날개를 없애고 내용을 오른쪽 날개에 모은다.
    private func baseWings(_ content: CompactContent) -> (left: CGFloat, right: CGFloat, items: CompactItems)? {
        let limit = wingLimit
        switch content {
        case let .idle(count):
            let dots = M.idleDotsWidth(count: count)
            let both = max(28, dots + M.wingPadding + 8)
            if limit.left >= both, limit.right >= both { return (both, both, .all) }
            let single = dots + M.wingPadding + 6
            if limit.right >= single { return (0, single, []) }

        case let .session(metrics):
            let pad = M.wingPadding
            let project = min(metrics.project, M.wideWingProjectCap)
            // 왼쪽: 상태 + 프로젝트명, 오른쪽: 툴 + `+N −M` (또는 상태 문구). SwiftUI 배치 오차 8pt 여유.
            let leftNeed = pad + 14 + (project > 0 ? 6 + project : 0) + 4 + 8
            var rightText = metrics.trailing
            if !metrics.isAttention, metrics.shortTool > 0 {
                rightText += min(metrics.shortTool, M.wideWingToolCap) + (metrics.trailing > 0 ? 6 : 0)
            }
            let rightNeed = 4 + rightText + pad + 8
            let wing = min(max(leftNeed, rightNeed, M.minWideWing), M.wideWingMax)
            let both = (wing / 4).rounded(.up) * 4
            // 프로젝트명은 줄일 수 있으니 왼쪽은 앞 몇 글자만 들어가도 된다
            let leftMin = pad + 14 + 6 + min(project, 40) + 4
            if limit.left >= leftMin, limit.right >= min(both, rightNeed) {
                return (min(both, limit.left), min(both, limit.right), .all)
            }
            if let wing = singleWing(available: limit.right, metrics) {
                return (0, wing.width, wing.items)
            }
        }
        return nil
    }

    /// 아이콘 구멍을 뚫는 넓은 노치.
    /// - 검은 날개 폭은 기본 폭 그대로 두되, 걸친 아이콘은 반으로 자르지 않게 품도록 늘린다 (한쪽 최대 `iconWingMax`).
    /// - 내용은 노치 ~ 첫 구멍 사이에 둔다. 한쪽이 28pt 미만이면 다른 쪽에 모으고, 양쪽 다 모자라면 노치 아래 띠에 둔다
    ///   (이때도 검은 날개와 구멍은 그대로 둬서 넓은 노치 모양을 유지).
    private func iconWings(
        _ content: CompactContent,
        base: (left: CGFloat, right: CGFloat, items: CompactItems)
    ) -> WingsSpec {
        let limit = wingLimit
        let rightItems = rightItems
        let leftItems = leftItems
        let cap = (left: min(M.iconWingMax, limit.left), right: min(M.iconWingMax, limit.right))
        // 노치 가장자리 ~ 첫 구멍 앞 (날개를 쓸 수 있는 폭 이내)
        let room = (left: min(limit.left, C.room(leftItems)), right: min(limit.right, C.room(rightItems)))
        let minRoom = M.wingContentMinRoom

        func fitted(_ width: CGFloat, _ side: WingCutouts.Side) -> CGFloat {
            guard width > 0 else { return 0 }
            return side == .left
                ? C.fitEdge(width, items: leftItems, cap: cap.left)
                : C.fitEdge(width, items: rightItems, cap: cap.right)
        }

        var spec = WingsSpec(
            left: fitted(base.left, .left),
            right: fitted(base.right, .right),
            items: base.items,
            arrangement: .strip,
            leftSpan: 0,
            rightSpan: 0,
            leftOuterPad: M.wingPadding,
            rightOuterPad: M.wingPadding
        )

        /// 내용을 한쪽에 모은다 (그쪽 날개는 내용을 품을 만큼 넓힌다)
        func single(_ side: WingCutouts.Side, width: CGFloat, items: CompactItems) {
            spec.items = items
            switch side {
            case .left:
                spec.arrangement = .left
                spec.left = max(fitted(max(base.left, width), .left), width)
                spec.leftSpan = width
            case .right:
                spec.arrangement = .right
                spec.right = max(fitted(max(base.right, width), .right), width)
                spec.rightSpan = width
            }
        }

        switch content {
        case let .idle(count):
            let dots = M.idleDotsWidth(count: count)
            let singleWidth = dots + M.wingPadding + 6
            // 양쪽: 왼쪽엔 작은 점, 오른쪽엔 세션 점
            if base.left > 0, base.right > 0, room.left >= minRoom, room.right >= max(minRoom, dots + 4 + 6) {
                spec.arrangement = .split
            } else {
                let order: [WingCutouts.Side] = room.left >= room.right ? [.left, .right] : [.right, .left]
                if let side = order.first(where: { (side: WingCutouts.Side) in
                    side == .left ? room.left >= singleWidth : room.right >= singleWidth
                }) {
                    single(side, width: singleWidth, items: [])
                }
            }

        case let .session(metrics):
            // 양쪽: 왼쪽 상태(+ 프로젝트) · 오른쪽 (툴 +) `+N −M`
            let leftMin: CGFloat = 4 + 14 + 6
            let main = metrics.trailing > 0 ? metrics.trailing : min(metrics.shortTool, 40)
            let rightMin = 4 + main + 6
            if base.left > 0, base.right > 0,
               room.left >= max(minRoom, leftMin), room.right >= max(minRoom, rightMin) {
                spec.arrangement = .split
                var items = CompactItems.all
                if room.left < leftMin + 6 + min(metrics.project, 24) { items.remove(.project) }
                if metrics.trailing > 0, room.right < rightMin + 6 + min(metrics.shortTool, 28) { items.remove(.tool) }
                spec.items = items
            } else {
                let order: [WingCutouts.Side] = room.left >= room.right ? [.left, .right] : [.right, .left]
                for side in order {
                    let available = side == .left ? room.left : room.right
                    guard available >= minRoom, let wing = singleWing(available: available, metrics) else { continue }
                    single(side, width: wing.width, items: wing.items)
                    break
                }
            }
        }

        // 내용 자리: 양쪽이면 노치 ~ 첫 구멍(또는 날개 끝)
        if spec.arrangement == .split {
            spec.leftSpan = min(spec.left, room.left)
            spec.rightSpan = min(spec.right, room.right)
        }
        if spec.leftSpan > 0, spec.leftSpan < spec.left - 0.5 { spec.leftOuterPad = 4 }
        if spec.rightSpan > 0, spec.rightSpan < spec.right - 0.5 { spec.rightOuterPad = 4 }

        let band = spec.arrangement == .strip ? neckHeight : geometry.headerHeight
        spec.holes = C.holes(leftItems, side: .left, wing: spec.left, bandHeight: band, notchMinX: notchMinX, notchMaxX: notchMaxX)
            + C.holes(rightItems, side: .right, wing: spec.right, bandHeight: band, notchMinX: notchMinX, notchMaxX: notchMaxX)
        return spec
    }

    /// 넓은 노치에서 마우스를 올리면 비켜줄 날개 자리 (패널 기준).
    /// 아이콘 위치를 몰라 날개가 아이콘을 덮을 때만 있다 (아이콘 구멍을 쓰면 비켜줄 필요 없음).
    func retractBands(for content: CompactContent) -> WingBands {
        guard usesWings, !cutsIconHoles, case let .wings(spec) = compactPlacement(for: content), spec.arrangement != .strip
        else { return .none }
        let ear: CGFloat = 6
        var bands = WingBands()
        if spec.left > 0 {
            bands.left = CGRect(x: notchMinX - spec.left - ear, y: 0, width: spec.left + ear, height: neckHeight)
        }
        if spec.right > 0 {
            bands.right = CGRect(x: notchMaxX, y: 0, width: spec.right + ear, height: neckHeight)
        }
        return bands
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
        case let .wings(spec):
            // 비켜준 쪽은 폭 0 (내용은 뷰에서 숨김)
            let left = spec.visibleLeft
            let right = spec.visibleRight
            let earL: CGFloat = left > 0 ? 6 : 0
            let earR: CGFloat = right > 0 ? 6 : 0
            let width = earL + left + notchWidth + right + earR
            let originX = notchMinX - left - earL
            let band: CGFloat
            var layout: IslandLayout
            if spec.arrangement == .strip {
                // 검은 날개(목)는 그대로 두고 노치 폭만큼 아래로 띠를 내린다 (몸통이 목보다 좁은 모양)
                band = neckHeight
                let height = band + M.stripHeight
                layout = IslandLayout(
                    size: CGSize(width: width, height: height),
                    origin: CGPoint(x: originX, y: 0),
                    shape: IslandShapeSpec(
                        neckLeft: earL, neckRight: earR, neckHeight: band,
                        bodyLeft: earL + left, bodyRight: earR + right,
                        leftEar: earL, rightEar: earR,
                        bodyTopRadius: 6, shoulderRadius: 12, bottomRadius: M.stripHeight / 2
                    ),
                    compact: .wings(spec)
                )
                layout.hitRects = [
                    CGRect(x: earL, y: 0, width: left + notchWidth + right, height: band),
                    CGRect(x: earL + left, y: band, width: notchWidth, height: M.stripHeight),
                ]
            } else {
                band = geometry.headerHeight
                layout = IslandLayout(
                    size: CGSize(width: width, height: band),
                    origin: CGPoint(x: originX, y: 0),
                    shape: IslandShapeSpec(
                        neckLeft: earL, neckRight: earR, neckHeight: band,
                        leftEar: earL, rightEar: earR, bottomRadius: isIdle ? 10 : 12
                    ),
                    compact: .wings(spec)
                )
                layout.hitRects = [CGRect(x: earL, y: 0, width: left + notchWidth + right, height: band)]
            }
            layout.holes = spec.holes.map { $0.offsetBy(dx: -originX, dy: 0) }
            layout.passThroughRects = C.passThrough(layout.holes, bandHeight: band)
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
        // 넓은 노치면 접힌 날개처럼 목(메뉴바 높이)도 메뉴바 아이템 위로 넓힌다.
        // 아이콘 위치를 알면 목은 아이콘 앞에서 멈춘다 (카드 상단 행이 아이콘을 덮지 않게)
        let free: (left: CGFloat, right: CGFloat)
        if cutsIconHoles {
            let limit = wingLimit
            free = (
                min(limit.left, max(0, C.room(leftItems) - 4)),
                min(limit.right, max(0, C.room(rightItems) - 4))
            )
        } else {
            free = usesWings ? wingLimit : notchFree
        }
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
