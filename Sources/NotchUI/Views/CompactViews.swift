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
/// - 노치 아래 띠: 상태 + 짧은 툴 이름 + `+N −M` + 요약 (한 줄에 안 들어가면 요약은 둘째 줄)
/// - 알약: 상태 + 프로젝트 · 툴 제목 + `+N −M` + 요약
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
            stripContent(session)

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

        case .strip:
            stripContent(session)

        case .line:
            StatusLine(layout: layout, color: Self.toneColor(session))

        case let .pill(items):
            HStack(spacing: 6) {
                StatusIndicator(session: session, reduceMotion: reduceMotion, size: min(14, layout.size.height - 6))
                let title = pillTitle(session, items: items)
                if !title.isEmpty {
                    Text(title)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                trailing(session, toolTitle: "")
                    .layoutPriority(1)
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

    /// 노치 아래 띠: 상태 + 짧은 툴 이름 + `+N −M` + 요약. 띠가 두 줄 높이면 요약은 둘째 줄 (폭은 노치 폭 그대로)
    @ViewBuilder
    private func stripContent(_ session: AgentSession) -> some View {
        let line = HStack(spacing: 5) {
            StatusIndicator(session: session, reduceMotion: reduceMotion, size: 12)
            trailing(session, toolTitle: IslandFormat.shortToolTitle(session))
        }
        CompactStrip(layout: layout) {
            if summary.isEmpty {
                line
            } else if layout.hasTwoLineStrip {
                VStack(spacing: 1) {
                    line
                    SessionSummaryChips(summary: summary, spokenPrefix: Self.summaryPrefix)
                }
            } else {
                HStack(spacing: 5) {
                    line
                    SessionSummaryChips(summary: summary, spokenPrefix: Self.summaryPrefix)
                        .padding(.leading, 3)
                }
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
    private func summaryChips(_ items: CompactItems, leading: CGFloat = 0, trailing: CGFloat = 0) -> some View {
        if items.contains(.summary), !summary.isEmpty {
            SessionSummaryChips(summary: summary, spokenPrefix: Self.summaryPrefix)
                .padding(.leading, leading)
                .padding(.trailing, trailing)
        }
    }

    /// 툴 이름 + `+N −M`, 또는 상태 문구 (승인 필요 등)
    @ViewBuilder
    private func trailing(_ session: AgentSession, toolTitle: String) -> some View {
        if let attention = CompactText.attentionText(session) {
            Text(attention.text)
                .foregroundStyle(Self.color(attention.tone))
        } else {
            HStack(spacing: 6) {
                if !toolTitle.isEmpty {
                    Text(toolTitle)
                        .truncationMode(.middle)
                }
                if session.turn.added > 0 || session.turn.removed > 0 {
                    DiffStatText(added: session.turn.added, removed: session.turn.removed)
                        .layoutPriority(1)
                }
            }
        }
    }

    /// `trailing` 이 그릴 것이 있는지 (상태 문구 · 툴 이름 · `+N −M`)
    private static func hasTrailing(_ session: AgentSession, toolTitle: String) -> Bool {
        CompactText.attentionText(session) != nil || !toolTitle.isEmpty
            || session.turn.added > 0 || session.turn.removed > 0
    }

    private func pillTitle(_ session: AgentSession, items: CompactItems) -> String {
        var parts: [String] = []
        if items.contains(.project) { parts.append(session.projectName) }
        if items.contains(.tool), CompactText.attentionText(session) == nil {
            let tool = IslandFormat.fullToolTitle(session)
            if !tool.isEmpty { parts.append(tool) }
        }
        return parts.joined(separator: " · ")
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
