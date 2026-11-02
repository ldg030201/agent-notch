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
/// - 내용 구조(`IslandContentKey`: 모드 종류 · 접힌 표시 방식 · 카드의 요청)가 바뀌면 이전 내용은 이전 레이아웃 그대로,
///   화면 위 그 자리에 머문 채 흐려지고, 모양이 거의 자리 잡은 뒤 새 내용이 나타난다.
/// - 호버 밝힘(내용만 살짝 밝게)은 모양이 다 자리 잡은 뒤에만 시작하고, 내용이 바뀔 때 마우스가 위에 있었으면 한 번 나갔다 들어와야 한다.
/// - 클릭 모양은 그린 모양 + 레이아웃 클릭 영역(`hitRects`, 점 둘레 등). 패널이 클릭을 받는 자리(`ScreenManager`)와 같다.
struct IslandContainer: View {
    let screenID: ScreenID
    let presentation: PresentationController

    let viewState: IslandViewState

    var body: some View {
        let mode = presentation.mode(for: screenID)
        let layout = presentation.layout(for: screenID, mode: mode)
        let concealed = presentation.isConcealed(screenID, mode: mode)
        // 동작 줄이기: 시스템 설정을 표시 상태가 들고 있다 (바뀌면 `ScreenManager` 가 알려 준다)
        let reduceMotion = presentation.reduceMotion
        let contentKey = IslandContentKey(mode: mode, layout: layout)
        let outgoing = viewState.outgoingContent(current: mode, layout: layout, reduceMotion: reduceMotion)
        let shown = outgoing ?? IslandShownContent(mode: mode, layout: layout)
        let swapping = outgoing != nil || !viewState.contentVisible
        let pointerOver = presentation.hoveredScreenID == screenID
        // 전환 중에는 호버 표시를 하지 않는다. 내용 밝기만 바꾼다
        let wantsHover = pointerOver && !mode.isOpen && !swapping && !reduceMotion
        // 모양이 다 자리 잡은 뒤에만 호버 표시를 시작한다 (전환 끝에 깜빡이지 않게)
        let lit = viewState.hoverHighlight(wants: wantsHover)
        let spec = layout.shapeSpec
        let shape = IslandPanelShape(spec: spec)
        let invisible = mode == .hidden || concealed
        // 모드 종류가 바뀔 때만 resize, 같은 종류 안의 변화(표시 방식만 바뀌는 교체 포함)는 adjust
        let motion = outgoing.map { $0.mode.kind != mode.kind } == true
            ? IslandMotion.resize(reduceMotion: reduceMotion)
            : IslandMotion.adjust

        ZStack(alignment: .topLeading) {
            IslandContentView(
                mode: shown.mode,
                layout: shown.layout,
                presentation: presentation,
                reduceMotion: reduceMotion
            )
            .frame(width: shown.layout.size.width, height: shown.layout.size.height, alignment: .topLeading)
            // 투명하게 숨은 동안 스피너 · 깜빡이는 점을 멈춘다 (보이지 않는 채로 계속 합성되지 않게)
            .environment(\.islandMotionPaused, invisible)
            .opacity(viewState.contentVisible ? 1 : 0)
            // 마우스를 올리면 내용만 살짝 밝게 (모양 크기는 바꾸지 않아 노치 밖으로 삐져나오지 않음)
            .brightness(lit ? 0.12 : 0)
            // 그 내용을 배치한 레이아웃 자리에 둔다: 사라지는 이전 내용은 화면 위 원래 자리에 그대로 머문다
            .offset(x: shown.layout.origin.x, y: shown.layout.origin.y)
            // 내용이 바뀌는 순간엔 새 뷰로 (이전 내용의 자리가 새 내용으로 이어지지 않게)
            .id(shown.key)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            IslandBackground(shape: shape)
        }
        // 내용은 그린 모양으로 자른다
        .clipShape(shape)
        // 테스트판: 빨간 테두리 (모양과 함께 움직이고, 클릭은 받지 않는다)
        .overlay {
            if presentation.showsTestBorder {
                IslandBorderShape(spec: spec).stroke(Palette.testBorder, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        // 클릭 모양: 그린 모양 + 레이아웃 클릭 영역(점 둘레처럼 모양보다 넓힌 자리).
        // 패널은 클릭 영역 안에서 클릭을 받으므로(`ScreenManager`) 여기서도 받아야 삼키지 않는다
        .contentShape(IslandHitShape(layout: layout, shape: shape))
        // 화면 기하가 바뀐 업데이트(해상도 · 노치 유무 변경)는 새 자리에 바로 그린다. 스프링으로 넘어가면 노치 위치까지
        // 보간돼서 노치를 덮는 목이 화면 왼쪽 끝 쪽으로 늘어나, 검은 띠가 메뉴바를 덮고 지나간다
        .transaction(value: presentation.geometries[screenID]) { $0.animation = nil }
        .animation(motion, value: layout.animationKey)
        .animation(IslandMotion.hover, value: lit)
        // 숨김 · 보임 페이드는 모양 스프링 바깥에 둔다: 안쪽에 두면 같은 업데이트에 모양이 바뀔 때 스프링이 투명도까지 가져가
        // 0.2초 페이드 대신 반투명한 검은 모양이 숨김 자리로 미끄러지며 오래 남는다
        .opacity(invisible ? 0 : 1)
        .allowsHitTesting(!invisible)
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
            // 지금 내용이 바로 보인다 (요청 카드면 승인 대기를 이때부터 잰다). 패널마다 새 뷰 상태이고, 사라질 때 교체를 비우므로
            // (`cancelSwap`) 붙는 순간 이어서 할 교체는 없다
            presentation.contentDidAppear(contentKey, on: screenID)
        }
        .onDisappear {
            // 패널을 내리거나 다시 만들면 이 뷰 상태는 버려진다: 남은 교체가 사라진 뷰 대신 승인 대기를 건드리지 않게
            viewState.cancelSwap()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AgentNotch")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Self.accessibilityHint(for: mode, shortcuts: presentation.shortcutEnabled))
    }

    /// 아일랜드 배경을 클릭했을 때 일어나는 일 (`PresentationController.handleIslandClick`).
    /// 알림 카드는 접거나 펼치지 않고 패널이 키 윈도우가 되어 단축키를 받는다 (설정 → 단축키에서 켠 것만 알린다)
    static func accessibilityHint(for mode: IslandMode, shortcuts: (PresentationController.ShortcutGroup) -> Bool) -> String {
        /// 켠 단축키만 모아 "클릭하면 단축키로 …: a, b" 로 만든다
        func keys(_ verb: String, _ items: [(String, PresentationController.ShortcutGroup)]) -> String {
            let enabled = items.filter { shortcuts($0.1) }.map(\.0)
            return enabled.isEmpty ? "" : "클릭하면 단축키로 \(verb): " + enabled.joined(separator: ", ")
        }
        switch mode {
        case .hidden:
            return ""
        case .expanded:
            return "클릭하면 접혀"
        case .idle, .working, .peek, .done, .failed:
            return "클릭하면 펼쳐져"
        case let .permission(request, _):
            switch request.kind {
            case .permission:
                return keys("결정할 수 있어", [("⌘↩ 허용", .permission), ("⌘⌫ 거부", .permission), ("⎋ 접기", .collapse)])
            case .question:
                return keys("답할 수 있어", [("숫자 키로 고르기", .interaction), ("↩ 다음 · 보내기", .interaction), ("⎋ 접기", .collapse)])
            case .plan:
                return keys("결정할 수 있어", [("↩ 승인", .interaction), ("⎋ 접기", .collapse)])
            }
        case .needsInput:
            return shortcuts(.collapse) ? "클릭하면 ⎋ 로 접을 수 있어" : ""
        }
    }

    /// 내용 구조가 바뀌면: 이전 내용을 흐리고, 모양이 거의 자리 잡은 뒤(`IslandViewState.contentDelay`) 새 내용을 나타낸다.
    /// 표시 상태에 내용이 바뀌기 시작함 · 새 내용이 보이기 시작함을 알린다 (요청 카드의 승인 대기는 새 내용이 나타난 때부터 잰다)
    private func beginContentSwap(to key: IslandContentKey, reduceMotion: Bool) {
        let state = viewState
        let presentation = presentation
        let screenID = screenID
        state.swapTask?.cancel()
        state.swapTask = nil
        presentation.contentWillChange(on: screenID)
        // 마우스가 위에 있는 채로 펼치거나 접혔으면 나갔다 들어올 때까지 밝히지 않는다
        if presentation.hoveredScreenID == screenID { state.blockHover() }
        switch state.beginSwap(to: key, reduceMotion: reduceMotion) {
        case .none:
            if !state.contentVisible {
                withAnimation(reduceMotion ? nil : IslandMotion.contentFadeIn) { state.contentVisible = true }
            }
            presentation.contentDidAppear(key, on: screenID)
        case .restore:
            // 전환 중 원래 종류로 돌아왔다: 흐리던 내용을 다시 보인다
            withAnimation(IslandMotion.contentFadeIn) { state.contentVisible = true }
            presentation.contentDidAppear(key, on: screenID)
        case .fadeOut:
            withAnimation(IslandMotion.contentFadeOut) { state.contentVisible = false }
            // 새 내용을 보일 때는 뷰 상태가 정한다 (흐린 채 기다리는 중에 또 바뀌어도 미루지 않는다, `beginSwap`)
            let deadline = state.swapDeadline ?? .now
            state.swapTask = Task { @MainActor in
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard !Task.isCancelled else { return }
                state.swapTask = nil
                // 이전 내용 → 지금 내용 (자리 이동 없이 바로), 그다음 나타난다
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { state.finishSwap() }
                withAnimation(IslandMotion.contentFadeIn) { state.contentVisible = true }
                presentation.contentDidAppear(key, on: screenID)
            }
        }
    }
}

/// 아일랜드 검은 배경
struct IslandBackground<S: Shape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(Palette.background)
            .accessibilityHidden(true)
    }
}

/// 클릭을 받는 모양: 아일랜드 모양 + 클릭 영역(`IslandLayout.hitRects`).
/// 클릭 영역은 애니메이션하지 않고 지금 레이아웃 값 그대로다 (`ScreenManager` 의 클릭 판정과 같다).
/// 모양과 클릭 영역은 하위 경로로 이어 붙인다 (nonzero 규칙이라 합집합, 불리언 연산 없음)
struct IslandHitShape: Shape {
    var shape: IslandPanelShape
    /// 클릭 영역 (패널 기준)
    let hitRects: [CGRect]

    init(layout: IslandLayout, shape: IslandPanelShape) {
        self.shape = shape
        hitRects = layout.panelHitRects
    }

    var animatableData: IslandShapeSpec {
        get { shape.spec }
        set { shape.spec = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = shape.path(in: rect)
        for hit in hitRects { path.addRect(hit) }
        return path
    }
}

/// 그리고 있는 내용: 모드와 그 모드를 배치한 레이아웃
struct IslandShownContent: Equatable {
    var mode: IslandMode
    var layout: IslandLayout

    var key: IslandContentKey { IslandContentKey(mode: mode, layout: layout) }
}

/// 내용 뷰 구조: 모드 종류 + 접힌 상태 표시 방식 + 카드의 요청.
/// 모드 종류가 같아도 표시 방식이 바뀌면(메뉴바 빈 곳이 줄어 알약 ↔ 점, 외부 모니터 표시를 바꿈 등) 내용을 통째로 바꾼다.
/// 그대로 두면 이전 · 새 내용이 프레임을 따라 200pt 가까이 미끄러지며 겹쳐 보인다.
/// 권한 요청 · 질문 · 계획 승인 카드는 요청이 바뀌어도(대기열의 다음 요청) 바꾼다: 같은 높이의 카드 글자만 제자리에서
/// 바뀌면 새 요청이 온 줄 모르고 이어서 누르기 쉽다 (승인은 새 요청 카드가 나타난 뒤 `PresentationController.shortcutSettleDelay` 가 지나야 받는다)
struct IslandContentKey: Hashable {
    enum Branch: Hashable {
        /// 펼친 카드 · 숨김
        case card
        case strip, pill, dot
    }

    var kind: IslandMode.Kind
    var branch: Branch
    /// 카드에 보이는 권한 요청 · 질문 · 계획 승인 (아니면 nil)
    var request: UUID?

    init(mode: IslandMode, layout: IslandLayout) {
        kind = mode.kind
        if case let .permission(info, _) = mode { request = info.id } else { request = nil }
        switch layout.compact {
        case nil: branch = .card
        case .strip: branch = .strip
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
/// 호버 밝힘 규칙: 모양이 바뀐 뒤 `IslandMotion.settleDelay` 가 지나야 밝아지기 시작하고(이미 밝으면 유지),
/// 내용이 바뀔 때 마우스가 위에 있었으면 마우스가 한 번 나갈 때까지 밝히지 않는다.
@MainActor
@Observable
final class IslandViewState {
    /// 구조가 바뀌는 동안 흐려지며 남는 이전 내용 (그때 레이아웃 그대로)
    private(set) var outgoing: IslandShownContent?
    var contentVisible = true
    /// 마지막으로 그린 지금 내용 (구조가 바뀐 첫 렌더에 이전 내용을 바로 쓰려고 기억)
    @ObservationIgnored private(set) var lastShown: IslandShownContent?
    @ObservationIgnored var swapTask: Task<Void, Never>?
    /// 흐린 이전 내용 뒤 새 내용을 보일 시각 (`beginSwap` 이 처음 흐리기 시작할 때 정하고, 기다리는 중 내용이 또 바뀌어도 미루지 않는다)
    @ObservationIgnored private(set) var swapDeadline: ContinuousClock.Instant?

    /// 마지막 크기 · 위치 변화 뒤 모양이 다 자리 잡았는지
    private(set) var shapeSettled = true
    /// 내용이 바뀔 때 마우스가 위에 있었음 → 마우스가 나갈 때까지 호버 밝힘 안 함
    private(set) var hoverBlocked = false
    /// 지금 호버로 밝혀 있는지 (렌더마다 갱신하는 기억값)
    @ObservationIgnored private var hoverLit = false
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    enum SwapStart: Equatable {
        /// 바꿀 내용 없음 (이미 지금 종류를 그리는 중)
        case none
        /// 이전 내용을 흐리고 `swapDeadline` 에 `finishSwap`
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

    /// 내용 구조가 바뀌었을 때 (`onChange`). 새로 흐리기 시작하면 새 내용을 보일 때(`swapDeadline` = 지금 + `contentDelay`)를 정한다.
    /// 흐린 채 기다리는 중에 또 바뀌면 그때를 그대로 둔다: 다시 재면 내용이 잇달아 바뀌는 동안 내용 없는 검은 모양만 계속 남는다
    func beginSwap(to key: IslandContentKey, reduceMotion: Bool, now: ContinuousClock.Instant = .now) -> SwapStart {
        if reduceMotion {
            outgoing = nil
            lastShown = nil
            swapDeadline = nil
            return .none
        }
        if let pending = outgoing {
            guard pending.key == key else {
                if swapDeadline == nil { swapDeadline = now + contentDelay(to: key) }
                return .fadeOut
            }
            outgoing = nil
            lastShown = nil
            swapDeadline = nil
            return .restore
        }
        guard let last = lastShown, last.key != key else {
            swapDeadline = nil
            return .none
        }
        outgoing = last
        lastShown = nil
        swapDeadline = now + contentDelay(to: key)
        return .fadeOut
    }

    /// 흐린 이전 내용 뒤 새 내용을 보일 때까지의 지연.
    /// 모드 종류가 바뀌면 `contentDelay`, 같은 모드에서 표시 방식만 바뀌면 프레임이 멀리 옮겨 가므로 `branchContentDelay`
    /// (같은 종류의 다음 요청 카드도 `branchContentDelay`. 승인 대기는 교체가 끝나 새 카드가 나타난 때부터 잰다)
    func contentDelay(to key: IslandContentKey) -> Duration {
        outgoing.map { $0.mode.kind == key.kind } == true ? IslandMotion.branchContentDelay : IslandMotion.contentDelay
    }

    /// 교체 끝: 다음 렌더부터 지금 모드를 그린다
    func finishSwap() {
        outgoing = nil
        lastShown = nil
        swapDeadline = nil
    }

    /// 뷰가 사라질 때: 기다리던 교체 · 자리 잡기 시계를 멈추고, 다시 붙으면 지금 내용을 바로 그리게 한다
    /// (교체를 기다리던 중에 사라졌어도 다시 붙었을 때 내용이 숨은 채 검은 모양만 남지 않게)
    func cancelSwap() {
        swapTask?.cancel()
        swapTask = nil
        swapDeadline = nil
        settleTask?.cancel()
        settleTask = nil
        outgoing = nil
        lastShown = nil
        if !contentVisible { contentVisible = true }
        if !shapeSettled { shapeSettled = true }
    }

    /// 기억한 내용이 지금과 다른 구조인지 (교체가 남았는지. 스냅숏 검사가 교체가 끝났는지 볼 때)
    func needsSwap(current key: IslandContentKey) -> Bool {
        if let pending = outgoing { return pending.key != key }
        return lastShown.map { $0.key != key } ?? false
    }

    // MARK: 호버 밝힘

    /// 이번 렌더에서 호버로 내용을 밝힐지. 밝히기 시작하는 건 모양이 자리 잡은 뒤에만 (이미 밝으면 유지)
    func hoverHighlight(wants: Bool) -> Bool {
        guard wants, !hoverBlocked else {
            hoverLit = false
            return false
        }
        if !hoverLit, shapeSettled { hoverLit = true }
        return hoverLit
    }

    /// 크기 · 위치 · 모양이 바뀌었다: `settleDelay` 동안 호버 밝힘을 새로 시작하지 않는다
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
            IdleCompactView(
                layout: layout, summary: presentation.compactSummary, hasUpdate: presentation.hasUpdate, reduceMotion: reduceMotion
            )
        case .working:
            CompactSessionView(
                session: presentation.compactSession,
                summary: presentation.compactSummary,
                hasUpdate: presentation.hasUpdate,
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
            switch request.kind {
            case .permission:
                PermissionView(
                    request: request,
                    queueCount: queueCount,
                    session: presentation.store.sessions[request.sessionID],
                    layout: layout,
                    presentation: presentation,
                    reduceMotion: reduceMotion
                )
            case let .question(questions):
                QuestionView(
                    request: request,
                    questions: questions,
                    queueCount: queueCount,
                    session: presentation.store.sessions[request.sessionID],
                    layout: layout,
                    presentation: presentation,
                    reduceMotion: reduceMotion
                )
            case let .plan(plan):
                PlanApprovalView(
                    request: request,
                    plan: plan,
                    queueCount: queueCount,
                    session: presentation.store.sessions[request.sessionID],
                    layout: layout,
                    presentation: presentation,
                    reduceMotion: reduceMotion
                )
            }
        case let .needsInput(sessionID, message, isPermissionPrompt):
            if let notice = presentation.notice, notice.id == sessionID {
                NoticeView(notice: notice, layout: layout, presentation: presentation, reduceMotion: reduceMotion)
            } else {
                NeedsInputView(
                    session: presentation.store.sessions[sessionID],
                    sessionID: sessionID,
                    message: message,
                    isPermissionPrompt: isPermissionPrompt,
                    layout: layout,
                    presentation: presentation,
                    reduceMotion: reduceMotion
                )
            }
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
