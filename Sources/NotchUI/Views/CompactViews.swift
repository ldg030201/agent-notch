import SwiftUI
import NotchCore

// MARK: - idle

/// idle: 세션 수만큼 점 (작업 중 = 초록, 주의 = 깜빡임, 나머지 = 회색). 레이아웃이 정한 자리에 둔다.
struct IdleCompactView: View {
    let layout: IslandLayout
    let store: SessionStore
    let reduceMotion: Bool

    var body: some View {
        let sessions = Array(store.rankedSessions.prefix(IslandMetrics.maxIdleDots))
        Group {
            switch layout.compact {
            case let .wings(left, right, _):
                CompactWings(layout: layout, left: left, right: right) {
                    if right > 0 {
                        // 양쪽 날개면 왼쪽엔 작은 점만
                        Circle()
                            .fill(Palette.muted)
                            .frame(width: 3, height: 3)
                    } else {
                        dots(sessions)
                    }
                } trailing: {
                    dots(sessions)
                }
            case .strip:
                CompactStrip(layout: layout) {
                    dots(sessions)
                }
            case .line:
                StatusLine(layout: layout, color: Palette.muted.opacity(0.6))
            case .pill:
                dots(sessions)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .dot:
                MenuBarDotView(tone: sessions.contains { $0.phase.isWorking } ? .green : .muted, reduceMotion: reduceMotion)
            case nil:
                Color.clear
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func dots(_ sessions: [AgentSession]) -> some View {
        HStack(spacing: IslandMetrics.idleDotSpacing) {
            ForEach(sessions) { session in
                SessionDot(session: session, size: IslandMetrics.idleDotSize, reduceMotion: reduceMotion)
            }
        }
    }

    private var accessibilityText: String {
        let total = store.rankedSessions.count
        let working = store.rankedSessions.filter { $0.phase.isWorking }.count
        return "세션 \(total)개, 작업 중 \(working)개"
    }
}

// MARK: - working

/// 접힌 상태로 포커스 세션 표시.
/// - 양쪽 날개: 왼쪽 = 상태 + 프로젝트명, 오른쪽 = 현재 툴 + `+N −M`
/// - 한쪽 날개: 상태 + (프로젝트) + (툴) + `+N −M` 을 노치 옆에 모은다
/// - 노치 아래 띠: 상태 + 짧은 툴 이름 + `+N −M`
/// - 알약: 상태 + 프로젝트 · 툴 제목 + `+N −M`
struct CompactSessionView: View {
    let session: AgentSession?
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
        case let .wings(left, right, items):
            if left > 0, right > 0 {
                CompactWings(layout: layout, left: left, right: right) {
                    HStack(spacing: 6) {
                        StatusIndicator(session: session, reduceMotion: reduceMotion)
                        Text(session.projectName)
                            .truncationMode(.tail)
                    }
                } trailing: {
                    trailing(session, toolTitle: IslandFormat.shortToolTitle(session))
                }
            } else {
                CompactWings(layout: layout, left: left, right: right) {
                    singleWing(session, items: items)
                } trailing: {
                    singleWing(session, items: items)
                }
            }

        case .strip:
            CompactStrip(layout: layout) {
                HStack(spacing: 5) {
                    StatusIndicator(session: session, reduceMotion: reduceMotion, size: 12)
                    trailing(session, toolTitle: IslandFormat.shortToolTitle(session))
                }
                .font(IslandFont.caption)
            }

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
            trailing(session, toolTitle: items.contains(.tool) ? IslandFormat.shortToolTitle(session) : "")
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

/// 노치 양옆 날개 틀. 양쪽이면 바깥쪽 정렬, 한쪽이면 노치 쪽으로 붙인다.
struct CompactWings<Leading: View, Trailing: View>: View {
    let layout: IslandLayout
    let left: CGFloat
    let right: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let earL = layout.shape.neckLeft
        let earR = layout.shape.neckRight
        let notchWidth = max(0, layout.size.width - earL - earR - left - right)
        let both = left > 0 && right > 0
        let pad = IslandMetrics.wingPadding

        HStack(spacing: 0) {
            if left > 0 {
                leading
                    .padding(.leading, pad)
                    .padding(.trailing, both ? 4 : 6)
                    .frame(width: left, alignment: both ? .leading : .trailing)
            }
            Color.clear.frame(width: notchWidth)
            if right > 0 {
                trailing
                    .padding(.leading, both ? 4 : 6)
                    .padding(.trailing, pad)
                    .frame(width: right, alignment: both ? .trailing : .leading)
            }
        }
        .padding(.leading, earL)
        .padding(.trailing, earR)
        .frame(height: layout.size.height)
        .font(IslandFont.body)
        .foregroundStyle(Palette.text)
        .lineLimit(1)
    }
}

/// 노치 아래 띠 틀: 목(노치) 높이만큼 비우고 그 아래 한 줄
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
