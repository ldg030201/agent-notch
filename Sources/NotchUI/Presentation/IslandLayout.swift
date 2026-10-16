import AppKit
import SwiftUI
import NotchCore

// MARK: - 레이아웃 결과

/// 접힌 상태 표시 방식 (뷰가 그대로 따라 그린다)
enum CompactVariant: Equatable {
    /// 노치 양옆 날개 (폭 · 요소 · 비켜준 쪽)
    case wings(WingsSpec)
    /// 노치 바로 아래로 내린 띠 (요소는 알약과 같은 규칙으로 고른다: `IslandLayoutEngine.stripItems`)
    case strip(items: CompactItems)
    /// 노치 아래 가장자리의 상태 색 선
    case line
    /// 알약 (메뉴바 안 또는 메뉴바 아래)
    case pill(items: CompactItems)
    /// 메뉴바 안 점
    case dot
}

extension CompactVariant {
    /// 모양 갈래. 같은 갈래끼리만 같은 부분 1 자리로 본다
    enum ShapeKind: Equatable { case wings, strip, line, pill, dot }

    var shapeKind: ShapeKind {
        switch self {
        case .wings: return .wings
        case .strip: return .strip
        case .line: return .line
        case .pill: return .pill
        case .dot: return .dot
        }
    }
}

/// 접힌 상태에 넣을 선택 요소 (상태 아이콘과 `+N −M`/상태 문구는 항상 표시)
struct CompactItems: OptionSet, Hashable {
    let rawValue: Int
    static let project = CompactItems(rawValue: 1 << 0)
    static let tool = CompactItems(rawValue: 1 << 1)
    /// 다른 세션 상태 요약 ("● 2")
    static let summary = CompactItems(rawValue: 1 << 2)
    /// 양쪽 날개에서 요약을 오른쪽 날개(`+N −M` 앞)에 둔다. 없으면 왼쪽 날개(프로젝트명 뒤)
    static let summaryTrailing = CompactItems(rawValue: 1 << 3)
    static let all: CompactItems = [.project, .tool]
}

/// 카드 상단 행 자리 (프레임 기준). 늘 부분 2(몸통) 안, 부분 1(접힌 모양) 아래다
struct HeaderSlot: Equatable {
    var top: CGFloat = 0
    var height: CGFloat = 0
    /// 몸통 왼쪽 · 오른쪽 여백 (프레임이 몸통보다 넓을 때). 본문도 같은 여백을 쓴다
    var leftInset: CGFloat = 0
    var rightInset: CGFloat = 0
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

    /// 그릴 모양 (패널 기준 원점을 함께 넣어 노치 보호를 프레임 위치와 같은 곡선으로 맞춘다)
    var shapeSpec: IslandShapeSpec {
        var spec = shape
        spec.originX = origin.x
        spec.originY = origin.y
        spec.frameWidth = size.width
        spec.frameHeight = size.height
        return spec
    }

    /// 애니메이션을 걸 값: 보이는 것만 (클릭 영역만 바뀐 경우엔 애니메이션하지 않는다)
    var animationKey: IslandLayout {
        var key = self
        key.hitRects = []
        return key
    }

    /// 본문 시작 y (상단 행 바로 아래)
    var contentTop: CGFloat { header.top + header.height }
    /// 본문 왼쪽/오른쪽 여백 (부분 1 · 귀 때문에 프레임이 몸통보다 넓을 때)
    var contentLeftInset: CGFloat { header.leftInset }
    var contentRightInset: CGFloat { header.rightInset }

    /// 패널(화면 맨 위) 기준 사각형 (원점 왼쪽 위)
    var panelRect: CGRect { CGRect(origin: origin, size: size) }

    /// 클릭 영역 (패널 기준)
    var panelHitRects: [CGRect] { hitRects.map { $0.offsetBy(dx: origin.x, dy: origin.y) } }

    /// 노치 아래 띠를 두 줄 높이로 잡았는지 (백그라운드 배지 · 요약이 제목 줄에 함께 안 들어감, `IslandLayoutEngine.stripHeight`).
    /// 두 줄이면 배지 · 요약은 둘째 줄이다
    var hasTwoLineStrip: Bool {
        size.height - shape.neckHeight > IslandMetrics.stripHeight + 1
    }
}

// MARK: - 접힌 상태 내용 크기

/// 접힌 상태에 보여줄 내용과 텍스트 폭 (레이아웃 선택용)
enum CompactContent: Equatable {
    /// 작업 중인 세션 없음: 모든 세션 상태 요약 (`content` = 요약 폭)
    case idle(content: CGFloat)
    case session(CompactMetrics)
}

struct CompactMetrics: Equatable {
    var project: CGFloat
    /// 짧은 툴 이름 폭 (`IslandFormat.shortToolTitle`, 예: "Bash"). 접힌 상태는 어디서나 이 이름만 쓴다
    var tool: CGFloat
    /// `+N −M` 또는 상태 문구 (없으면 0, 백그라운드 배지는 `badge`)
    var trailing: CGFloat
    /// 백그라운드 작업 배지 "⧉ N" 폭 (없으면 0). 날개 · 한쪽 날개 · 알약은 `trailing` 끝에 붙이고(`trailingWithBadge`),
    /// 노치 아래 띠는 제목 줄에 함께 안 들어가면 둘째 줄로 내린다 (제목 줄 요소는 배지 없이 고른다)
    var badge: CGFloat
    /// 다른 세션 상태 요약 폭 (다른 세션이 없으면 0). 숫자는 고정폭이라 한 자리 안에서 바뀌면 폭이 같다
    var summary: CGFloat
    /// 상태 문구(승인 필요 등)를 보여주는 단계라 툴 이름이 없는지
    var isAttention: Bool

    init(project: CGFloat, tool: CGFloat, trailing: CGFloat, badge: CGFloat = 0, summary: CGFloat = 0, isAttention: Bool) {
        self.project = project
        self.tool = tool
        self.trailing = trailing
        self.badge = badge
        self.summary = summary
        self.isAttention = isAttention
    }

    /// - summary: 접힌 상태의 세션 상태 요약 (`PresentationController.compactSummary`)
    @MainActor
    init(session: AgentSession, summary: SessionStatusSummary = .empty) {
        let attention = CompactText.attentionText(session)
        badge = CompactText.backgroundBadgeWidth(session.backgroundTaskCount)
        self.summary = CompactText.summaryWidth(summary)
        project = CompactText.width(session.projectName, font: IslandFont.bodyNS)
        if let attention {
            tool = 0
            trailing = CompactText.width(attention.text, font: IslandFont.bodyNS)
            isAttention = true
        } else {
            tool = CompactText.width(IslandFormat.shortToolTitle(session), font: IslandFont.bodyNS)
            trailing = CompactText.statWidth(added: session.turn.added, removed: session.turn.removed)
            isAttention = false
        }
    }

    /// `+N −M`(또는 상태 문구) 끝에 백그라운드 배지까지 한 줄로 이은 폭 (`CompactSessionView.trailing` 뷰)
    var trailingWithBadge: CGFloat { CompactText.joined(trailing, badge) }
}

/// 접힌 상태 문구 측정 · 결정 (뷰와 레이아웃이 같은 규칙을 쓴다)
enum CompactText {
    enum Tone { case amber, red, muted }

    /// 작업 중이 아닌 단계의 상태 문구 (승인 필요 등). 작업 중이면 nil.
    /// 쉬는 세션은 고정했을 때만 접힌 상태에 보인다: 지난 턴의 `+N −M` 대신 "유휴" (백그라운드 작업이 돌면 배지만)
    static func attentionText(_ session: AgentSession) -> (text: String, tone: Tone)? {
        switch session.phase {
        case .waitingPermission: return ("승인 필요", .amber)
        case .waitingInput: return ("입력 필요", .amber)
        case .failed: return ("실패", .red)
        case .completed: return ("완료", .muted)
        case .idle where session.backgroundTaskCount == 0: return ("유휴", .muted)
        default: return nil
        }
    }

    /// 글자 폭 (올림). 레이아웃 · 뷰 계산마다 같은 글자를 다시 재지 않게 글꼴 · 글자별로 기억한다
    @MainActor
    static func width(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let key = WidthKey(font: font, text: text)
        if let cached = widthCache[key] { return cached }
        let measured = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        if widthCache.count >= widthCacheLimit { widthCache.removeAll(keepingCapacity: true) }
        widthCache[key] = measured
        return measured
    }

    private struct WidthKey: Hashable {
        var font: NSFont
        var text: String
    }

    @MainActor private static var widthCache: [WidthKey: CGFloat] = [:]
    /// 기억하는 글자 수 상한 (넘으면 비우고 다시 모은다)
    private static let widthCacheLimit = 256

    /// `+N −M` 폭 (둘 다 0 이면 표시 안 함)
    @MainActor
    static func statWidth(added: Int, removed: Int) -> CGFloat {
        guard added > 0 || removed > 0 else { return 0 }
        return width("+\(added)", font: IslandFont.monoNS) + 4 + width("\u{2212}\(removed)", font: IslandFont.monoNS)
    }

    /// 백그라운드 작업 배지 폭: 아이콘 칸 + 숫자 (0 이면 표시 안 함). 요약처럼 자릿수로만 정해진다
    static func backgroundBadgeWidth(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        typealias M = IslandMetrics
        return ceil(M.backgroundIconSize + M.backgroundIconGap + CGFloat(String(count).count) * summaryDigitWidth)
    }

    /// 한 줄에 이어 붙인 두 요소 폭 (`trailing` 뷰의 사이 간격 6)
    static func joined(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        first > 0 && second > 0 ? first + IslandMetrics.backgroundLead + second : first + second
    }

    /// 요약 숫자 한 자리 폭 (고정폭 숫자 11pt)
    static let summaryDigitWidth: CGFloat = ceil(("0" as NSString).size(withAttributes: [.font: IslandFont.summaryCountNS]).width * 2) / 2

    /// 세션 상태 요약 폭: 묶음마다 점 + 숫자 (자릿수로만 정해지므로 1 → 2 처럼 한 자리 안의 변화는 폭이 같다). 비었으면 0
    static func summaryWidth(_ summary: SessionStatusSummary) -> CGFloat {
        let groups = summary.groups
        guard !groups.isEmpty else { return 0 }
        typealias M = IslandMetrics
        var width = CGFloat(groups.count - 1) * M.summaryGroupSpacing
        for item in groups {
            width += M.summaryDotSize + M.summaryDotGap + CGFloat(String(item.count).count) * summaryDigitWidth
        }
        return ceil(width)
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

extension CompactPlacement {
    /// 로그용 자리 종류 (숫자 · 내용 없이)
    var kindName: String {
        switch self {
        case let .wings(spec): return "wings-\(spec.arrangement)"
        case .strip: return "strip"
        case .line: return "line"
        case .menuBarPill: return "menuBarPill"
        case .menuBarDot: return "menuBarDot"
        case .belowMenuBarPill: return "belowMenuBarPill"
        case .none: return "none"
        }
    }
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
    /// 넓은 노치에서 마우스를 올려 비켜준 날개
    var retracted: WingSides = []
    /// 직전에 그린 접힌 날개 (배치 이력: 다른 배치 · 더 많은 요소로 바꿀 때 여유를 더 요구하고, 펼친 카드 띠가 이어받는다)
    var previousWings: WingsSpec?
    /// 직전에 그린 메뉴바 알약 (노치 없는 화면). 펼친 카드는 이 알약을 부분 1 로 삼아, 펼치고 접는 동안 알약이 그대로 있다
    var previousPill: CompactPlacement?
    /// 카드를 접는 동안 붙잡는 카드 띠 · 목 알약 (`cardBand(for:)`). 있으면 접힌 자리를 이것으로 그린다
    var collapseHold: CompactPlacement?
    /// 직전에 그린 부분 1 (접힌 모양 또는 열린 카드의 부분 1). 펼친 카드 · 접히는 동안의 접힌 상태는 자리가 같으면 이 모양을 그대로 쓴다
    /// (카드가 열려 있는 동안 접힌 내용이 바뀌어 아래 반경 · 띠 높이가 달라져도 부분 1 이 그대로)
    var previousPart1: IslandLayout?

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

    /// 넓은 노치(날개) 방식을 쓰는지. 다른 노치 앱이 있으면 노치 아래 방식으로 물러난다.
    /// 날개는 메뉴바 아이콘을 덮고, 마우스를 올리면 비켜준다 (`retracted`).
    var usesWings: Bool { geometry.hasNotch && notchStyle == .wings && !notchConflict }

    /// 넓은 노치: 한쪽 날개가 쓸 수 있는 최대 폭.
    /// 메뉴바 아이템 · 앱 메뉴가 있어도 덮으므로 화면의 노치 옆 영역까지 쓴다.
    var wingLimit: (left: CGFloat, right: CGFloat) {
        (max(0, notchMinX - M.menuBarMargin), max(0, screenWidth - notchMaxX - M.menuBarMargin))
    }

    /// 앱 메뉴 끝 추정값: 앱 메뉴는 잴 수 없어서 화면 폭의 45%(최대 900pt)까지 차 있다고 본다
    static func estimatedAppMenuEnd(screenWidth: CGFloat) -> CGFloat {
        min(screenWidth * 0.45, 900)
    }

    /// 노치 없는 화면: 앱 메뉴 끝(추정) ~ 상태 아이템 시작 구간 (여백 미포함)
    var menuBarGap: (start: CGFloat, end: CGFloat)? {
        let appEnd = Self.estimatedAppMenuEnd(screenWidth: screenWidth)
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
        let fresh = geometry.hasNotch ? notchPlacement(content) : externalPlacement(content)
        return heldCollapsePlacement(fresh: fresh, content: content) ?? fresh
    }

    /// 카드를 접는 동안 붙잡은 카드 띠 · 목 알약 (`collapseHold`). 아직 메뉴바에 맞으면 그 자리, 아니면 nil (지금 자리).
    /// 카드가 열려 있는 동안 접힌 내용이 바뀌었어도 접히는 동안엔 띠 · 알약이 그대로이고, 몸통만 그 안으로 줄어든다
    /// (알약 요소는 붙잡은 폭에 지금 내용으로 고른다). 바뀌는 것은 놓은 뒤 접힌 상태 안의 변화(몸통 = 띠라 이음매 없음)로 일어난다
    private func heldCollapsePlacement(fresh: CompactPlacement, content: CompactContent) -> CompactPlacement? {
        guard let held = collapseHold, held != fresh else { return nil }
        /// 붙잡은 알약 폭에 넣을 지금 내용의 요소
        func pillItems(width: CGFloat) -> CompactItems {
            guard case let .session(metrics) = content else { return .all }
            return Self.pillItems(metrics, width: width)
        }
        switch (held, fresh) {
        case let (.wings(spec), .wings(freshSpec)):
            // 마우스를 올려 비켜주는 쪽은 바로 따른다
            var kept = spec
            kept.hidden = freshSpec.hidden
            // 띠 양끝이 같으면 지금 자리 (요소만 바뀐 것은 붙잡지 않는다)
            let sameBand = abs(kept.visibleLeft - freshSpec.visibleLeft) < 0.25 && abs(kept.visibleRight - freshSpec.visibleRight) < 0.25
            guard !sameBand, bandStillFits(spec) else { return nil }
            return .wings(kept)
        case let (.wings(spec), .strip), let (.wings(spec), .line):
            return bandStillFits(spec) ? held : nil
        case (.strip, .wings), (.line, .wings):
            // 카드 띠가 노치 폭이었다: 노치 아래 띠 · 선으로 접는다
            return held
        case let (.menuBarPill(centerX, width, _), .menuBarPill):
            guard pillStillFits(centerX: centerX, width: width) else { return nil }
            return .menuBarPill(centerX: centerX, width: width, items: pillItems(width: width))
        case let (.belowMenuBarPill(width, _), .belowMenuBarPill):
            return .belowMenuBarPill(width: width, items: pillItems(width: width))
        default:
            return nil
        }
    }

    /// 노치 화면: 넓은 노치면 날개, 아니면(노치 아래 방식 · 다른 노치 앱 · 날개가 안 들어감) 노치 아래 띠 또는 선
    private func notchPlacement(_ content: CompactContent) -> CompactPlacement {
        if usesWings, let placement = wingsPlacement(content) { return placement }
        switch overlapStyle {
        case .belowNotch: return .strip(width: notchWidth)
        case .minimal: return .line
        }
    }

    // MARK: 배치 이력 (출렁임 방지)

    /// 직전과 다른 배치(날개 쪽 · 더 많은 요소)로 바꾸려면 문턱보다 이만큼 더 여유가 있어야 한다.
    /// 내용 폭이 문턱 근처를 오가도 배치가 뒤집히지 않는다.
    /// 판단에만 쓰고 폭은 늘 실제 여유로 계산한다 (바꾼 다음 계산에서 폭이 한 번 더 바뀌지 않게).
    static let arrangementHysteresis: CGFloat = 8

    /// 직전과 다른 배치로 바꿀 때 더 필요한 여유 (직전 날개를 모르면 0)
    private func entryMargin(_ arrangement: WingArrangement) -> CGFloat {
        guard let previous = previousWings, previous.arrangement != arrangement else { return 0 }
        return Self.arrangementHysteresis
    }

    /// 같은 배치에서 직전보다 요소를 더 넣을 때 더 필요한 여유
    private func itemEntryMargin(_ items: CompactItems, arrangement: WingArrangement) -> CGFloat {
        guard let previous = previousWings, previous.arrangement == arrangement,
              items.isStrictSuperset(of: previous.items)
        else { return 0 }
        return Self.arrangementHysteresis
    }

    // MARK: 다른 세션 요약 자리 (양쪽 날개)

    /// 양쪽 날개에 둘 요소와 쪽마다 필요한 폭
    struct SplitPlan: Equatable {
        var items: CompactItems
        var left: CGFloat
        var right: CGFloat
    }

    /// 양쪽 날개에 필요한 폭: 왼쪽 = 상태 + 프로젝트 (+ 요약), 오른쪽 = (요약 + 8pt 이상 +) (툴 +) `+N −M`
    /// (오른쪽 요약은 노치 쪽에 고정, 나머지는 바깥 끝).
    /// 바깥 여백 · 안쪽 4pt · SwiftUI 배치 오차 8pt 포함 (CompactWings · CompactSessionView 배치와 같은 순서)
    static func splitNeed(
        _ metrics: CompactMetrics,
        items: CompactItems,
        project: CGFloat,
        tool: CGFloat,
        leftPad: CGFloat,
        rightPad: CGFloat
    ) -> SplitPlan {
        let summary = items.contains(.summary) ? metrics.summary : 0
        let summaryLeft = summary > 0 && !items.contains(.summaryTrailing)
        let shownProject = items.contains(.project) ? project : 0
        var left = leftPad + 14 + (shownProject > 0 ? 6 + shownProject : 0) + 4 + 8
        if summaryLeft { left += M.summaryLead + summary }
        let trailing = metrics.trailingWithBadge
        var rightText = trailing
        let shownTool = items.contains(.tool) ? tool : 0
        if shownTool > 0 { rightText += shownTool + (trailing > 0 ? 6 : 0) }
        if summary > 0, !summaryLeft { rightText += summary + (rightText > 0 ? M.summaryLead : 0) }
        return SplitPlan(items: items, left: left, right: 4 + rightText + rightPad + 8)
    }

    /// 다른 세션 요약을 넣는 양쪽 날개 후보 (앞에서부터 고른다, 요약이 없으면 빈 목록).
    /// 왼쪽 프로젝트명 뒤 → 오른쪽 `+N −M` 앞 → 오른쪽 + 툴 이름 뺌 → 왼쪽 + 프로젝트명 줄임 → 왼쪽 + 프로젝트명 뺌.
    /// 툴 이름 → 프로젝트명 순으로 줄이고 요약은 끝까지 남긴다 (칩을 반만 자르지 않게 통째로 넣을 자리만 고른다).
    static func splitPlans(
        _ metrics: CompactMetrics,
        project: CGFloat,
        tool: CGFloat,
        leftPad: CGFloat,
        rightPad: CGFloat
    ) -> [SplitPlan] {
        guard metrics.summary > 0 else { return [] }
        func need(_ items: CompactItems, project shown: CGFloat = project) -> SplitPlan {
            splitNeed(metrics, items: items, project: shown, tool: tool, leftPad: leftPad, rightPad: rightPad)
        }
        var plans = [need([.project, .tool, .summary]), need([.project, .tool, .summary, .summaryTrailing])]
        if tool > 0 { plans.append(need([.project, .summary, .summaryTrailing])) }
        if project > Self.shortProjectWidth { plans.append(need([.project, .tool, .summary], project: Self.shortProjectWidth)) }
        plans.append(need([.tool, .summary]))
        return plans
    }

    /// 요약 자리가 모자랄 때 줄인 프로젝트명 폭
    static let shortProjectWidth: CGFloat = 40

    /// 양쪽 날개 후보 중 처음으로 들어가는 것.
    /// 직전 양쪽 날개보다 요소를 더 넣거나 요약을 반대쪽으로 옮길 땐 여유가 더 있어야 한다 (폭이 조금씩 바뀌어도 오가지 않게)
    private func firstFittingPlan(_ plans: [SplitPlan], caps: (left: CGFloat, right: CGFloat)) -> SplitPlan? {
        let previous = previousWings?.arrangement == .split ? previousWings?.items : nil
        return plans.first { plan in
            var extra: CGFloat = 0
            if let previous {
                let added = plan.items.subtracting(previous).subtracting(.summaryTrailing)
                let moved = plan.items.contains(.summary) && previous.contains(.summary)
                    && plan.items.contains(.summaryTrailing) != previous.contains(.summaryTrailing)
                if !added.isEmpty || moved { extra = Self.arrangementHysteresis }
            }
            return plan.left + extra <= caps.left + 0.5 && plan.right + extra <= caps.right + 0.5
        }
    }

    /// 넓은 노치: 양쪽 날개 (목업 기본형). 그것도 안 되면 nil (노치 아래 방식).
    /// 날개는 메뉴바 아이콘을 덮고, 마우스를 올린 쪽(`retracted`)은 비켜준다.
    private func wingsPlacement(_ content: CompactContent) -> CompactPlacement? {
        guard let base = baseWings(content) else { return nil }
        return .wings(.plain(left: base.left, right: base.right, items: base.items, hidden: retracted))
    }

    /// 넓은 노치 기본 폭: 내용에 맞추되 한쪽 `wideWingMax` 이하, 노치를 가운데 두도록 양쪽을 같게.
    /// 왼쪽이 모자라면 왼쪽 날개를 없애고 내용을 오른쪽 날개에 모은다.
    private func baseWings(_ content: CompactContent) -> (left: CGFloat, right: CGFloat, items: CompactItems)? {
        let limit = wingLimit
        switch content {
        case let .idle(dots):
            let both = max(28, dots + M.wingPadding + 8)
            if limit.left >= both, limit.right >= both { return (both, both, .all) }
            let single = dots + M.wingPadding + 6
            if limit.right >= single { return (0, single, []) }

        case let .session(metrics):
            let pad = M.wingPadding
            let project = min(metrics.project, M.wideWingProjectCap)
            let tool = metrics.isAttention ? 0 : min(metrics.tool, M.wideWingToolCap)
            // 왼쪽: 상태 + 프로젝트명, 오른쪽: 툴 + `+N −M` (또는 상태 문구). SwiftUI 배치 오차 8pt 여유.
            let plain = Self.splitNeed(metrics, items: .all, project: project, tool: tool, leftPad: pad, rightPad: pad)
            var wing = min(max(plain.left, plain.right, M.minWideWing), M.wideWingMax)
            var items = CompactItems.all
            // 다른 세션 요약: 날개를 `summaryWingGrowth` 까지 넓혀 넣는다 (툴 이름 → 프로젝트명 순으로 줄임)
            if metrics.summary > 0 {
                let cap = M.wideWingMax + M.summaryWingGrowth
                let plans = Self.splitPlans(metrics, project: project, tool: tool, leftPad: pad, rightPad: pad)
                if let plan = firstFittingPlan(plans, caps: (min(cap, limit.left), min(cap, limit.right))) {
                    items = plan.items
                    wing = max(wing, plan.left, plan.right)
                }
            }
            let both = (wing / 4).rounded(.up) * 4
            // 프로젝트명은 줄일 수 있으니 왼쪽은 앞 몇 글자만 들어가도 된다
            let leftMin = pad + 14 + 6 + min(project, Self.shortProjectWidth) + 4
            let margin = entryMargin(.split)
            if limit.left >= leftMin + margin, limit.right >= min(both, plain.right) {
                return (min(both, limit.left), min(both, limit.right), items)
            }
            if let wing = singleWing(available: limit.right, metrics, arrangement: .right) {
                return (0, wing.width, wing.items)
            }
        }
        return nil
    }

    /// 넓은 노치에서 마우스를 올리면 비켜줄 날개 자리 (패널 기준, 지금 그린 접힌 자리 `placement` 의 날개).
    /// 날개가 메뉴바 아이콘을 덮으므로 날개마다 있다
    func retractBands(for placement: CompactPlacement) -> WingBands {
        guard usesWings, case let .wings(spec) = placement else { return .none }
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

    /// 날개 하나에 모을 때 폭과 요소.
    /// 같은 쪽에서 직전보다 요소를 더 넣으려면 여유가 더 있어야 한다 (`itemEntryMargin`)
    private func singleWing(
        available: CGFloat,
        _ metrics: CompactMetrics,
        arrangement: WingArrangement
    ) -> (width: CGFloat, items: CompactItems)? {
        let cap = min(available, M.maxSingleWing)
        for variant in Self.singleVariants(metrics) {
            // SwiftUI 실제 배치가 측정값보다 조금 넓게 잡히는 것을 감안해 8pt 여유
            let need = M.wingPadding + 6 + 8 + Self.contentWidth(
                metrics, items: variant.items, toolWidth: metrics.tool, toolCap: 90, projectCap: variant.projectCap
            )
            if need + itemEntryMargin(variant.items, arrangement: arrangement) <= cap {
                return (min(cap, (need / 8).rounded(.up) * 8), variant.items)
            }
        }
        return nil
    }

    /// 한 줄(날개 하나)에 넣을 요소 후보 (앞에서부터 고른다).
    /// - 요약 없음: 프로젝트명 → 툴 이름 순으로 생략 (상태 문구를 보여줄 땐 툴 이름이 없다)
    /// - 요약 있음: 툴 이름 → 프로젝트명(줄임 → 뺌) 순으로 생략하고 요약은 끝까지 남긴다
    static func singleVariants(_ metrics: CompactMetrics) -> [(items: CompactItems, projectCap: CGFloat)] {
        typealias Variant = (items: CompactItems, projectCap: CGFloat)
        let full: CGFloat = 110
        let none: CompactItems = []
        guard metrics.summary > 0 else {
            let plain: [Variant] = metrics.isAttention
                ? [(CompactItems.project, full), (none, 0)]
                : [(CompactItems.all, full), (CompactItems.tool, full), (none, 0)]
            return plain
        }
        let withSummary: CompactItems = [.project, .summary]
        var variants: [Variant] = []
        if !metrics.isAttention { variants.append((withSummary.union(.tool), full)) }
        variants.append((withSummary, full))
        variants.append((withSummary, shortProjectWidth))
        variants.append((CompactItems.summary, 0))
        variants.append((none, 0))
        return variants
    }

    /// 상태 아이콘 + 선택 요소 + `+N −M` 폭 (한 줄: 상태 · 프로젝트 · 요약 · 툴 · `+N −M` · 백그라운드 배지)
    static func contentWidth(
        _ metrics: CompactMetrics,
        items: CompactItems,
        toolWidth: CGFloat,
        toolCap: CGFloat,
        projectCap: CGFloat = 110
    ) -> CGFloat {
        var width: CGFloat = 14
        if items.contains(.project) { width += 6 + min(metrics.project, projectCap) }
        if items.contains(.summary), metrics.summary > 0 { width += M.summaryLead + metrics.summary }
        if items.contains(.tool), toolWidth > 0 { width += 6 + min(toolWidth, toolCap) }
        if metrics.trailingWithBadge > 0 { width += 6 + metrics.trailingWithBadge }
        return width
    }

    /// 노치 아래 띠 높이: 백그라운드 배지 · 요약(고른 요소 `stripItems` 에 있을 때)이 제목 줄에 함께 안 들어가면 두 줄로
    /// (폭은 늘 노치 폭, `stripWraps`)
    func stripHeight(for content: CompactContent) -> CGFloat {
        guard case let .session(metrics) = content, metrics.summary > 0 || metrics.badge > 0 else { return M.stripHeight }
        let items = Self.stripItems(metrics, width: notchWidth)
        return Self.stripWraps(metrics, items: items, width: notchWidth) ? M.stripHeight + M.stripSecondLineHeight : M.stripHeight
    }

    /// 노치 아래 띠에 넣을 요소 (접힌 내용이 세션일 때만, 아니면 빈 값)
    func stripItems(for content: CompactContent) -> CompactItems {
        guard case let .session(metrics) = content else { return [] }
        return Self.stripItems(metrics, width: notchWidth)
    }

    private func externalPlacement(_ content: CompactContent) -> CompactPlacement {
        switch externalStyle {
        case .hidden:
            return .none
        case .belowMenuBar:
            switch content {
            case let .idle(dots): return .belowMenuBarPill(width: dots + 28, items: .all)
            case let .session(metrics):
                // 폭은 늘 같고, 넘치는 제목은 줄인다 (요소는 메뉴바 안 알약과 같은 규칙)
                return .belowMenuBarPill(width: M.pillWorkingWidth, items: Self.pillItems(metrics, width: M.pillWorkingWidth))
            }
        case .inMenuBar:
            guard let range = menuBarPillRange else { return .none }
            let gapRoom = range.hi - range.lo
            if gapRoom < M.minMenuBarPill {
                return gapRoom >= M.menuBarDotSize ? .menuBarDot(centerX: ((range.lo + range.hi) / 2).rounded()) : .none
            }
            switch content {
            case let .idle(dots):
                let width = min(dots + 28, gapRoom)
                return .menuBarPill(centerX: pillCenter(width: width, in: range), width: width, items: .all)
            case let .session(metrics):
                let full = Self.pillNeed(metrics, items: Self.pillVariants(metrics)[0])
                let desired = min(max((full / 20).rounded(.up) * 20, 120), M.pillWorkingWidth)
                let width = min(desired, gapRoom).rounded(.down)
                return .menuBarPill(
                    centerX: pillCenter(width: width, in: range), width: width, items: Self.pillItems(metrics, width: width)
                )
            }
        }
    }

    /// 메뉴바 안 알약을 둘 수 있는 가로 구간 (빈 구간에서 양쪽 여백을 뺀 것). 메뉴바가 숨었거나 빈 구간이 없으면 nil
    private var menuBarPillRange: (lo: CGFloat, hi: CGFloat)? {
        guard menuBarVisible, let gap = menuBarGap else { return nil }
        let lo = gap.start + M.menuBarMargin
        let hi = gap.end - M.menuBarMargin
        return hi > lo ? (lo, hi) : nil
    }

    /// 폭 `width` 알약의 가운데 x.
    /// 화면 가운데가 빈 구간 안이면 화면 가운데에 두되, 가운데로는 자리가 모자라면 빈 구간 안으로 들어올 만큼만 민다.
    /// 화면 가운데가 빈 구간 밖이면 빈 구간 가운데
    private func pillCenter(width: CGFloat, in range: (lo: CGFloat, hi: CGFloat)) -> CGFloat {
        let gapCenter = ((range.lo + range.hi) / 2).rounded()
        let margin = M.menuBarMargin
        guard midX > range.lo - margin, midX < range.hi + margin else { return gapCenter }
        let lower = (range.lo + width / 2).rounded(.up)
        let upper = (range.hi - width / 2).rounded(.down)
        guard lower <= upper else { return gapCenter }
        return min(max(midX, lower), upper)
    }

    /// 직전 알약(가운데 · 폭)이 지금 메뉴바에서도 그 폭 알약이 놓일 자리 그대로인지
    private func pillStillFits(centerX: CGFloat, width: CGFloat) -> Bool {
        guard let range = menuBarPillRange else { return false }
        return width <= range.hi - range.lo + 0.5 && abs(centerX - pillCenter(width: width, in: range)) < 0.5
    }

    // MARK: 한 줄 내용 요소 (알약 · 노치 아래 띠가 같은 규칙)

    /// 한 줄 내용(상태 + 프로젝트명 · 툴 이름 + `+N −M` + 백그라운드 배지 + 요약)의 틀. 알약과 노치 아래 띠는 틀만 다르고
    /// 요소 후보(`pillVariants`) · 빼는 순서 · 제목 최소 폭(`pillProjectMin` · `pillToolMin`)은 같다
    struct LineChrome: Equatable {
        /// 좌우 여백 + 상태 아이콘 (+ 배치 오차)
        var base: CGFloat
        /// 상태 아이콘 · 제목 · `+N −M` 사이 간격
        var spacing: CGFloat
        /// 요약 앞 간격(`summaryLead`) 밖에 더 잡는 폭
        var summaryExtra: CGFloat
        /// 백그라운드 배지 · 요약이 제목 줄에 안 들어가면 둘째 줄로 내릴 수 있는지 (노치 아래 띠).
        /// 그러면 제목 줄 요소는 배지 · 요약 없이 고른다 (알약이 같은 내용에 배지 없이 고르는 것과 같은 요소)
        var wraps: Bool

        /// 알약: 좌우 여백 12 · 상태 아이콘 · 간격 6. 요약은 `Spacer` 뒤에 붙어 8pt 더
        static let pill = LineChrome(base: 24 + 12, spacing: 6, summaryExtra: 8, wraps: false)
        /// 노치 아래 띠: 좌우 여백 10 · 상태 12 · 간격 5 · 배치 오차 4. 배지 · 요약은 둘째 줄로 내릴 수 있다
        static let strip = LineChrome(base: 20 + 12 + 4, spacing: 5, summaryExtra: 0, wraps: true)
    }

    /// 알약 · 노치 아래 띠에 넣을 요소 후보 (앞에서부터 고른다).
    /// 요약이 없으면 프로젝트명 → 툴 이름 순으로, 요약이 있으면 툴 이름 → 프로젝트명 순으로 빼고 요약은 끝까지 남긴다.
    /// 요약이 없을 때 툴 이름이 줄여도 안 들어가면 그보다 짧게 줄일 수 있는 프로젝트명이라도 남긴다 (상태 아이콘만 남지 않게)
    static func pillVariants(_ metrics: CompactMetrics) -> [CompactItems] {
        guard metrics.summary > 0 else { return [.all, [.tool], [.project], []] }
        return [[.project, .tool, .summary], [.project, .summary], [.summary], []]
    }

    /// 제목을 줄일 수 있는 최소 폭: 프로젝트명(끝 줄임) · 툴 이름(가운데 줄임).
    /// 뷰(`PillTitleLayout`)는 빼는 순서와 같은 쪽을 먼저 이만큼까지 줄이고, 그래도 모자라면 다른 쪽을 줄인다
    static let pillProjectMin: CGFloat = 40
    static let pillToolMin: CGFloat = 64

    /// 폭 `width` 알약에 넣을 요소 (`lineItems`)
    static func pillItems(_ metrics: CompactMetrics, width: CGFloat) -> CompactItems {
        lineItems(metrics, width: width, chrome: .pill)
    }

    /// 폭 `width`(노치 폭) 노치 아래 띠에 넣을 요소: 알약과 같은 규칙 (백그라운드 배지 · 요약은 둘째 줄로 내릴 수 있어 빼고 고른다)
    static func stripItems(_ metrics: CompactMetrics, width: CGFloat) -> CompactItems {
        lineItems(metrics, width: width, chrome: .strip)
    }

    /// 한 줄 내용에 넣을 요소: 제목을 줄일 수 있는 만큼 줄여서라도 들어가는 첫 후보.
    /// 제목을 통째로 빼는 것은 최소 폭으로도 안 들어갈 때뿐이라, 제목이 들어갈 자리가 있으면 상태 아이콘만 남기지 않는다.
    /// 배지 · 요약을 둘째 줄로 내릴 수 있는 틀(노치 아래 띠)은 제목 줄(배지 · 요약 없이)만 들어가면 된다
    static func lineItems(_ metrics: CompactMetrics, width: CGFloat, chrome: LineChrome) -> CompactItems {
        pillVariants(metrics).first { items in
            let line = lineNeed(metrics, items: items, squeezed: true, chrome: chrome)
            if chrome.wraps { return line <= width }
            return line + summaryNeed(metrics, items: items, chrome: chrome) <= width
        } ?? []
    }

    /// 노치 아래 띠가 둘째 줄을 쓰는지: 줄이지 않은 제목 줄 + 백그라운드 배지 + 요약이 한 줄에 안 들어갈 때
    /// (제목을 배지 · 요약 때문에 줄이지 않게). 둘째 줄에는 배지와 요약을 함께 둔다
    static func stripWraps(_ metrics: CompactMetrics, items: CompactItems, width: CGFloat) -> Bool {
        let extra = badgeNeed(metrics, chrome: .strip) + summaryNeed(metrics, items: items, chrome: .strip)
        guard extra > 0 else { return false }
        return lineNeed(metrics, items: items, squeezed: false, chrome: .strip) + extra > width
    }

    /// 제목(프로젝트명 · 툴 이름) 폭. 둘 다면 사이 " · " 14pt.
    /// - squeezed: 최소 폭(`pillProjectMin` · `pillToolMin`)까지 줄였을 때
    static func titleWidth(_ metrics: CompactMetrics, items: CompactItems, squeezed: Bool) -> CGFloat {
        var text: CGFloat = 0
        if items.contains(.project), metrics.project > 0 {
            text += min(metrics.project, squeezed ? pillProjectMin : 110)
        }
        if items.contains(.tool), !metrics.isAttention, metrics.tool > 0 {
            text += (text > 0 ? 14 : 0) + min(metrics.tool, squeezed ? pillToolMin : 200)
        }
        return text
    }

    /// 한 줄 내용 폭 (요약 제외): 틀 + 제목 + `+N −M`(또는 상태 문구) + 백그라운드 배지.
    /// 배지를 둘째 줄로 내릴 수 있는 틀(노치 아래 띠)은 배지 없이 잰다 (제목 줄에 함께 두면 `badgeNeed` 만큼 더)
    static func lineNeed(_ metrics: CompactMetrics, items: CompactItems, squeezed: Bool, chrome: LineChrome) -> CGFloat {
        var width = chrome.base
        let text = titleWidth(metrics, items: items, squeezed: squeezed)
        if text > 0 { width += chrome.spacing + text }
        let trailing = chrome.wraps ? metrics.trailing : metrics.trailingWithBadge
        if trailing > 0 { width += chrome.spacing + trailing }
        return width
    }

    /// 배지를 둘째 줄로 내릴 수 있는 틀에서 배지를 제목 줄 끝에 함께 둘 때 더 필요한 폭 (아니면 0 — `lineNeed` 에 이미 있다).
    /// `+N −M`(또는 상태 문구)이 있으면 그 뒤 `backgroundLead`, 없으면 제목 뒤 틀 간격
    static func badgeNeed(_ metrics: CompactMetrics, chrome: LineChrome) -> CGFloat {
        guard chrome.wraps, metrics.badge > 0 else { return 0 }
        return (metrics.trailing > 0 ? M.backgroundLead : chrome.spacing) + metrics.badge
    }

    /// 요약 폭 (요소에 있고 다른 세션이 있을 때만): 앞 간격 + 칩 + 틀의 추가 폭
    static func summaryNeed(_ metrics: CompactMetrics, items: CompactItems, chrome: LineChrome) -> CGFloat {
        guard items.contains(.summary), metrics.summary > 0 else { return 0 }
        return M.summaryLead + metrics.summary + chrome.summaryExtra
    }

    /// 알약 내용 폭 (좌우 여백 12 포함). 프로젝트명 · 툴 이름을 한 줄로 이어 보여주고, 요약은 `+N −M` · 백그라운드 배지 뒤에 붙인다.
    /// - squeezed: 제목을 최소 폭(`pillProjectMin` · `pillToolMin`)까지 줄였을 때
    static func pillNeed(_ metrics: CompactMetrics, items: CompactItems, squeezed: Bool = false) -> CGFloat {
        lineNeed(metrics, items: items, squeezed: squeezed, chrome: .pill) + summaryNeed(metrics, items: items, chrome: .pill)
    }

    // MARK: 레이아웃

    // 접힌 모양은 목 + 몸통으로 만든다. 한 덩어리 모양은 몸통 = 목 폭, 몸통 높이 = 아래 반경.
    // 접힌 모양은 그대로 부분 1 (`IslandShapeSpec.part1`)이 되고, 펼친 카드는 부분 1 아래로 부분 2(몸통)를 내린다.
    // 펼치고 접는 동안 부분 1 은 접힌 모양 그대로다 (양 끝 값이 같다)

    /// 몸통 모서리: 노치 화면 접힌 모양 · 메뉴바 알약 · 점 · 펼친 카드가 같은 값을 쓴다.
    /// 노치 화면은 몸통이 목과 같은 폭이면 보이지 않고 카드로 넓어질 때 그대로 이어지며, 알약 · 점은 알약 카드 · 점 카드와 같아서
    /// 펼치고 접는 동안 이음매 반경이 0 에서 자라며 턱이 남지 않는다
    private static let bodyTopRadius: CGFloat = 14
    /// 노치 화면 접힌 모양 · 카드의 어깨 모서리
    private static let compactShoulderRadius: CGFloat = 10
    /// 메뉴바 알약 · 점의 어깨 모서리
    private static let pillShoulderRadius: CGFloat = 8

    /// 모든 레이아웃 공통 마무리: 하드웨어 노치 보호 · 메뉴바 아래 몸통
    private func finish(_ layout: IslandLayout) -> IslandLayout {
        var layout = layout
        if geometry.hasNotch {
            layout.shape.notchMinX = (screenWidth - notchWidth) / 2
            layout.shape.notchWidth = notchWidth
            layout.shape.notchHeight = geometry.notchSize.height
            // 몸통은 목 높이(메뉴바 · 노치 중 큰 쪽) 아래에서만 목보다 넓어진다
            layout.shape.menuBarBottom = neckHeight
        } else if menuBarVisible {
            // 노치 없는 화면도 메뉴바 안 알약 · 점에서 펼친 카드는 메뉴바 아래에서만 넓어진다
            layout.shape.menuBarBottom = menuBarHeight
        }
        return layout
    }

    /// 펼친 카드 몸통(부분 2) 어깨 모서리: 노치 화면 · 메뉴바 알약
    private var cardShoulderRadius: CGFloat { geometry.hasNotch ? Self.compactShoulderRadius : Self.pillShoulderRadius }

    /// 접힌 모양을 부분 1 로 기억시킨다: 부분 1 = 지금 모양 그대로 (패널 기준).
    /// 주 외곽선도 같은 치수라 부분 1 만 그린다. 카드로 펼치면 부분 2 는 부분 1 아래 모서리(`capRadius`) 안쪽에서 나온다
    private func asPart1(_ layout: IslandLayout) -> IslandLayout {
        var layout = layout
        let part1 = IslandPart1Spec(rect: layout.panelRect, shape: layout.shape)
        layout.shape.part1 = part1
        // 두 조각(노치 아래 띠)이면 위 조각(띠) 아래 볼록 모서리, 한 조각이면 아래 모서리
        layout.shape.capRadius = part1.isTwoPiece ? layout.shape.shoulderRadius : layout.shape.bottomRadius
        return layout
    }

    /// 숨김 (투명하게 접히는 동안 쓰는 작은 모양)
    func hiddenLayout() -> IslandLayout {
        finish(asPart1(hiddenShape()))
    }

    private func hiddenShape() -> IslandLayout {
        if geometry.hasNotch {
            let size = CGSize(width: notchWidth, height: geometry.headerHeight)
            return IslandLayout(
                size: size,
                origin: CGPoint(x: notchMinX, y: 0),
                shape: IslandShapeSpec(
                    neckHeight: size.height - 10,
                    bodyTopRadius: Self.bodyTopRadius, shoulderRadius: Self.compactShoulderRadius, bottomRadius: 10
                ),
                compact: nil
            )
        }
        let size = CGSize(width: 60, height: 22)
        let top = externalStyle == .inMenuBar && menuBarVisible ? max(0, (menuBarHeight - size.height) / 2) : menuBarHeight + NotchGeometry.pillTopGap
        return IslandLayout(
            size: size,
            origin: CGPoint(x: midX - size.width / 2, y: top),
            shape: IslandShapeSpec(
                neckHeight: size.height / 2, topRadius: 11,
                bodyTopRadius: Self.bodyTopRadius, shoulderRadius: Self.pillShoulderRadius, bottomRadius: 11
            ),
            compact: nil
        )
    }

    func compactLayout(for content: CompactContent) -> IslandLayout {
        compactLayoutAndPlacement(for: content).layout
    }

    /// 접힌 모양과 그 자리 (자리는 한 번만 고른다)
    func compactLayoutAndPlacement(for content: CompactContent) -> (layout: IslandLayout, placement: CompactPlacement) {
        let placement = compactPlacement(for: content)
        let fresh = compactLayout(placement: placement, content: content)
        // 카드를 접는 동안: 카드의 부분 1 을 그대로 그린다 (접힌 내용이 바뀌어 아래 반경 · 띠 높이가 달라도). 내용 자리는 지금 것
        guard collapseHold != nil, let previous = previousPart1, Self.samePart1Place(previous, fresh) else { return (fresh, placement) }
        var held = previous
        held.compact = fresh.compact
        return (finish(held), placement)
    }

    /// 접힌 자리 하나의 모양 (부분 1)
    func compactLayout(placement: CompactPlacement, content: CompactContent) -> IslandLayout {
        if case .none = placement { return hiddenLayout() }
        return finish(asPart1(compactShape(placement: placement, content: content)))
    }

    /// 두 부분 1 이 같은 자리 · 같은 모양 갈래인지 (가로 자리 · 폭 · 위가 같음. 아래 반경 · 띠 높이는 내용에 따라 다를 수 있다)
    static func samePart1Place(_ a: IslandLayout, _ b: IslandLayout) -> Bool {
        guard let ka = a.compact?.shapeKind, ka == b.compact?.shapeKind else { return false }
        return abs(a.origin.x - b.origin.x) < 0.5 && abs(a.size.width - b.size.width) < 0.5 && abs(a.origin.y - b.origin.y) < 0.5
    }

    private func compactShape(placement: CompactPlacement, content: CompactContent) -> IslandLayout {
        let isIdle: Bool
        if case .idle = content { isIdle = true } else { isIdle = false }

        switch placement {
        case let .wings(spec):
            // 비켜준 쪽은 폭 0 (내용은 뷰에서 숨김)
            let left = spec.visibleLeft
            let right = spec.visibleRight
            let earL: CGFloat = left > 0 ? Self.wingEar : 0
            let earR: CGFloat = right > 0 ? Self.wingEar : 0
            let width = earL + left + notchWidth + right + earR
            let originX = notchMinX - left - earL
            let band = geometry.headerHeight
            let bottomRadius: CGFloat = isIdle ? 10 : 12
            var layout = IslandLayout(
                size: CGSize(width: width, height: band),
                origin: CGPoint(x: originX, y: 0),
                shape: IslandShapeSpec(
                    neckLeft: earL, neckRight: earR, neckHeight: band - bottomRadius,
                    bodyLeft: earL, bodyRight: earR,
                    leftEar: earL, rightEar: earR,
                    bodyTopRadius: Self.bodyTopRadius, shoulderRadius: Self.compactShoulderRadius,
                    bottomRadius: bottomRadius
                ),
                compact: .wings(spec)
            )
            layout.hitRects = [CGRect(x: earL, y: 0, width: left + notchWidth + right, height: band)]
            return layout

        case let .strip(width):
            let neck = neckHeight
            let strip = stripHeight(for: content)
            let height = neck + strip
            let inset = ((width - notchWidth) / 2).rounded(.down)
            var layout = IslandLayout(
                size: CGSize(width: width, height: height),
                origin: CGPoint(x: midX - width / 2, y: 0),
                shape: IslandShapeSpec(
                    neckLeft: inset, neckRight: inset, neckHeight: neck,
                    bodyTopRadius: 8, shoulderRadius: 6, bottomRadius: M.stripHeight / 2
                ),
                compact: .strip(items: stripItems(for: content))
            )
            layout.hitRects = [
                CGRect(x: inset, y: 0, width: width - inset * 2, height: neck),
                CGRect(x: 0, y: neck, width: width, height: strip),
            ]
            return layout

        case .line:
            let height = neckHeight + M.lineThickness
            var layout = IslandLayout(
                size: CGSize(width: notchWidth, height: height),
                origin: CGPoint(x: notchMinX, y: 0),
                shape: IslandShapeSpec(
                    neckHeight: height - M.lineThickness,
                    bodyTopRadius: Self.bodyTopRadius, shoulderRadius: Self.compactShoulderRadius,
                    bottomRadius: M.lineThickness
                ),
                compact: .line
            )
            layout.hitRects = [CGRect(origin: .zero, size: layout.size)]
            return layout

        case let .menuBarPill(centerX, width, items):
            let height = max(16, menuBarHeight - 4)
            var layout = IslandLayout(
                size: CGSize(width: width, height: height),
                origin: CGPoint(x: (centerX - width / 2).rounded(), y: ((menuBarHeight - height) / 2).rounded(.down)),
                shape: IslandShapeSpec(
                    neckHeight: height / 2, topRadius: height / 2,
                    bodyTopRadius: Self.bodyTopRadius, shoulderRadius: Self.pillShoulderRadius, bottomRadius: height / 2
                ),
                compact: .pill(items: items)
            )
            layout.hitRects = [CGRect(origin: .zero, size: layout.size)]
            return layout

        case let .menuBarDot(centerX):
            let size = M.menuBarDotSize
            var layout = IslandLayout(
                size: CGSize(width: size, height: size),
                origin: CGPoint(x: (centerX - size / 2).rounded(), y: ((menuBarHeight - size) / 2).rounded(.down)),
                shape: IslandShapeSpec(
                    neckHeight: size / 2, topRadius: size / 2,
                    bodyTopRadius: Self.bodyTopRadius, shoulderRadius: size / 2, bottomRadius: size / 2
                ),
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
                shape: IslandShapeSpec(
                    neckHeight: height / 2, topRadius: height / 2,
                    bodyTopRadius: Self.bodyTopRadius, shoulderRadius: Self.pillShoulderRadius, bottomRadius: height / 2
                ),
                compact: .pill(items: items)
            )
            layout.hitRects = [CGRect(origin: .zero, size: layout.size)]
            return layout

        case .none:
            return hiddenShape()
        }
    }

    /// 펼친 카드. `bodyHeight` 는 카드 폭을 받아 상단 행 아래 본문 높이를 돌려준다.
    /// - part1: 카드 위 접힌 모양 (`cardPart1`). nil 이면 메뉴바 아래 떠 있는 카드 (접힌 상태를 숨기는 화면)
    func cardLayout(
        preferredWidth: CGFloat,
        radius: CGFloat,
        part1: IslandLayout?,
        bodyHeight: (CGFloat) -> CGFloat
    ) -> IslandLayout {
        finish(cardShape(preferredWidth: preferredWidth, radius: radius, part1: part1, bodyHeight: bodyHeight))
    }

    private func cardShape(
        preferredWidth: CGFloat,
        radius: CGFloat,
        part1: IslandLayout?,
        bodyHeight: (CGFloat) -> CGFloat
    ) -> IslandLayout {
        if geometry.hasNotch, let part1 {
            return attachedCard(
                part1: part1, preferredWidth: max(preferredWidth, notchWidth + 80), radius: radius, centerX: midX, bodyHeight: bodyHeight
            )
        }
        let maxWidth = preferredWidth > M.externalCardMaxWidth
            ? min(preferredWidth, screenWidth - 16)
            : min(preferredWidth, M.externalCardMaxWidth)
        let cardWidth = max(200, maxWidth)
        if let part1 {
            return attachedCard(
                part1: part1, preferredWidth: cardWidth, radius: radius, centerX: part1.panelRect.midX.rounded(), bodyHeight: bodyHeight
            )
        }
        let top = (menuBarVisible ? menuBarHeight : 0) + NotchGeometry.pillTopGap
        return floatingCard(cardWidth: cardWidth, anchorX: midX, top: top, radius: radius, bodyHeight: bodyHeight)
    }

    /// 펼친 카드의 부분 1: 카드 띠 · 목 알약 자리(`cardBand`)의 접힌 모양 (접힌 상태를 숨기는 화면이면 nil).
    /// 직전에 그린 부분 1 과 자리가 같으면 그 모양 그대로 (펼치는 동안 부분 1 이 조금도 바뀌지 않게)
    func cardPart1(for compact: CompactPlacement, content: CompactContent) -> IslandLayout? {
        let band = cardBand(for: compact)
        if case .none = band { return nil }
        let fresh = compactLayout(placement: band, content: content)
        if let previous = previousPart1, Self.samePart1Place(previous, fresh) { return previous }
        return fresh
    }

    // MARK: 펼친 카드 띠 (노치 화면)

    /// 접힌 날개 귀 반경 (`compactShape` 와 카드 띠가 같은 값을 쓴다)
    static let wingEar: CGFloat = 6
    /// 부분 2(몸통)는 부분 1 목보다 쪽마다 이만큼 이상 넓다 (옆면을 맞댄 채 이어지거나 거의 겹친 이음매가 생기지 않게)
    static let bodySnap: CGFloat = 12

    /// 펼친 카드 띠(부분 1)가 쓰는 날개 (nil = 노치 폭): 직전에 그린 접힌 날개(배치 이력)가 아직 맞으면 그대로, 아니면 지금 계산한 접힌 자리.
    /// 직전에 그린 접힌 모양이 노치 폭(노치 아래 띠 · 선)이었으면 지금 날개가 맞아도 노치 폭 (펼치는 동안 띠가 넓어지지 않게).
    /// 표시 상태가 이 값을 접힌 날개 이력으로 기억해, 접을 때도 같은 띠에서 시작한다
    func cardBandWings(for compact: CompactPlacement) -> WingsSpec? {
        guard case let .wings(fresh) = compact, previousWings != .withoutWings else { return nil }
        if let previous = previousWings, bandStillFits(previous) { return previous }
        return fresh
    }

    /// 펼친 카드의 부분 1 이 쓰는 접힌 자리: 노치 화면은 카드 띠 날개(노치 폭이면 노치 아래 띠 · 선),
    /// 노치 없는 화면은 알약 · 점. 표시 상태가 카드를 접는 동안 이 자리를 붙잡는다 (`collapseHold`)
    func cardBand(for compact: CompactPlacement) -> CompactPlacement {
        guard geometry.hasNotch else { return cardPill(for: compact) }
        if let spec = cardBandWings(for: compact) { return .wings(spec) }
        guard case .wings = compact else { return compact }
        return overlapStyle == .minimal ? .line : .strip(width: notchWidth)
    }

    /// 펼친 카드 부분 1 이 될 메뉴바 알약 (노치 없는 화면): 직전에 그린 알약이 아직 그 자리 그대로 들어가면 그것.
    /// 빈 구간이 줄어 그대로 안 들어가면 들어가는 만큼만 줄여 다시 놓는다 (지금 내용 폭보다 좁게는 두지 않음)
    func cardPill(for compact: CompactPlacement) -> CompactPlacement {
        guard case let .menuBarPill(_, freshWidth, items) = compact, case let .menuBarPill(centerX, width, _)? = previousPill,
              let range = menuBarPillRange
        else { return compact }
        if pillStillFits(centerX: centerX, width: width) { return .menuBarPill(centerX: centerX, width: width, items: items) }
        let kept = max(freshWidth, min(width, range.hi - range.lo).rounded(.down))
        return .menuBarPill(centerX: pillCenter(width: kept, in: range), width: kept, items: items)
    }

    /// 직전 날개가 지금 화면에도 맞는지: 넓은 노치이고, 쓸 수 있는 폭 안
    private func bandStillFits(_ spec: WingsSpec) -> Bool {
        guard usesWings else { return false }
        let limit = wingLimit
        return spec.visibleLeft <= limit.left + 0.5 && spec.visibleRight <= limit.right + 0.5
    }

    /// 카드 몸통(부분 2) 가로 구간 (패널 기준): 원하는 폭 이상, 부분 1 목(`attachMin…attachMax`)보다 쪽마다 `bodySnap` 이상 넓게,
    /// 되도록 `centerX` 가운데 · 화면 안(가장자리 8pt). 부분 1 을 품는 것이 화면 여백보다 먼저다
    static func cardBodySpan(
        preferred: CGFloat, attachMin: CGFloat, attachMax: CGFloat, centerX: CGFloat, screenWidth: CGFloat
    ) -> (minX: CGFloat, maxX: CGFloat) {
        let need = (lo: attachMin - bodySnap, hi: attachMax + bodySnap)
        let width = max(preferred, need.hi - need.lo).rounded(.up)
        var lo = (centerX - width / 2).rounded()
        lo = min(max(lo, 8), max(8, screenWidth - 8 - width))
        lo = min(max(lo, need.hi - width), need.lo)
        return (lo, lo + width)
    }

    /// 부분 1(접힌 모양) 아래로 부분 2(몸통)를 내린 카드.
    /// - 부분 1 은 접힌 모양 그대로 (`IslandShapeSpec.part1`). 주 외곽선의 목은 부분 1 의 위 조각(띠 · 알약 · 점)과 같은 자리 ·
    ///   같은 귀 · 위 반경, 목 아래끝은 부분 1 아래끝(두 조각이면 띠 아래끝)이다.
    /// - 몸통은 메뉴바 아래에서만 목보다 넓어지고(쪽마다 `bodySnap` 이상), 만나는 곳은 오목하게 잇는다.
    /// - 상단 행 · 본문은 모두 몸통 안, 부분 1 아래에 둔다
    private func attachedCard(
        part1 p1: IslandLayout,
        preferredWidth: CGFloat,
        radius: CGFloat,
        centerX: CGFloat,
        bodyHeight: (CGFloat) -> CGFloat
    ) -> IslandLayout {
        let piece = p1.shape.part1
        let twoPiece = piece.isTwoPiece
        let top = p1.origin.y
        // 부분 1 위 조각 가로 자리 (귀 제외)
        let attachMin = p1.origin.x + piece.neckLeft
        let attachMax = p1.origin.x + p1.size.width - piece.neckRight
        let neckBottom = top + (twoPiece ? piece.neckHeight : p1.size.height)
        let part1Bottom = p1.panelRect.maxY
        let barBottom = geometry.hasNotch ? neckHeight : (menuBarVisible ? menuBarHeight : 0)
        // 몸통이 넓어지는 높이 · 상단 행 높이 (부분 1 아래)
        let bodyTop = max(neckBottom, barBottom)
        let headerTop = max(bodyTop, part1Bottom)
        let span = Self.cardBodySpan(
            preferred: preferredWidth, attachMin: attachMin, attachMax: attachMax, centerX: centerX, screenWidth: screenWidth
        )
        let cardWidth = span.maxX - span.minX
        let frameMinX = min(p1.origin.x, span.minX)
        let frameMaxX = max(p1.origin.x + p1.size.width, span.maxX)
        let height = headerTop - top + M.headerRowHeight + bodyHeight(cardWidth)
        let bodyLeft = span.minX - frameMinX
        let bodyRight = frameMaxX - span.maxX

        var shape = IslandShapeSpec(
            neckLeft: attachMin - frameMinX, neckRight: frameMaxX - attachMax, neckHeight: neckBottom - top,
            bodyLeft: bodyLeft, bodyRight: bodyRight,
            leftEar: piece.leftEar, rightEar: piece.rightEar, topRadius: piece.topRadius,
            bodyTopRadius: Self.bodyTopRadius, shoulderRadius: cardShoulderRadius, bottomRadius: radius
        )
        shape.capRadius = p1.shape.capRadius
        shape.part1 = piece
        var layout = IslandLayout(
            size: CGSize(width: frameMaxX - frameMinX, height: height),
            origin: CGPoint(x: frameMinX, y: top),
            shape: shape,
            compact: nil,
            cardWidth: cardWidth
        )
        layout.header = HeaderSlot(top: headerTop - top, height: M.headerRowHeight, leftInset: bodyLeft, rightInset: bodyRight)
        // 클릭: 부분 1 자리 + 목(부분 1 위 조각 폭, 몸통이 넓어지는 높이까지) + 몸통. 목 옆 메뉴바는 통과
        let dx = p1.origin.x - frameMinX
        layout.hitRects = p1.hitRects.map { $0.offsetBy(dx: dx, dy: 0) } + [
            CGRect(x: attachMin - frameMinX, y: 0, width: attachMax - attachMin, height: bodyTop - top),
            CGRect(x: bodyLeft, y: bodyTop - top, width: cardWidth, height: height - (bodyTop - top)),
        ]
        return layout
    }

    /// 메뉴바 아래 떠 있는 카드 (접힌 상태를 숨기는 화면). 목 = 상단 행, 몸통 = 본문 (같은 폭).
    /// 접힌 모양이 없으므로 카드 모양 전체를 부분 1 로 둔다 (숨김 ↔ 카드 전환이 한 모양으로 바뀐다)
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
            shape: IslandShapeSpec(neckHeight: header, topRadius: radius, bottomRadius: radius),
            compact: nil,
            cardWidth: cardWidth
        )
        layout.header = HeaderSlot(top: 0, height: header)
        layout.hitRects = [CGRect(origin: .zero, size: layout.size)]
        return asPart1(layout)
    }

    /// 열린 메뉴와 겹치는지 볼 영역: 카드가 펼쳐질 자리 (패널 기준)
    func cardZone() -> CGRect {
        let content = CompactContent.idle(content: CompactText.summaryWidth(SessionStatusSummary(done: 1)))
        let layout = cardLayout(
            preferredWidth: IslandMetrics.permissionWidth,
            radius: 22,
            part1: cardPart1(for: compactPlacement(for: content), content: content),
            bodyHeight: { _ in 150 }
        )
        return layout.panelRect
    }
}
