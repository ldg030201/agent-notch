import SwiftUI
import NotchCore

/// 패널 하나의 루트 뷰. 패널은 화면 맨 위에 화면 폭 전체로 붙어 있고, 아일랜드는 레이아웃 위치에 놓인다.
struct IslandRootView: View {
    let screenID: ScreenID
    let presentation: PresentationController
    /// 패널 수명 동안 유지되는 뷰 상태 (@State 대신 사용 — 아래 IslandViewState 참고)
    let viewState: IslandViewState

    var body: some View {
        ZStack(alignment: .topLeading) {
            if presentation.geometries[screenID] != nil {
                IslandContainer(screenID: screenID, presentation: presentation, viewState: viewState)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }
}

/// 아일랜드 본체: 검정 모양 + 모드별 내용.
/// - 크기 · 위치 · 모양은 한 스프링으로 함께 움직인다 (종류가 바뀌면 `IslandMotion.resize`, 같은 종류 안의 크기 변화는 `adjust`).
/// - 검정 모양 · 잘라내기 · 클릭 모양은 패널 전체 기준(`IslandPanelShape`)으로 스펙 하나에서 그린다.
///   프레임 크기 · 오프셋을 따로 애니메이션하면 SwiftUI 가 둘을 모양 보간과 어긋나게 움직일 때(재조준 · 프레임 밀림)
///   부분 1 이 옆으로 튀거나 넓어져 보인다.
/// - 내용 구조(`IslandContentKey`: 모드 종류 · 접힌 표시 방식)가 바뀌면 이전 내용은 이전 레이아웃 그대로,
///   화면 위 그 자리에 머문 채 흐려지고, 모양이 거의 자리 잡은 뒤 새 내용이 나타난다.
/// - 호버 확대는 모양이 다 자리 잡은 뒤에만 시작하고, 내용이 바뀔 때 마우스가 위에 있었으면 한 번 나갔다 들어와야 한다.
/// - 아이콘 구멍은 패널 기준으로 늘 진짜 아이콘 자리에 뚫는다 (모양 애니메이션과 무관).
struct IslandContainer: View {
    let screenID: ScreenID
    let presentation: PresentationController

    let viewState: IslandViewState

    @Environment(\.accessibilityReduceMotion) private var environmentReduceMotion

    var body: some View {
        let mode = presentation.mode(for: screenID)
        let layout = presentation.layout(for: screenID, mode: mode)
        let concealed = presentation.isConcealed(screenID)
        let reduceMotion = presentation.reduceMotion || environmentReduceMotion
        let contentKey = IslandContentKey(mode: mode, layout: layout)
        let outgoing = viewState.outgoingContent(current: mode, layout: layout, reduceMotion: reduceMotion)
        let shown = outgoing ?? IslandShownContent(mode: mode, layout: layout)
        let swapping = outgoing != nil || !viewState.contentVisible
        let pointerOver = presentation.hoveredScreenID == screenID
        // 전환 중 · 아이콘 구멍과 겹칠 때는 호버 표시를 하지 않는다
        let wantsHover = pointerOver && !mode.isOpen && !swapping && !reduceMotion && !layout.overlapsIconHoles
        // 모양이 다 자리 잡은 뒤에만 호버 표시를 시작한다 (전환 끝에 깜빡이지 않게)
        let scaled = viewState.hoverScale(wants: wantsHover)
        let spec = layout.shapeSpec
        let shape = IslandPanelShape(spec: spec)
        let invisible = mode == .hidden || concealed
        // 모드 종류가 바뀔 때만 resize, 같은 종류 안의 변화(표시 방식만 바뀌는 교체 포함)는 adjust
        let motion = outgoing.map { $0.mode.kind != mode.kind } == true
            ? IslandMotion.resize(reduceMotion: reduceMotion)
            : IslandMotion.adjust(reduceMotion: reduceMotion)

        ZStack(alignment: .topLeading) {
            IslandContentView(
                mode: shown.mode,
                layout: shown.layout,
                presentation: presentation,
                reduceMotion: reduceMotion
            )
            .frame(width: shown.layout.size.width, height: shown.layout.size.height, alignment: .topLeading)
            .opacity(viewState.contentVisible ? 1 : 0)
            // 마우스를 올리면 내용만 살짝 밝게 (모양 크기는 바꾸지 않아 노치 밖으로 삐져나오지 않음)
            .brightness(scaled ? 0.12 : 0)
            // 그 내용을 배치한 레이아웃 자리에 둔다: 사라지는 이전 내용은 화면 위 원래 자리에 그대로 머문다
            .offset(x: shown.layout.origin.x, y: shown.layout.origin.y)
            // 내용이 바뀌는 순간엔 새 뷰로 (이전 내용의 자리가 새 내용으로 이어지지 않게)
            .id(shown.key)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            IslandBackground(shape: IslandPanelShape(spec: spec, holes: layout.iconHoles))
        }
        .clipShape(shape)
        // 아이콘 구멍 위는 클릭을 받지 않는다 (마우스 상태 갱신 전에 눌려도 펼쳐지지 않게). 통과 영역은 프레임 기준 → 패널 기준
        .contentShape(IslandHitShape(
            shape: shape,
            cutouts: layout.passThroughRects.map { $0.offsetBy(dx: layout.origin.x, dy: layout.origin.y) }
        ))
        .opacity(invisible ? 0 : 1)
        .allowsHitTesting(!invisible)
        .animation(motion, value: layout.animationKey)
        .animation(IslandMotion.hover, value: scaled)
        .animation(.easeOut(duration: 0.2), value: invisible)
        .onTapGesture {
            presentation.handleIslandClick(on: screenID)
        }
        .onChange(of: contentKey) { _, key in
            beginContentSwap(to: key, reduceMotion: reduceMotion)
        }
        .onChange(of: layout.animationKey) { _, _ in
            viewState.layoutChanged()
        }
        .onChange(of: pointerOver) { _, over in
            if !over { viewState.pointerLeft() }
        }
        .onAppear {
            // 패널이 다시 붙었을 때 기억한 내용이 다른 구조면 교체를 시작한다 (onChange 는 처음 값엔 불리지 않음)
            if viewState.needsSwap(current: contentKey) { beginContentSwap(to: contentKey, reduceMotion: reduceMotion) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AgentNotch")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(mode == .expanded ? "클릭하면 접혀" : "클릭하면 펼쳐져")
    }

    /// 내용 구조가 바뀌면: 이전 내용을 흐리고, 모양이 거의 자리 잡은 뒤(`IslandViewState.contentDelay`) 새 내용을 나타낸다
    private func beginContentSwap(to key: IslandContentKey, reduceMotion: Bool) {
        let state = viewState
        state.swapTask?.cancel()
        state.swapTask = nil
        // 마우스가 위에 있는 채로 펼치거나 접혔으면 나갔다 들어올 때까지 커지지 않는다
        if presentation.hoveredScreenID == screenID { state.blockHover() }
        switch state.beginSwap(to: key, reduceMotion: reduceMotion) {
        case .none:
            if !state.contentVisible {
                withAnimation(reduceMotion ? nil : IslandMotion.contentFadeIn) { state.contentVisible = true }
            }
        case .restore:
            // 전환 중 원래 종류로 돌아왔다: 흐리던 내용을 다시 보인다
            withAnimation(IslandMotion.contentFadeIn) { state.contentVisible = true }
        case .fadeOut:
            withAnimation(IslandMotion.contentFadeOut) { state.contentVisible = false }
            let delay = state.contentDelay(to: key)
            state.swapTask = Task { @MainActor in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                state.swapTask = nil
                // 이전 내용 → 지금 내용 (자리 이동 없이 바로), 그다음 나타난다
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { state.finishSwap() }
                withAnimation(IslandMotion.contentFadeIn) { state.contentVisible = true }
            }
        }
    }
}

/// 아일랜드 검은 배경 (아이콘 구멍은 `IslandShape.holes` 로 뚫는다)
struct IslandBackground<S: Shape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(Palette.background)
            .accessibilityHidden(true)
    }
}

/// 클릭을 받는 모양: 아일랜드 모양에서 클릭 통과 영역(아이콘 구멍)을 뺀 것
struct IslandHitShape: Shape {
    var shape: IslandPanelShape
    /// 패널 기준
    let cutouts: [CGRect]

    var animatableData: IslandShapeSpec {
        get { shape.spec }
        set { shape.spec = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let base = shape.path(in: rect)
        guard !cutouts.isEmpty else { return base }
        var holes = Path()
        for cutout in cutouts { holes.addRect(cutout) }
        return base.subtracting(holes)
    }
}

/// 그리고 있는 내용: 모드와 그 모드를 배치한 레이아웃
struct IslandShownContent: Equatable {
    var mode: IslandMode
    var layout: IslandLayout

    var key: IslandContentKey { IslandContentKey(mode: mode, layout: layout) }
}

/// 내용 뷰 구조: 모드 종류 + 접힌 상태 표시 방식.
/// 모드 종류가 같아도 표시 방식이 바뀌면(앞 앱 메뉴 길이로 왼쪽 날개 ↔ 노치 아래 띠 등) 내용을 통째로 바꾼다.
/// 그대로 두면 이전 · 새 내용이 프레임을 따라 200pt 가까이 미끄러지며 겹쳐 보인다.
struct IslandContentKey: Hashable {
    enum Branch: Hashable {
        /// 펼친 카드 · 숨김
        case card
        case wings(WingArrangement)
        case strip, line, pill, dot
    }

    var kind: IslandMode.Kind
    var branch: Branch

    init(mode: IslandMode, layout: IslandLayout) {
        kind = mode.kind
        switch layout.compact {
        case nil: branch = .card
        case let .wings(spec): branch = .wings(spec.arrangement)
        case .strip: branch = .strip
        case .line: branch = .line
        case .pill: branch = .pill
        case .dot: branch = .dot
        }
    }
}

/// 아일랜드 뷰의 일시 상태.
/// macOS 27 SDK 에서 `@State` 가 SwiftUIMacros 플러그인을 요구하는데 Command Line Tools 에는 그 플러그인이 없어서,
/// 패널마다 하나씩 만든 관찰 가능 객체로 대신한다.
///
/// 내용 교체 규칙 (내용 구조 `IslandContentKey` 가 바뀔 때):
/// 1. 구조가 바뀐 첫 렌더 (`onChange` 전): 마지막으로 그린 이전 내용을 그대로 그린다 (새 내용이 한 프레임 끼지 않게)
/// 2. `beginSwap`: 이전 내용을 `outgoing` 으로 고정하고 흐린다
/// 3. `finishSwap` (`contentDelay(to:)` 뒤): `outgoing` 과 기억한 내용을 비워 다음 렌더부터 지금 모드를 그린다
/// 스냅숏 시트(`SnapshotContentSwapCheck`)가 이 객체를 그대로 돌려 순서별로 검사한다.
///
/// 호버 확대 규칙: 모양이 바뀐 뒤 `IslandMotion.settleDelay` 가 지나야 커지기 시작하고(이미 커졌으면 유지),
/// 내용이 바뀔 때 마우스가 위에 있었으면 마우스가 한 번 나갈 때까지 커지지 않는다.
@MainActor
@Observable
final class IslandViewState {
    /// 구조가 바뀌는 동안 흐려지며 남는 이전 내용 (그때 레이아웃 그대로)
    private(set) var outgoing: IslandShownContent?
    var contentVisible = true
    /// 마지막으로 그린 지금 내용 (구조가 바뀐 첫 렌더에 이전 내용을 바로 쓰려고 기억)
    @ObservationIgnored private(set) var lastShown: IslandShownContent?
    @ObservationIgnored var swapTask: Task<Void, Never>?

    /// 마지막 크기 · 위치 변화 뒤 모양이 다 자리 잡았는지
    private(set) var shapeSettled = true
    /// 내용이 바뀔 때 마우스가 위에 있었음 → 마우스가 나갈 때까지 호버 확대 안 함
    private(set) var hoverBlocked = false
    /// 지금 호버로 커져 있는지 (렌더마다 갱신하는 기억값)
    @ObservationIgnored private var hoverScaled = false
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    enum SwapStart: Equatable {
        /// 바꿀 내용 없음 (이미 지금 종류를 그리는 중)
        case none
        /// 이전 내용을 흐리고 `contentDelay` 뒤 `finishSwap`
        case fadeOut
        /// 전환 중 원래 종류로 돌아옴: 흐리던 내용을 다시 보인다
        case restore
    }

    init() {}

    /// 지금 그릴 이전 내용 (없으면 현재 모드를 그린다). 렌더마다 부른다
    func outgoingContent(current mode: IslandMode, layout: IslandLayout, reduceMotion: Bool) -> IslandShownContent? {
        let current = IslandShownContent(mode: mode, layout: layout)
        let key = current.key
        if let pending = outgoing {
            if pending.key != key { return pending }
            // 전환 중 원래 구조로 돌아왔으면 지금 내용을 그린다
        } else if !reduceMotion, let last = lastShown, last.key != key {
            return last
        }
        lastShown = current
        return nil
    }

    /// 내용 구조가 바뀌었을 때 (`onChange`)
    func beginSwap(to key: IslandContentKey, reduceMotion: Bool) -> SwapStart {
        if reduceMotion {
            outgoing = nil
            lastShown = nil
            return .none
        }
        if let pending = outgoing {
            guard pending.key == key else { return .fadeOut }
            outgoing = nil
            lastShown = nil
            return .restore
        }
        guard let last = lastShown, last.key != key else { return .none }
        outgoing = last
        lastShown = nil
        return .fadeOut
    }

    /// 흐린 이전 내용 뒤 새 내용을 보일 때까지의 지연.
    /// 모드 종류가 바뀌면 `contentDelay`, 같은 모드에서 표시 방식만 바뀌면 프레임이 멀리 옮겨 가므로 `branchContentDelay`
    func contentDelay(to key: IslandContentKey) -> Duration {
        outgoing.map { $0.mode.kind == key.kind } == true ? IslandMotion.branchContentDelay : IslandMotion.contentDelay
    }

    /// 교체 끝: 다음 렌더부터 지금 모드를 그린다
    func finishSwap() {
        outgoing = nil
        lastShown = nil
    }

    /// 기억한 내용이 지금과 다른 구조인지 (패널이 다시 붙었을 때 확인)
    func needsSwap(current key: IslandContentKey) -> Bool {
        if let pending = outgoing { return pending.key != key }
        return lastShown.map { $0.key != key } ?? false
    }

    // MARK: 호버 확대

    /// 이번 렌더에서 호버로 커질지. 커지기 시작하는 건 모양이 자리 잡은 뒤에만 (이미 커져 있으면 유지)
    func hoverScale(wants: Bool) -> Bool {
        guard wants, !hoverBlocked else {
            hoverScaled = false
            return false
        }
        if !hoverScaled, shapeSettled { hoverScaled = true }
        return hoverScaled
    }

    /// 크기 · 위치 · 모양이 바뀌었다: `settleDelay` 동안 호버 확대를 새로 시작하지 않는다
    func layoutChanged() {
        settleTask?.cancel()
        if shapeSettled { shapeSettled = false }
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: IslandMotion.settleDelay)
            guard !Task.isCancelled, let self else { return }
            self.markSettled()
        }
    }

    /// 모양이 다 자리 잡았다 (`layoutChanged` 뒤 `settleDelay`)
    func markSettled() {
        settleTask?.cancel()
        settleTask = nil
        if !shapeSettled { shapeSettled = true }
    }

    /// 마우스가 아일랜드 위에 있는 채로 내용이 바뀌었다 (펼치기 · 접기)
    func blockHover() {
        if !hoverBlocked { hoverBlocked = true }
    }

    /// 마우스가 아일랜드를 벗어났다: 다음에 들어오면 다시 커질 수 있다
    func pointerLeft() {
        if hoverBlocked { hoverBlocked = false }
    }
}

/// 모드별 내용
struct IslandContentView: View {
    let mode: IslandMode
    let layout: IslandLayout
    let presentation: PresentationController
    let reduceMotion: Bool

    var body: some View {
        switch mode {
        case .hidden:
            Color.clear
        case .idle:
            IdleCompactView(layout: layout, summary: presentation.compactSummary, reduceMotion: reduceMotion)
        case .working:
            CompactSessionView(
                session: presentation.compactSession,
                summary: presentation.compactSummary,
                layout: layout,
                reduceMotion: reduceMotion
            )
        case let .peek(sessionID, diff):
            PeekView(
                session: presentation.store.sessions[sessionID],
                diff: diff,
                textLine: presentation.streamingLine(for: sessionID),
                layout: layout,
                actions: presentation.actions,
                reduceMotion: reduceMotion
            )
        case let .permission(request, queueCount):
            PermissionView(
                request: request,
                queueCount: queueCount,
                session: presentation.store.sessions[request.sessionID],
                layout: layout,
                presentation: presentation,
                reduceMotion: reduceMotion
            )
        case let .needsInput(sessionID, message, isPermissionPrompt):
            NeedsInputView(
                session: presentation.store.sessions[sessionID],
                sessionID: sessionID,
                message: message,
                isPermissionPrompt: isPermissionPrompt,
                layout: layout,
                presentation: presentation,
                reduceMotion: reduceMotion
            )
        case let .done(sessionID):
            CompletionView(
                session: presentation.store.sessions[sessionID],
                failed: false,
                textLine: presentation.streamingLine(for: sessionID),
                layout: layout
            )
        case let .failed(sessionID):
            CompletionView(
                session: presentation.store.sessions[sessionID],
                failed: true,
                textLine: nil,
                layout: layout
            )
        case .expanded:
            ExpandedView(layout: layout, presentation: presentation, reduceMotion: reduceMotion)
        }
    }
}
