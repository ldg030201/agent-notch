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
/// 크기 · 위치는 스프링으로 애니메이션하고, 모드 종류가 바뀌면 내용을 잠깐 숨겼다가 크기 변경 후 페이드인한다.
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
        let displayMode = resolvedDisplayMode(current: mode)
        let hovered = presentation.hoveredScreenID == screenID && !mode.isOpen
        let shape = IslandShape(spec: layout.shape)
        let invisible = mode == .hidden || concealed

        ZStack(alignment: .topLeading) {
            IslandContentView(
                mode: displayMode,
                layout: layout,
                presentation: presentation,
                reduceMotion: reduceMotion
            )
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
            .opacity(viewState.contentVisible ? 1 : 0)
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .background(shape.fill(Palette.background))
        .clipShape(shape)
        .contentShape(shape)
        .opacity(invisible ? 0 : 1)
        .allowsHitTesting(!invisible)
        .scaleEffect(hovered && !reduceMotion ? 1.02 : 1, anchor: .top)
        .offset(x: layout.origin.x, y: layout.origin.y)
        .animation(IslandMotion.resize(reduceMotion: reduceMotion), value: layout)
        .animation(IslandMotion.hover, value: hovered)
        .animation(.easeOut(duration: 0.2), value: invisible)
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
    let presentation: PresentationController
    let reduceMotion: Bool

    var body: some View {
        switch mode {
        case .hidden:
            Color.clear
        case .idle:
            IdleCompactView(layout: layout, store: presentation.store, reduceMotion: reduceMotion)
        case .working:
            CompactSessionView(session: presentation.compactSession, layout: layout, reduceMotion: reduceMotion)
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
