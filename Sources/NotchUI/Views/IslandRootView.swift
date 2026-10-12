import SwiftUI
import NotchCore

/// 패널 하나의 루트 뷰. 패널 상단 가운데에 아일랜드를 둔다.
struct IslandRootView: View {
    let screenID: ScreenID
    let presentation: PresentationController
    /// 패널 수명 동안 유지되는 뷰 상태 (@State 대신 사용 — 아래 IslandViewState 참고)
    let viewState: IslandViewState

    var body: some View {
        VStack(spacing: 0) {
            if let geometry = presentation.geometries[screenID] {
                IslandContainer(screenID: screenID, geometry: geometry, presentation: presentation, viewState: viewState)
                    .padding(.top, geometry.islandTopInset)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

/// 아일랜드 본체: 검정 모양 + 모드별 내용.
/// 크기는 스프링으로 애니메이션하고, 모드 종류가 바뀌면 내용을 잠깐 숨겼다가 크기 변경 후 페이드인한다.
struct IslandContainer: View {
    let screenID: ScreenID
    let geometry: NotchGeometry
    let presentation: PresentationController

    let viewState: IslandViewState

    @Environment(\.accessibilityReduceMotion) private var environmentReduceMotion

    var body: some View {
        let mode = presentation.mode(for: screenID)
        let layout = presentation.layout(for: mode, geometry: geometry)
        let reduceMotion = presentation.reduceMotion || environmentReduceMotion
        let displayMode = resolvedDisplayMode(current: mode)
        let hovered = presentation.hoveredScreenID == screenID && !mode.isOpen
        let shape = IslandShape(
            earRadius: layout.earRadius,
            topRadius: layout.topRadius,
            bottomRadius: layout.bottomRadius
        )

        ZStack(alignment: .top) {
            IslandContentView(
                mode: displayMode,
                layout: layout,
                geometry: geometry,
                presentation: presentation,
                reduceMotion: reduceMotion
            )
            .frame(width: layout.bodySize.width, height: layout.bodySize.height, alignment: .top)
            .opacity(viewState.contentVisible ? 1 : 0)
        }
        .frame(width: layout.frameSize.width, height: layout.frameSize.height, alignment: .top)
        .background(shape.fill(Palette.background))
        .clipShape(shape)
        .contentShape(shape)
        .opacity(mode == .hidden ? 0 : 1)
        .scaleEffect(hovered && !reduceMotion ? 1.02 : 1, anchor: .top)
        .animation(IslandMotion.resize(reduceMotion: reduceMotion), value: layout)
        .animation(IslandMotion.hover, value: hovered)
        .animation(.easeOut(duration: 0.2), value: mode == .hidden)
        .onTapGesture {
            presentation.handleIslandClick(on: screenID)
        }
        .onAppear {
            if viewState.shownMode == nil { viewState.shownMode = mode }
        }
        .onChange(of: mode) { oldMode, newMode in
            guard oldMode.kind != newMode.kind else { return }
            // 사라지는 동안엔 직전에 보이던 내용을 그대로 그린다
            if viewState.contentVisible { viewState.shownMode = oldMode }
            beginContentSwap(reduceMotion: reduceMotion)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AgentNotch")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(mode == .expanded ? "클릭하면 접혀" : "클릭하면 펼쳐져")
    }

    /// 전환 중(내용이 숨겨진 동안)에만 이전 모드를 그리고, 그 외엔 항상 최신 모드를 그린다.
    private func resolvedDisplayMode(current: IslandMode) -> IslandMode {
        guard !viewState.contentVisible, let shown = viewState.shownMode, shown.kind != current.kind else {
            return current
        }
        return shown
    }

    private func beginContentSwap(reduceMotion: Bool) {
        viewState.swapTask?.cancel()
        if reduceMotion {
            viewState.shownMode = presentation.mode(for: screenID)
            viewState.contentVisible = true
            return
        }
        withAnimation(IslandMotion.contentFadeOut) {
            viewState.contentVisible = false
        }
        let state = viewState
        let presentation = presentation
        let screenID = screenID
        state.swapTask = Task { @MainActor in
            try? await Task.sleep(for: IslandMotion.contentDelay)
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                state.shownMode = presentation.mode(for: screenID)
            }
            withAnimation(IslandMotion.contentFadeIn) {
                state.contentVisible = true
            }
        }
    }
}

/// 아일랜드 뷰의 일시 상태.
/// macOS 27 SDK 에서 `@State` 가 SwiftUIMacros 플러그인을 요구하는데 Command Line Tools 에는 그 플러그인이 없어서,
/// 패널마다 하나씩 만든 관찰 가능 객체로 대신한다.
@MainActor
@Observable
final class IslandViewState {
    /// 지금 그리고 있는 모드 (종류 전환 중엔 이전 모드를 잠깐 유지)
    var shownMode: IslandMode?
    var contentVisible = true
    @ObservationIgnored var swapTask: Task<Void, Never>?

    init() {}
}

/// 모드별 내용
struct IslandContentView: View {
    let mode: IslandMode
    let layout: IslandLayout
    let geometry: NotchGeometry
    let presentation: PresentationController
    let reduceMotion: Bool

    var body: some View {
        switch mode {
        case .hidden:
            Color.clear
        case .idle:
            IdleWingsView(geometry: geometry, layout: layout, store: presentation.store, reduceMotion: reduceMotion)
        case .working:
            CompactWingsView(
                session: presentation.compactSession,
                geometry: geometry,
                height: layout.headerHeight,
                reduceMotion: reduceMotion
            )
        case let .peek(sessionID, diff):
            PeekView(
                session: presentation.store.sessions[sessionID],
                diff: diff,
                textLine: presentation.streamingLine(for: sessionID),
                geometry: geometry,
                headerHeight: layout.headerHeight,
                actions: presentation.actions,
                reduceMotion: reduceMotion
            )
        case let .permission(request, queueCount):
            PermissionView(
                request: request,
                queueCount: queueCount,
                session: presentation.store.sessions[request.sessionID],
                geometry: geometry,
                headerHeight: layout.headerHeight,
                presentation: presentation,
                reduceMotion: reduceMotion
            )
        case let .needsInput(sessionID, message, isPermissionPrompt):
            NeedsInputView(
                session: presentation.store.sessions[sessionID],
                sessionID: sessionID,
                message: message,
                isPermissionPrompt: isPermissionPrompt,
                geometry: geometry,
                headerHeight: layout.headerHeight,
                actions: presentation.actions,
                reduceMotion: reduceMotion
            )
        case let .done(sessionID):
            CompletionView(
                session: presentation.store.sessions[sessionID],
                failed: false,
                textLine: presentation.streamingLine(for: sessionID),
                geometry: geometry,
                headerHeight: layout.headerHeight
            )
        case let .failed(sessionID):
            CompletionView(
                session: presentation.store.sessions[sessionID],
                failed: true,
                textLine: nil,
                geometry: geometry,
                headerHeight: layout.headerHeight
            )
        case .expanded:
            ExpandedView(
                geometry: geometry,
                headerHeight: layout.headerHeight,
                presentation: presentation,
                reduceMotion: reduceMotion
            )
        }
    }
}
