import SwiftUI
import NotchCore

// MARK: - idle

/// idle: 모든 세션 상태 요약 ("● 3" — 기다리는 중 주황 · 진행 중 초록 · 끝남 회색). 레이아웃이 정한 자리에 둔다.
struct IdleCompactView: View {
    let layout: IslandLayout
    /// 모든 세션 요약 (보여주는 세션이 없으므로 빼는 세션 없음)
    let summary: SessionStatusSummary
    let reduceMotion: Bool

    var body: some View {
        Group {
            switch layout.compact {
            case let .wings(spec) where spec.arrangement == .strip:
                CompactStrip(layout: layout) {
                    chips
                }
            case let .wings(spec):
                CompactWings(layout: layout, spec: spec) {
                    if spec.arrangement == .split {
                        // 양쪽 날개면 왼쪽엔 작은 점만
                        Circle()
                            .fill(Palette.muted)
                            .frame(width: 3, height: 3)
                    } else {
                        chips
                    }
                } trailing: {
                    chips
                }
            case .strip:
                CompactStrip(layout: layout) {
                    chips
                }
            case .line:
                StatusLine(layout: layout, color: Palette.muted.opacity(0.6))
            case .pill:
                chips
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .dot:
                MenuBarDotView(tone: summary.working > 0 ? .green : .muted, reduceMotion: reduceMotion)
            case nil:
                Color.clear
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var chips: some View {
        SessionSummaryChips(summary: summary)
    }

    private var accessibilityText: String {
        let spoken = summary.spokenText
        return spoken.isEmpty ? "세션 \(summary.total)개" : "세션 \(summary.total)개, \(spoken)"
    }
}

// MARK: - working

/// 접힌 상태로 포커스 세션 표시. 다른 세션이 있으면 상태 요약("● 2")을 레이아웃이 정한 자리에 함께 둔다.
/// - 양쪽 날개: 왼쪽 = 상태 + 프로젝트명 (+ 요약), 오른쪽 = (노치 쪽에 고정한 요약 …) 현재 툴 + `+N −M`
/// - 한쪽 날개: 상태 + (프로젝트) + (요약) + (툴) + `+N −M` 을 노치 옆에 모은다
/// - 노치 아래 띠: 알약과 같은 요소 (상태 + 프로젝트 · 툴 이름 + `+N −M` + 배지 + 요약, 한 줄에 안 들어가면 배지 · 요약은 둘째 줄)
/// - 알약: 상태 + 프로젝트 · 툴 이름 + `+N −M` + 배지 + 요약
/// 툴은 어디서나 짧은 이름만 (`IslandFormat.shortToolTitle`, 예: "Bash")
struct CompactSessionView: View {
    let session: AgentSession?
    /// 이 세션을 뺀 다른 세션 요약
    var summary: SessionStatusSummary = .empty
    let layout: IslandLayout
    let reduceMotion: Bool

    var body: some View {
        if let session {
            content(session)
                .accessibilityElement(children: .combine)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func content(_ session: AgentSession) -> some View {
        switch layout.compact {
        case let .wings(spec) where spec.arrangement == .strip:
            stripContent(session, items: spec.items)

        case let .wings(spec):
            if spec.arrangement == .split {
                let summaryRight = spec.items.contains(.summaryTrailing)
                CompactWings(layout: layout, spec: spec) {
                    HStack(spacing: 6) {
                        StatusIndicator(session: session, reduceMotion: reduceMotion)
                        if spec.items.contains(.project) {
                            // 자리가 모자라면 프로젝트명부터 줄인다 (요약은 통째로)
                            Text(session.projectName)
                                .truncationMode(.tail)
                                .layoutPriority(-1)
                        }
                        if !summaryRight { summaryChips(spec.items, leading: 2) }
                    }
                } trailing: {
                    let toolTitle = spec.items.contains(.tool) ? IslandFormat.shortToolTitle(session) : ""
                    if summaryRight, !summary.isEmpty {
                        // 요약은 노치 쪽에 고정하고 툴 · `+N −M` 은 바깥 끝에 붙인다
                        // (툴 이름 · diff 자릿수가 바뀌어도 칩이 좌우로 움직이지 않게)
                        HStack(spacing: 0) {
                            summaryChips(spec.items)
                            Spacer(minLength: Self.hasTrailing(session, toolTitle: toolTitle) ? IslandMetrics.summaryLead : 0)
                            trailing(session, toolTitle: toolTitle)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        trailing(session, toolTitle: toolTitle)
                    }
                }
            } else {
                CompactWings(layout: layout, spec: spec) {
                    singleWing(session, items: spec.items)
                } trailing: {
                    singleWing(session, items: spec.items)
                }
            }

        case let .strip(items):
            stripContent(session, items: items)

        case .line:
            StatusLine(layout: layout, color: Self.toneColor(session))

        case let .pill(items):
            HStack(spacing: 6) {
                StatusIndicator(session: session, reduceMotion: reduceMotion, size: min(14, layout.size.height - 6))
                pillTitle(session, items: items)
                Spacer(minLength: 0)
                // 그릴 것이 없으면 빼서 사이 간격이 겹치지 않게 (제목 자리가 그만큼 넓어진다)
                if Self.hasTrailing(session, toolTitle: "") {
                    trailing(session, toolTitle: "")
                        .layoutPriority(1)
                }
                summaryChips(items, leading: 2)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .font(IslandFont.body)
            .foregroundStyle(Palette.text)
            .lineLimit(1)

        case .dot:
            MenuBarDotView(tone: Self.tone(session), reduceMotion: reduceMotion)

        case nil:
            Color.clear
        }
    }

    /// 노치 아래 띠: 알약과 같은 요소(`IslandLayoutEngine.stripItems`) — 상태 + 프로젝트 · 툴 이름 + `+N −M` + 배지 + 요약.
    /// 띠가 두 줄 높이면 백그라운드 배지 · 요약은 둘째 줄 (폭은 노치 폭 그대로). 제목 줄 요소는 배지 · 요약 없이 골라서
    /// 메뉴바 알약과 같은 제목이다 (예: 둘 다 "api-server · Bash +12 −3")
    @ViewBuilder
    private func stripContent(_ session: AgentSession, items: CompactItems) -> some View {
        let showsSummary = !summary.isEmpty && items.contains(.summary)
        let badgeCount = session.backgroundTaskCount
        let wraps = layout.hasTwoLineStrip && (showsSummary || badgeCount > 0)
        let line = HStack(spacing: 5) {
            StatusIndicator(session: session, reduceMotion: reduceMotion, size: 12)
            pillTitle(session, items: items)
            if Self.hasTrailing(session, toolTitle: "", badge: !wraps) {
                trailing(session, toolTitle: "", badge: !wraps)
                    .layoutPriority(1)
            }
        }
        CompactStrip(layout: layout) {
            if wraps {
                VStack(spacing: 1) {
                    line
                    // 둘째 줄: 배지 · 요약 (알약에서 `+N −M` 뒤에 잇는 순서 그대로)
                    HStack(spacing: IslandMetrics.summaryLead) {
                        if badgeCount > 0 { BackgroundTaskBadge(count: badgeCount) }
                        if showsSummary { SessionSummaryChips(summary: summary, spokenPrefix: Self.summaryPrefix) }
                    }
                }
            } else if showsSummary {
                HStack(spacing: 5) {
                    line
                    SessionSummaryChips(summary: summary, spokenPrefix: Self.summaryPrefix)
                        .padding(.leading, 3)
                }
            } else {
                line
            }
        }
    }

    /// 한쪽 날개에 모은 내용
    private func singleWing(_ session: AgentSession, items: CompactItems) -> some View {
        HStack(spacing: 6) {
            StatusIndicator(session: session, reduceMotion: reduceMotion)
            if items.contains(.project) {
                // 자리가 모자라면 프로젝트명부터 줄인다
                Text(session.projectName)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            summaryChips(items, leading: 2)
            trailing(session, toolTitle: items.contains(.tool) ? IslandFormat.shortToolTitle(session) : "")
        }
    }

    static let summaryPrefix = "다른 세션 "

    /// 레이아웃이 요약 자리를 줬고 다른 세션이 있을 때만 요약 칩 (앞 내용과 간격 `summaryLead` 를 맞추는 여백 포함)
    @ViewBuilder
    private func summaryChips(_ items: CompactItems, leading: CGFloat = 0) -> some View {
        if items.contains(.summary), !summary.isEmpty {
            SessionSummaryChips(summary: summary, spokenPrefix: Self.summaryPrefix)
                .padding(.leading, leading)
        }
    }

    /// 툴 이름 + `+N −M`, 또는 상태 문구 (승인 필요 등). 백그라운드 작업이 돌고 있으면 끝에 배지 "⧉ N"
    /// (`badge` 가 false 면 빼고 — 노치 아래 띠가 배지를 둘째 줄로 내린 경우)
    @ViewBuilder
    private func trailing(_ session: AgentSession, toolTitle: String, badge: Bool = true) -> some View {
        HStack(spacing: IslandMetrics.backgroundLead) {
            if let attention = CompactText.attentionText(session) {
                Text(attention.text)
                    .foregroundStyle(Self.color(attention.tone))
            } else {
                if !toolTitle.isEmpty {
                    Text(toolTitle)
                        .truncationMode(.middle)
                }
                if session.turn.added > 0 || session.turn.removed > 0 {
                    DiffStatText(added: session.turn.added, removed: session.turn.removed)
                        .layoutPriority(1)
                }
            }
            if badge, session.backgroundTaskCount > 0 {
                BackgroundTaskBadge(count: session.backgroundTaskCount)
                    .layoutPriority(1)
            }
        }
    }

    /// `trailing` 이 그릴 것이 있는지 (상태 문구 · 툴 이름 · `+N −M` · 백그라운드 배지)
    private static func hasTrailing(_ session: AgentSession, toolTitle: String, badge: Bool = true) -> Bool {
        CompactText.attentionText(session) != nil || !toolTitle.isEmpty
            || session.turn.added > 0 || session.turn.removed > 0
            || (badge && session.backgroundTaskCount > 0)
    }

    /// 알약 · 노치 아래 띠 제목: 프로젝트명(끝 줄임) · 짧은 툴 이름(가운데 줄임). 자리가 모자라면 `PillTitleLayout` 이 줄인다.
    /// 레이아웃(`IslandLayoutEngine.lineItems`)은 둘 다 최소 폭까지 줄인 폭으로 요소를 고른다
    @ViewBuilder
    private func pillTitle(_ session: AgentSession, items: CompactItems) -> some View {
        let project = items.contains(.project) ? session.projectName : ""
        let tool = items.contains(.tool) && CompactText.attentionText(session) == nil ? IslandFormat.shortToolTitle(session) : ""
        if !project.isEmpty, !tool.isEmpty {
            // 빼는 순서와 같게 줄인다: 요약이 없으면 프로젝트명부터, 있으면 툴 제목부터
            PillTitleLayout(projectFirst: !items.contains(.summary)) {
                Text(project)
                    .truncationMode(.tail)
                Text(verbatim: " · ")
                Text(tool)
                    .truncationMode(.middle)
            }
        } else if !project.isEmpty {
            Text(project)
                .truncationMode(.tail)
        } else if !tool.isEmpty {
            Text(tool)
                .truncationMode(.middle)
        }
    }

    static func tone(_ session: AgentSession) -> MenuBarDotView.Tone {
        switch session.phase {
        case .waitingPermission, .waitingInput: return .amber
        case .failed: return .red
        case .thinking, .runningTool, .compacting: return .green
        default: return session.hasUnseenCompletion ? .green : .muted
        }
    }

    static func toneColor(_ session: AgentSession) -> Color {
        tone(session).color
    }

    private static func color(_ tone: CompactText.Tone) -> Color {
        switch tone {
        case .amber: return Palette.amber
        case .red: return Palette.red
        case .muted: return Palette.muted
        }
    }
}

/// 알약 · 노치 아래 띠 제목 배치: 프로젝트명 · 구분점 · 툴 이름을 한 줄로 잇는다.
/// 자리가 모자라면 한쪽을 먼저 최소 폭(`IslandLayoutEngine.pillProjectMin` · `pillToolMin`)까지 줄이고, 그래도 모자라면 다른 쪽을 줄인다.
/// 줄인 글자의 실제 폭대로 이어 붙여 사이가 벌어지지 않는다
struct PillTitleLayout: Layout {
    /// true 면 프로젝트명을 먼저 줄이고, false 면 툴 제목을 먼저 줄인다
    var projectFirst: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = sizes(proposal, subviews)
        return CGSize(width: sizes.reduce(0) { $0 + $1.width }, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, size) in zip(subviews, sizes(ProposedViewSize(width: bounds.width, height: bounds.height), subviews)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
            x += size.width
        }
    }

    /// 하위 뷰(프로젝트명 · 구분점 · 툴 제목) 크기
    private func sizes(_ proposal: ProposedViewSize, _ subviews: Subviews) -> [CGSize] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        guard subviews.count == 3, let available = proposal.width,
              available < ideal.reduce(0, { $0 + $1.width })
        else { return ideal }
        let room = max(0, available - ideal[1].width)
        func fit(_ index: Int, _ width: CGFloat) -> CGSize {
            subviews[index].sizeThatFits(ProposedViewSize(width: max(0, width), height: proposal.height))
        }
        // 먼저 줄일 쪽(first)은 다른 쪽이 다 들어가고 남는 만큼(최소 폭까지), 다른 쪽이 최소 폭도 안 되면 그보다 더 줄인다.
        // 다른 쪽(second)은 first 가 실제로 쓴 폭을 뺀 나머지 전부
        let (first, second) = projectFirst ? (0, 2) : (2, 0)
        let floors = [min(ideal[0].width, IslandLayoutEngine.pillProjectMin), 0, min(ideal[2].width, IslandLayoutEngine.pillToolMin)]
        let firstWidth = min(ideal[first].width, max(floors[first], room - ideal[second].width), max(0, room - floors[second]))
        let firstSize = fit(first, firstWidth)
        let secondSize = fit(second, room - firstSize.width)
        var sizes = ideal
        sizes[first] = firstSize
        sizes[second] = secondSize
        return sizes
    }
}

// MARK: - 자리별 틀

/// 노치 양옆 날개 틀. 내용은 노치 가장자리부터 `WingsSpec` 의 내용 자리 폭 안에 둔다
/// (아이콘 구멍이 있으면 첫 구멍 앞까지). 양쪽이면 바깥쪽 정렬, 한쪽이면 노치 쪽으로 붙인다.
/// 비켜준 쪽 내용은 날개가 들어가는 동안 흐려진다.
struct CompactWings<Leading: View, Trailing: View>: View {
    let layout: IslandLayout
    let spec: WingsSpec
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let earL = layout.shape.neckLeft
        let earR = layout.shape.neckRight
        let left = spec.visibleLeft
        let right = spec.visibleRight
        let notchX = earL + left
        let notchWidth = max(0, layout.size.width - earL - earR - left - right)
        let split = spec.arrangement == .split
        let height = layout.size.height
        let showsLeft = (split || spec.arrangement == .left) && spec.leftSpan > 0
        let showsRight = (split || spec.arrangement == .right) && spec.rightSpan > 0

        ZStack(alignment: .topLeading) {
            if showsLeft {
                leading
                    .padding(.leading, spec.leftOuterPad)
                    .padding(.trailing, split ? 4 : 6)
                    .frame(width: spec.leftSpan, height: height, alignment: split ? .leading : .trailing)
                    .offset(x: notchX - spec.leftSpan)
                    .opacity(spec.hidden.contains(.left) ? 0 : 1)
            }
            if showsRight {
                trailing
                    .padding(.leading, split ? 4 : 6)
                    .padding(.trailing, spec.rightOuterPad)
                    .frame(width: spec.rightSpan, height: height, alignment: split ? .trailing : .leading)
                    .offset(x: notchX + notchWidth)
                    .opacity(spec.hidden.contains(.right) ? 0 : 1)
            }
        }
        .frame(width: layout.size.width, height: height, alignment: .topLeading)
        .font(IslandFont.body)
        .foregroundStyle(Palette.text)
        .lineLimit(1)
    }
}

/// 노치 아래 띠 틀: 목(노치) 높이만큼 비우고 그 아래 한 줄 (요약이 안 들어가면 두 줄).
/// 넓은 노치에서 내용만 띠로 내린 경우 몸통(노치 폭) 안에 둔다.
struct CompactStrip<Content: View>: View {
    let layout: IslandLayout
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: layout.shape.neckHeight)
            content
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: max(0, layout.size.height - layout.shape.neckHeight))
                .padding(.leading, layout.shape.bodyLeft)
                .padding(.trailing, layout.shape.bodyRight)
        }
        .font(IslandFont.caption)
        .foregroundStyle(Palette.text)
        .lineLimit(1)
    }
}

/// 노치 아래 가장자리 상태 색 선
struct StatusLine: View {
    let layout: IslandLayout
    let color: Color

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Capsule()
                .fill(color)
                .frame(height: IslandMetrics.lineThickness)
                .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

/// 메뉴바 안 12pt 점 (검정 원 안에 상태 색 점)
struct MenuBarDotView: View {
    enum Tone { case green, amber, red, muted }

    let tone: Tone
    let reduceMotion: Bool

    var body: some View {
        Group {
            switch tone {
            case .amber:
                PulsingDot(color: Palette.amberNS, animated: !reduceMotion)
            case .red:
                PulsingDot(color: Palette.redNS, animated: !reduceMotion)
            case .green, .muted:
                Circle().fill(tone.color)
            }
        }
        .frame(width: 6, height: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch tone {
        case .green: return "작업 중"
        case .amber: return "확인 필요"
        case .red: return "실패"
        case .muted: return "대기"
        }
    }
}

extension MenuBarDotView.Tone {
    var color: Color {
        switch self {
        case .green: return Palette.green
        case .amber: return Palette.amber
        case .red: return Palette.red
        case .muted: return Palette.muted
        }
    }
}

// MARK: - 카드 상단 행 왼쪽

/// 펼친 카드 상단 행 왼쪽: 상태 + 프로젝트명
struct CardHeaderLeading: View {
    let session: AgentSession?
    let reduceMotion: Bool
    var indicator: AnyView?

    var body: some View {
        HStack(spacing: 6) {
            if let indicator {
                indicator
            } else if let session {
                StatusIndicator(session: session, reduceMotion: reduceMotion)
            }
            Text(session?.projectName ?? "Claude Code")
                .truncationMode(.tail)
        }
    }
}
