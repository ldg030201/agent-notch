import AppKit
import QuartzCore
import SwiftUI
import NotchCore

// MARK: - 스피너

/// 작업 중 스피너. 실제 패널에서는 Core Animation 으로 돌려 앱 CPU 를 쓰지 않고,
/// 스냅숏 렌더링에서는 같은 크기의 정지된 SwiftUI 호를 그린다.
struct SpinnerView: View {
    var color: NSColor = Palette.greenNS
    var lineWidth: CGFloat = 1.8
    var animated: Bool = true

    @Environment(\.islandRenderContext) private var renderContext

    var body: some View {
        if renderContext.isSnapshot {
            Circle()
                .inset(by: lineWidth / 2 + 0.5)
                .trim(from: 0, to: 0.75)
                .stroke(Color(nsColor: color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        } else {
            LayerSpinner(color: color, lineWidth: lineWidth, animated: animated)
        }
    }
}

private struct LayerSpinner: NSViewRepresentable {
    var color: NSColor
    var lineWidth: CGFloat
    var animated: Bool

    func makeNSView(context: Context) -> SpinnerNSView {
        let view = SpinnerNSView()
        view.configure(color: color, lineWidth: lineWidth, animated: animated)
        return view
    }

    func updateNSView(_ nsView: SpinnerNSView, context: Context) {
        nsView.configure(color: color, lineWidth: lineWidth, animated: animated)
    }
}

final class SpinnerNSView: NSView {
    private let arc = CAShapeLayer()
    private var animated = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.strokeEnd = 0.75
        layer?.addSublayer(arc)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    func configure(color: NSColor, lineWidth: CGFloat, animated: Bool) {
        arc.strokeColor = color.cgColor
        arc.lineWidth = lineWidth
        if self.animated != animated {
            self.animated = animated
            updateAnimation()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        let inset = arc.lineWidth / 2 + 0.5
        arc.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
        updateAnimation()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    private func updateScale() {
        arc.contentsScale = window?.backingScaleFactor ?? 2
    }

    private func updateAnimation() {
        arc.removeAnimation(forKey: "spin")
        guard animated, window != nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -Double.pi * 2 // 시계 방향
        spin.duration = 1
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        arc.add(spin, forKey: "spin")
    }
}

// MARK: - 깜빡이는 점 (주의 필요)

/// 주의 필요 점. 실제 패널에서는 Core Animation 으로 깜빡이고, 스냅숏에서는 정지된 원.
struct PulsingDot: View {
    var color: NSColor = Palette.amberNS
    var animated: Bool = true

    @Environment(\.islandRenderContext) private var renderContext

    var body: some View {
        if renderContext.isSnapshot {
            Circle().fill(Color(nsColor: color))
        } else {
            LayerPulsingDot(color: color, animated: animated)
        }
    }
}

private struct LayerPulsingDot: NSViewRepresentable {
    var color: NSColor
    var animated: Bool

    func makeNSView(context: Context) -> PulsingDotNSView {
        let view = PulsingDotNSView()
        view.configure(color: color, animated: animated)
        return view
    }

    func updateNSView(_ nsView: PulsingDotNSView, context: Context) {
        nsView.configure(color: color, animated: animated)
    }
}

final class PulsingDotNSView: NSView {
    private let dot = CALayer()
    private var animated = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    func configure(color: NSColor, animated: Bool) {
        dot.backgroundColor = color.cgColor
        if self.animated != animated {
            self.animated = animated
            updateAnimation()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = bounds
        dot.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    private func updateAnimation() {
        dot.removeAnimation(forKey: "pulse")
        guard animated, window != nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.25
        pulse.duration = 0.5
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        dot.add(pulse, forKey: "pulse")
    }
}

// MARK: - 세션 상태 표시

/// 접힌 날개/목록에서 쓰는 세션 상태 아이콘
struct StatusIndicator: View {
    let session: AgentSession
    var reduceMotion: Bool
    /// 아이콘 영역 크기 (기본 14)
    var size: CGFloat = 14

    var body: some View {
        Group {
            if session.phase.isWorking {
                SpinnerView(animated: !reduceMotion)
                    .frame(width: size - 1, height: size - 1)
                    .accessibilityLabel("작업 중")
            } else if session.phase == .failed {
                Image(systemName: "xmark.circle")
                    .font(.system(size: size - 1, weight: .medium))
                    .foregroundStyle(Palette.red)
                    .accessibilityLabel("실패")
            } else if session.phase.needsAttention {
                PulsingDot(animated: !reduceMotion)
                    .frame(width: size * 0.57, height: size * 0.57)
                    .accessibilityLabel("확인 필요")
            } else if session.phase == .completed {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: size - 1, weight: .medium))
                    .foregroundStyle(Palette.green)
                    .accessibilityLabel("완료")
            } else {
                Circle()
                    .fill(Palette.muted)
                    .frame(width: size * 0.43, height: size * 0.43)
                    .accessibilityLabel("유휴")
            }
        }
        .frame(width: size, height: size)
    }
}

/// 세션 목록 점 (주의 = 깜빡이는 주황, 작업 중 = 초록, 나머지 = 회색)
struct SessionDot: View {
    let session: AgentSession
    var size: CGFloat = 7
    var reduceMotion: Bool

    var body: some View {
        Group {
            if session.phase.needsAttention {
                PulsingDot(color: session.phase == .failed ? Palette.redNS : Palette.amberNS, animated: !reduceMotion)
            } else {
                Circle().fill(session.phase.isWorking ? Palette.green : Palette.muted)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 세션 상태 요약

/// 세션 상태 요약 "● 2 ● 1 ● 3": 기다리는 중(주황) → 진행 중(초록) → 끝남(회색), 0 인 묶음은 뺀다.
/// 점만 색을 쓰고 숫자는 보조 글자색이라 `+N −M` 과 헷갈리지 않는다. 늘 통째로 그린다 (줄어들지 않음 — 자리는 레이아웃이 잡는다).
struct SessionSummaryChips: View {
    let summary: SessionStatusSummary
    /// 읽어 줄 때 앞에 붙일 말 (예: "다른 세션 ")
    var spokenPrefix = ""

    var body: some View {
        HStack(spacing: IslandMetrics.summaryGroupSpacing) {
            ForEach(summary.groups.map { $0.group }, id: \.self) { group in
                HStack(spacing: IslandMetrics.summaryDotGap) {
                    Circle()
                        .fill(Self.color(group))
                        .frame(width: IslandMetrics.summaryDotSize, height: IslandMetrics.summaryDotSize)
                    Text(verbatim: "\(summary.count(group))")
                        .font(IslandFont.summaryCount)
                        .foregroundStyle(Palette.secondary)
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenPrefix + summary.spokenText)
        .accessibilityHidden(summary.isEmpty)
    }

    static func color(_ group: SessionStatusSummary.Group) -> Color {
        switch group {
        case .waiting: return Palette.amber
        case .working: return Palette.green
        case .done: return Palette.muted
        }
    }
}

/// 백그라운드 작업 수 배지 (겹친 네모 + 숫자). 폭은 `CompactText.backgroundBadgeWidth` 와 같다
struct BackgroundTaskBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: IslandMetrics.backgroundIconGap) {
            Image(systemName: "square.on.square")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: IslandMetrics.backgroundIconSize)
            Text(verbatim: "\(count)")
                .font(IslandFont.summaryCount)
        }
        .foregroundStyle(Palette.secondary)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("백그라운드 작업 \(count)개")
    }
}

// MARK: - diff

/// `+N −M` (초록/빨강 고정폭)
struct DiffStatText: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "+\(added)").foregroundStyle(Palette.green)
            Text(verbatim: "\u{2212}\(removed)").foregroundStyle(Palette.red)
        }
        .font(IslandFont.mono)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(added)줄 추가, \(removed)줄 삭제")
    }
}

enum DiffPresentation {
    /// 노치에 보여줄 diff 줄: 변경 줄 위주로 최대 3줄
    static func visibleLines(_ diff: DiffSnippet) -> [DiffLine] {
        let changed = diff.lines.filter { $0.kind != .context }
        let source = changed.isEmpty ? diff.lines : changed
        return Array(source.prefix(IslandMetrics.maxDiffRows))
    }

    /// 세션 cwd 기준 상대 경로 (예: src/auth/session.ts)
    static func displayPath(_ diff: DiffSnippet, cwd: String?) -> String {
        if let cwd, !cwd.isEmpty {
            let prefix = cwd.hasSuffix("/") ? cwd : cwd + "/"
            if diff.filePath.hasPrefix(prefix) {
                return String(diff.filePath.dropFirst(prefix.count))
            }
        }
        return diff.fileName
    }
}

/// 미니 diff 행 (고정폭 11pt, 색 배경)
struct DiffRowsView: View {
    let lines: [DiffLine]

    var body: some View {
        VStack(alignment: .leading, spacing: IslandMetrics.diffRowSpacing) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
    }

    private func row(_ line: DiffLine) -> some View {
        let style = Self.style(for: line.kind)
        return Text(verbatim: "\(style.sign) \(line.text)")
            .font(IslandFont.mono)
            .foregroundStyle(style.foreground)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: IslandMetrics.diffRowHeight, maxHeight: IslandMetrics.diffRowHeight, alignment: .leading)
            .background(style.background, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityLabel(Self.accessibilityPrefix(line.kind) + line.text)
    }

    private static func style(for kind: DiffLine.Kind) -> (sign: String, foreground: Color, background: Color) {
        switch kind {
        case .added: return ("+", Palette.green, Palette.addBackground)
        case .removed: return ("-", Palette.red, Palette.removeBackground)
        case .context: return (" ", Palette.muted, .clear)
        }
    }

    private static func accessibilityPrefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: return "추가: "
        case .removed: return "삭제: "
        case .context: return ""
        }
    }
}

// MARK: - 버튼

struct IslandButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        IslandButtonBody(configuration: configuration, prominent: prominent)
    }
}

/// 비활성 상태를 읽으려고 따로 둔 버튼 본문 (비활성이면 흐리게)
private struct IslandButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(IslandFont.body)
            .lineLimit(1)
            .foregroundStyle(prominent ? Palette.allowText : Palette.text)
            .padding(.horizontal, 10)
            .frame(height: IslandMetrics.buttonHeight)
            .background(prominent ? Palette.green : Palette.row, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 아이콘만 있는 작은 버튼 (설정 톱니 등)
struct IslandIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - 상단 행 (날개)

/// 카드 상단 행 (부분 2 맨 위): 왼쪽 · 오른쪽
struct WingRow<Leading: View, Trailing: View>: View {
    let height: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            trailing
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, IslandMetrics.wingPadding)
        .frame(height: height)
        .font(IslandFont.body)
        .foregroundStyle(Palette.text)
        .lineLimit(1)
    }
}

/// 펼친 카드 공통 틀: 부분 2(몸통) 맨 위 상단 행, 그 아래 본문. 부분 1(접힌 모양) 자리에는 아무것도 두지 않는다.
struct CardScaffold<Leading: View, Trailing: View, Content: View>: View {
    let layout: IslandLayout
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        let header = layout.header
        VStack(spacing: 0) {
            WingRow(height: header.height) {
                leading
            } trailing: {
                trailing
            }
            .padding(.leading, header.leftInset)
            .padding(.trailing, header.rightInset)
            .padding(.top, header.top)

            Color.clear.frame(height: max(0, layout.contentTop - header.top - header.height))

            content
                .padding(.leading, layout.contentLeftInset)
                .padding(.trailing, layout.contentRightInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// 스냅숏 렌더링에선 ScrollView 를 그릴 수 없어서 잘린 VStack 으로 대신한다.
struct IslandScrollable<Content: View>: View {
    var showsIndicators = false
    @ViewBuilder var content: Content

    @Environment(\.islandRenderContext) private var renderContext

    var body: some View {
        if renderContext.isSnapshot {
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ScrollView(.vertical) { content }
                .scrollIndicators(showsIndicators ? .automatic : .never)
        }
    }
}

/// 실제 시각(1초/1분 주기) 또는 스냅숏 고정 시각으로 내용을 그린다.
struct IslandClock<Content: View>: View {
    var everySecond = false
    @ViewBuilder var content: (Date) -> Content

    @Environment(\.islandRenderContext) private var renderContext

    var body: some View {
        if let now = renderContext.fixedNow {
            content(now)
        } else if everySecond {
            TimelineView(.periodic(from: .now, by: 1)) { context in content(context.date) }
        } else {
            TimelineView(.everyMinute) { context in content(context.date) }
        }
    }
}

// MARK: - 문자열 포맷

enum IslandFormat {
    /// 2m 14s / 45s / 1h 04m
    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, seconds) }
        return "\(seconds)s"
    }

    /// 경과 분 (유휴 · 12분)
    static func idleText(since date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "방금" }
        if minutes < 60 { return "\(minutes)분" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)시간" }
        return "\(hours / 24)일"
    }

    /// 접힌 상태(날개 · 노치 아래 띠 · 알약)용 짧은 툴 이름 (예: "Bash", "Edit", MCP 는 서버 이름 "Claude_Browser").
    /// 명령 · 경로 · MCP 툴 이름은 펼친 타임라인과 카드에서 보여준다
    static func shortToolTitle(_ session: AgentSession) -> String {
        switch session.phase {
        case .compacting: return session.phase.label
        case .thinking where session.currentActivity?.status != .running: return session.phase.label
        default: break
        }
        guard let activity = session.currentActivity else { return session.phase == .thinking ? session.phase.label : "" }
        return activity.shortLabel
    }

    /// 세션 목록 부제 (승인 대기 / Edit 중 / 유휴 · 12분). 정해진 단계 이름은 메뉴바 메뉴와 같다 (`SessionPhase.label`)
    static func subtitle(_ session: AgentSession, now: Date) -> String {
        switch session.phase {
        case .runningTool:
            let tool = shortToolTitle(session)
            return tool.isEmpty ? "실행 중" : "\(tool) 중"
        case .completed where session.hasUnseenCompletion:
            return session.phase.label
        case .idle, .completed:
            // 쉬는 중이어도 백그라운드 작업이 돌면 그 문구 (`AgentSession.backgroundStatusText`)
            return session.backgroundStatusText ?? "유휴 · \(idleText(since: session.lastEventAt, now: now))"
        case .thinking, .waitingPermission, .waitingInput, .compacting, .failed:
            return session.phase.label
        }
    }

    /// 백그라운드 작업 종류별 내역 (예: "서브에이전트 2 · 셸 1"). 한 종류뿐이면 이름만 ("셸"), 없으면 nil
    static func backgroundBreakdown(_ session: AgentSession) -> String? {
        let parts = [
            ("서브에이전트", session.activeSubagents),
            ("셸", session.backgroundShells),
            ("기타", session.backgroundOthers),
        ].filter { $0.1 > 0 }
        guard !parts.isEmpty else { return nil }
        if parts.count == 1 { return parts[0].0 }
        return parts.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    /// 한 줄로 보여줄 텍스트 (줄바꿈 제거)
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
