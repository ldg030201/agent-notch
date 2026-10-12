import AppKit
import Observation
import NotchCore
import os

/// 스토어 상태 + 설정 + 일시 상태(피크/완료 타이머, 사용자 펼침, 접어 둔 알림)로부터
/// 화면별 아일랜드 표시 모드를 계산한다.
@MainActor
@Observable
final class PresentationController {
    /// 스토어 신호로 생기는 일시적 펼침
    enum Transient: Equatable {
        case peek(sessionID: String, diff: DiffSnippet)
        case done(sessionID: String)
        case failed(sessionID: String)
    }

    /// 패널이 키 윈도우일 때의 단축키
    enum Shortcut {
        case allow, allowAlways, deny, collapse
    }

    let store: SessionStore
    let preferences: AppPreferences
    let actions: IslandActions

    private(set) var geometries: [ScreenID: NotchGeometry] = [:]
    /// NSScreen.screens 순서 (첫 번째 = 메뉴바가 있는 주 화면)
    private(set) var screenOrder: [ScreenID] = []
    /// 마우스가 있는 화면
    private(set) var activeScreenID: ScreenID?
    /// 마우스가 아일랜드 위에 있는 화면
    private(set) var hoveredScreenID: ScreenID?
    /// 사용자가 직접 펼친 화면 (클릭한 화면에서만 펼친다)
    private(set) var expandedScreenID: ScreenID?
    /// 풀스크린 앱이 덮고 있는 화면 (best-effort)
    private(set) var fullscreenScreenIDs: Set<ScreenID> = []
    private(set) var reduceMotion = false
    /// 화면별 메뉴바 빈 공간 측정값
    private(set) var spaces: [ScreenID: MenuBarSpace] = [:]
    /// 열린 메뉴 · 팝오버가 아일랜드 자리와 겹친 화면
    private(set) var occludedScreenIDs: Set<ScreenID> = []
    /// 노치를 쓰는 다른 앱 (화면 → 앱 이름)
    private(set) var notchConflicts: [ScreenID: String] = [:]
    /// 업데이트 상태 (없으면 배지 · 버전 탭 숨김)
    var updateProvider: UpdateProvider?

    private var transient: Transient?
    /// ⎋ 로 접어 둔 권한 요청 (요청은 계속 대기)
    private var suppressedPermissionIDs: Set<UUID> = []
    /// ⎋ 로 접어 둔 입력 대기 알림
    private var suppressedInputKey: String?
    /// needsInput 신호로 받은 메시지 (세션별 최신)
    private var inputMessages: [String: String] = [:]

    /// 지금 카드에 보이는 권한 요청과 처음 보인 시각(부팅 후 초). 막 바뀐 요청은 단축키로 결정하지 않는다.
    @ObservationIgnored private var displayedPermission: (id: UUID, since: TimeInterval)?
    /// 새 권한 요청이 보이고 나서 단축키 결정을 받기 시작할 때까지의 시간
    static let shortcutSettleDelay: TimeInterval = 0.5

    @ObservationIgnored private var transientTask: Task<Void, Never>?
    @ObservationIgnored private var lastSignalSeq: Int?
    @ObservationIgnored private var observing = false
    /// stop/start 를 반복해도 관찰 루프가 겹치지 않게 하는 세대 번호
    @ObservationIgnored private var generation = 0
    /// 사용자 동작으로 펼쳤을 때 해당 화면 패널을 키 윈도우로 만든다 (ScreenManager 가 연결)
    @ObservationIgnored var onRequestKey: ((ScreenID) -> Void)?
    /// 설정 창 열기 (NotchUIController 가 연결. 없으면 IslandActions.openSettings 사용)
    @ObservationIgnored var onOpenSettings: ((SettingsSection?) -> Void)?

    @ObservationIgnored private let logger = Logger(subsystem: "com.ldg.agent-notch", category: "Presentation")

    init(store: SessionStore, preferences: AppPreferences, actions: IslandActions) {
        self.store = store
        self.preferences = preferences
        self.actions = actions
    }

    // MARK: - 생명주기

    func start() {
        guard !observing else { return }
        observing = true
        generation += 1
        // 시작 전에 쌓인 신호에는 반응하지 않는다
        lastSignalSeq = store.latestSignal?.seq
        setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        armSignalObservation()
    }

    func stop() {
        observing = false
        transientTask?.cancel()
        transientTask = nil
        transient = nil
        expandedScreenID = nil
    }

    private func armSignalObservation() {
        guard observing else { return }
        let current = generation
        withObservationTracking {
            _ = store.latestSignal
        } onChange: { [weak self] in
            // willSet 시점에 불리므로 다음 틱에서 새 값을 읽는다
            Task { @MainActor [weak self] in
                guard let self, self.observing, self.generation == current else { return }
                self.handleLatestSignal()
                self.armSignalObservation()
            }
        }
    }

    // MARK: - 외부 상태 갱신 (ScreenManager)

    func updateScreens(_ list: [NotchGeometry]) {
        let map = Dictionary(list.map { ($0.screenID, $0) }, uniquingKeysWith: { first, _ in first })
        let order = list.map(\.screenID)
        if map != geometries { geometries = map }
        if order != screenOrder { screenOrder = order }
        if let expanded = expandedScreenID, map[expanded] == nil { expandedScreenID = nil }
        if let active = activeScreenID, map[active] == nil { activeScreenID = nil }
        if let hovered = hoveredScreenID, map[hovered] == nil { hoveredScreenID = nil }
        let validFullscreen = fullscreenScreenIDs.filter { map[$0] != nil }
        if validFullscreen != fullscreenScreenIDs { fullscreenScreenIDs = validFullscreen }
    }

    func setActiveScreen(_ id: ScreenID?) {
        if activeScreenID != id { activeScreenID = id }
    }

    func setHoveredScreen(_ id: ScreenID?) {
        if hoveredScreenID != id { hoveredScreenID = id }
    }

    func setFullscreenScreens(_ ids: Set<ScreenID>) {
        if fullscreenScreenIDs != ids { fullscreenScreenIDs = ids }
    }

    func setReduceMotion(_ value: Bool) {
        if reduceMotion != value { reduceMotion = value }
    }

    func setSpaces(_ value: [ScreenID: MenuBarSpace]) {
        if spaces != value { spaces = value }
    }

    func setNotchConflicts(_ value: [ScreenID: String]) {
        if notchConflicts != value { notchConflicts = value }
    }

    /// 열린 메뉴와 겹친 화면. 겹치기 시작하면 일시 펼침(피크/완료)은 바로 접는다.
    func setOccluded(_ ids: Set<ScreenID>) {
        guard occludedScreenIDs != ids else { return }
        occludedScreenIDs = ids
        if let target = transientTargetScreenID, ids.contains(target), transient != nil {
            clearTransient()
        }
    }

    /// 감지된 다른 노치 앱 이름 (설정 화면 표시용)
    var notchConflictNames: [String] {
        Array(Set(notchConflicts.values)).sorted()
    }

    // MARK: - 화면 정책

    /// 일시적 펼침(피크/권한/완료 등)을 보여줄 화면
    var transientTargetScreenID: ScreenID? {
        switch preferences.displayPolicy {
        case .allScreens, .activeScreen:
            if let active = activeScreenID, geometries[active] != nil { return active }
            return screenOrder.first
        case .builtInOnly:
            return builtInScreenID
        }
    }

    /// 내장 화면. 덮개를 닫아 내장 화면이 없으면 노치 화면 → 주 화면 순으로 대신한다.
    var builtInScreenID: ScreenID? {
        screenOrder.first { geometries[$0]?.isBuiltIn == true }
            ?? screenOrder.first { geometries[$0]?.hasNotch == true }
            ?? screenOrder.first
    }

    func isVisible(_ id: ScreenID) -> Bool {
        switch preferences.displayPolicy {
        case .allScreens: return true
        case .activeScreen, .builtInOnly: return id == transientTargetScreenID
        }
    }

    /// 사용자 동작(메뉴 등)으로 펼칠 화면: 마우스가 있는 화면이 보이면 그 화면, 아니면 정책상 대상 화면
    var preferredUserScreenID: ScreenID? {
        if let active = activeScreenID, geometries[active] != nil, isVisible(active) { return active }
        return transientTargetScreenID
    }

    // MARK: - 모드 계산

    func mode(for id: ScreenID) -> IslandMode {
        guard geometries[id] != nil, isVisible(id) else { return .hidden }
        let isTarget = id == transientTargetScreenID
        let fullscreen = fullscreenScreenIDs.contains(id)
        let behavior = preferences.fullscreenBehavior
        // 열린 메뉴와 겹치면 알림 펼침은 메뉴가 닫힐 때까지 미루고(접힌 상태 + 주황 점), 일시 펼침은 보이지 않는다
        let occluded = occludedScreenIDs.contains(id)

        if isTarget, !(fullscreen && behavior == .hide), let alert = alertMode() {
            if occluded { return compactMode(for: id) }
            noteDisplayed(alert)
            return alert
        }
        // 사용자가 직접 연 펼침은 풀스크린 설정보다 우선
        if expandedScreenID == id { return .expanded }
        if fullscreen && behavior != .showAll { return .hidden }
        if isTarget, !occluded, let transient = transientMode() { return transient }
        return compactMode(for: id)
    }

    /// 열린 메뉴와 겹쳐 접힌 아일랜드를 투명하게 숨기는 중인지 (알림이 대기 중이면 숨기지 않음)
    func isConcealed(_ id: ScreenID) -> Bool {
        guard occludedScreenIDs.contains(id) else { return false }
        switch mode(for: id) {
        case .idle, .working:
            return !(id == transientTargetScreenID && alertMode() != nil)
        default:
            return false
        }
    }

    /// 접힌 상태에서 보여줄 세션: 포커스 세션이 활동 중이면 그것, 아니면 작업 중인 첫 세션
    var compactSession: AgentSession? {
        if let focused = store.focusedSession, Self.isActive(focused) { return focused }
        return store.rankedSessions.first { $0.phase.isWorking }
    }

    private static func isActive(_ session: AgentSession) -> Bool {
        session.phase.isWorking || session.phase.needsAttention || session.hasUnseenCompletion
    }

    /// 접힌 상태. 둘 자리가 없으면(메뉴바가 숨었거나 빈 구간이 없음, "표시 안 함") 숨긴다.
    private func compactMode(for id: ScreenID) -> IslandMode {
        guard !store.rankedSessions.isEmpty else { return .hidden }
        let mode: IslandMode = compactSession == nil ? .idle : .working
        if let engine = layoutEngine(for: id), engine.compactPlacement(for: compactContent(for: mode)) == .none {
            return .hidden
        }
        return mode
    }

    private func alertMode() -> IslandMode? {
        let pending = store.pendingPermissions
        if let request = pending.first(where: { !suppressedPermissionIDs.contains($0.id) }) {
            return .permission(request, queueCount: pending.count)
        }
        if let input = pendingInput(), suppressedInputKey != Self.inputKey(input.sessionID, input.message) {
            return .needsInput(sessionID: input.sessionID, message: input.message, isPermissionPrompt: input.isPermissionPrompt)
        }
        return nil
    }

    /// 입력 대기 중이거나, 훅 대기 없이 터미널에서 승인을 기다리는 세션
    private func pendingInput() -> (sessionID: String, message: String, isPermissionPrompt: Bool)? {
        var candidates: [AgentSession] = []
        if let focused = store.focusedSession { candidates.append(focused) }
        candidates.append(contentsOf: store.rankedSessions)
        let hookPendingSessions = Set(store.pendingPermissions.map(\.sessionID))

        for session in candidates {
            switch session.phase {
            case .waitingInput:
                let message = inputMessages[session.id] ?? session.lastNotification ?? "입력이 필요해"
                return (session.id, message, false)
            case .waitingPermission where !hookPendingSessions.contains(session.id):
                return (session.id, "터미널에서 승인 필요", true)
            default:
                continue
            }
        }
        return nil
    }

    private func transientMode() -> IslandMode? {
        guard let transient else { return nil }
        switch transient {
        case let .peek(sessionID, diff):
            guard preferences.peekOnEdit, store.sessions[sessionID] != nil else { return nil }
            return .peek(sessionID: sessionID, diff: diff)
        case let .done(sessionID):
            guard store.sessions[sessionID]?.phase == .completed else { return nil }
            return .done(sessionID: sessionID)
        case let .failed(sessionID):
            guard store.sessions[sessionID]?.phase == .failed else { return nil }
            return .failed(sessionID: sessionID)
        }
    }

    private static func inputKey(_ sessionID: String, _ message: String) -> String {
        sessionID + "\u{1F}" + message
    }

    // MARK: - 레이아웃

    func layoutEngine(for id: ScreenID) -> IslandLayoutEngine? {
        guard let geometry = geometries[id] else { return nil }
        return IslandLayoutEngine(
            geometry: geometry,
            space: spaces[id],
            externalStyle: preferences.externalDisplayStyle,
            notchStyle: preferences.notchStyle,
            overlapStyle: preferences.compactOverlapStyle,
            notchConflict: notchConflicts[id] != nil
        )
    }

    /// 접힌 상태 내용 (레이아웃 선택용 폭 측정)
    func compactContent(for mode: IslandMode) -> CompactContent {
        if mode == .working, let session = compactSession {
            return .session(CompactMetrics(session: session))
        }
        return .idle(count: store.rankedSessions.count)
    }

    func layout(for id: ScreenID, mode: IslandMode) -> IslandLayout {
        guard let engine = layoutEngine(for: id) else {
            return IslandLayout(size: .zero, origin: .zero, shape: IslandShapeSpec(), compact: nil)
        }
        return layout(for: mode, engine: engine)
    }

    func layout(for mode: IslandMode, engine: IslandLayoutEngine) -> IslandLayout {
        typealias M = IslandMetrics
        let contentWidth: (CGFloat) -> CGFloat = { $0 - M.bodyPadding * 2 }

        func card(_ width: CGFloat, radius: CGFloat, body: @escaping (CGFloat) -> CGFloat) -> IslandLayout {
            let compact = engine.compactPlacement(for: compactContent(for: compactSession == nil ? .idle : .working))
            return engine.cardLayout(preferredWidth: width, radius: radius, compact: compact, bodyHeight: body)
        }

        switch mode {
        case .hidden:
            return engine.hiddenLayout()

        case .idle, .working:
            return engine.compactLayout(for: compactContent(for: mode))

        case let .peek(sessionID, diff):
            let rows = DiffPresentation.visibleLines(diff).count
            let hasText = streamingLine(for: sessionID) != nil
            let body = M.bodyTop + M.lineHeight + 6 + M.diffRowsHeight(count: rows)
                + (hasText ? 8 + M.lineHeight : 0) + M.bodyBottom
            return card(M.peekWidth, radius: 22) { _ in body }

        case let .permission(request, _):
            return card(M.permissionWidth, radius: 22) { width in
                PermissionCardModel(request: request, cardWidth: width).bodyHeight
            }

        case let .needsInput(_, message, _):
            return card(M.needsInputWidth, radius: 22) { width in
                let lines = TextMeasure.lineCount(
                    message, font: IslandFont.bodyNS, lineHeight: M.bodyLineHeight,
                    width: contentWidth(width), maxLines: 2
                )
                return M.bodyTop + CGFloat(lines) * M.lineHeight + 10 + M.buttonHeight + 14
            }

        case let .done(sessionID):
            let hasText = streamingLine(for: sessionID) != nil
            let body = 2 + M.lineHeight + (hasText ? 4 + M.lineHeight : 0) + M.bodyBottom
            return card(M.doneWidth, radius: 20) { _ in body }

        case let .failed(sessionID):
            let hasFiles = !(store.sessions[sessionID]?.turn.changedFiles.isEmpty ?? true)
            let body = 2 + M.lineHeight + (hasFiles ? 4 + M.lineHeight : 0) + M.bodyBottom
            return card(M.doneWidth, radius: 20) { _ in body }

        case .expanded:
            return card(M.expandedSize.width, radius: 26) { _ in M.expandedBodyHeight }
        }
    }

    /// 열린 메뉴와 겹치는지 볼 영역 (패널 기준): 지금 아일랜드 + 카드가 펼쳐질 자리
    func overlapZone(for id: ScreenID) -> CGRect? {
        guard let engine = layoutEngine(for: id) else { return nil }
        let current = layout(for: mode(for: id), engine: engine).panelRect
        return current.union(engine.cardZone())
    }

    /// 설정이 켜져 있을 때만 보여줄 최근 응답 한 줄
    func streamingLine(for sessionID: String) -> String? {
        guard preferences.showStreamingText else { return nil }
        return store.sessions[sessionID]?.latestTextLine
    }

    // MARK: - 사용자 동작

    /// 아일랜드 배경 클릭 (버튼 클릭은 제외)
    func handleIslandClick(on id: ScreenID) {
        switch mode(for: id) {
        case .hidden:
            return
        case .permission, .needsInput:
            // 알림 카드는 클릭으로 접지 않는다. 키 윈도우만 되어 단축키를 받는다.
            onRequestKey?(id)
            return
        default:
            break
        }
        if restoreSuppressedAlerts() { return }
        toggleExpanded(on: id)
    }

    /// 펼침/접기 토글 (펼칠 때 포커스 세션의 미확인 완료를 확인 처리)
    func toggleExpanded(on id: ScreenID) {
        if expandedScreenID == id {
            expandedScreenID = nil
            return
        }
        expandedScreenID = id
        if let focused = store.focusedSession, focused.hasUnseenCompletion {
            store.markSeen(sessionID: focused.id)
        }
        onRequestKey?(id)
    }

    /// ⎋: 지금 보이는 일시 펼침을 접는다. 권한 요청은 대기 상태로 남는다.
    func collapse(on id: ScreenID) {
        switch mode(for: id) {
        case let .permission(request, _):
            suppressedPermissionIDs.insert(request.id)
        case let .needsInput(sessionID, message, _):
            suppressedInputKey = Self.inputKey(sessionID, message)
        case .expanded:
            expandedScreenID = nil
        case .peek, .done, .failed:
            clearTransient()
        case .hidden, .idle, .working:
            break
        }
    }

    /// 권한 카드 "접기": 요청은 그대로 대기하고 접힌 상태(주황 점)로 줄인다. 접힌 아일랜드를 누르면 다시 펼친다.
    func minimize(_ request: PermissionRequestInfo) {
        suppressedPermissionIDs.insert(request.id)
    }

    /// 입력 대기 카드 "접기"
    func minimizeInput(sessionID: String, message: String) {
        suppressedInputKey = Self.inputKey(sessionID, message)
    }

    /// 아일랜드 바깥(다른 앱)을 클릭하면 사용자가 연 펼침과 일시 펼침(피크/완료)을 바로 접는다.
    /// 권한 요청 · 입력 대기는 "접기"/⎋ 로만 접는다 (실수로 놓치지 않게).
    func clickedOutside() {
        if expandedScreenID != nil { expandedScreenID = nil }
        if transient != nil { clearTransient() }
    }

    /// 접어 둔 알림이 있으면 다시 펼친다
    @discardableResult
    func restoreSuppressedAlerts() -> Bool {
        let pendingIDs = Set(store.pendingPermissions.map(\.id))
        var restored = false
        if !suppressedPermissionIDs.isDisjoint(with: pendingIDs) {
            suppressedPermissionIDs.removeAll()
            restored = true
        }
        if let key = suppressedInputKey, let input = pendingInput(), Self.inputKey(input.sessionID, input.message) == key {
            suppressedInputKey = nil
            restored = true
        }
        return restored
    }

    /// 펼침의 톱니 버튼 · 새 버전 배지: 펼침을 접고 설정 창을 연다
    func openSettings(section: SettingsSection? = nil) {
        expandedScreenID = nil
        if let onOpenSettings {
            onOpenSettings(section)
        } else {
            actions.openSettings()
        }
    }

    func resolve(_ request: PermissionRequestInfo, decision: PermissionDecision) {
        logger.debug("권한 결정 전달")
        actions.resolvePermission(id: request.id, decision: decision)
    }

    /// 터미널로: 노치에서 결정하지 않고 Claude Code 기본 프롬프트로 넘긴 뒤 터미널로 이동
    func sendToTerminal(_ request: PermissionRequestInfo) {
        actions.resolvePermission(id: request.id, decision: .passthrough)
        actions.jumpToTerminal(sessionID: request.sessionID)
    }

    /// 키 윈도우일 때의 단축키 처리. 처리했으면(또는 일부러 무시했으면) true.
    func perform(_ shortcut: Shortcut, on id: ScreenID) -> Bool {
        let mode = mode(for: id)
        if shortcut == .collapse {
            guard mode.isOpen else { return false }
            collapse(on: id)
            return true
        }
        guard case let .permission(request, _) = mode else { return false }
        // 방금 바뀐 요청은 아직 읽지 못했을 수 있다 → 결정하지 않고 키만 소비 (경고음 없이 무시)
        guard isSettled(request) else {
            logger.debug("새 권한 요청 직후 단축키 무시")
            return true
        }
        let card = PermissionCardModel(request: request, cardWidth: layout(for: id, mode: mode).cardWidth)
        switch shortcut {
        case .allow:
            guard card.canAllow else { return true }
            resolve(request, decision: .allow)
        case .allowAlways:
            guard card.canAllowAlways else { return true }
            resolve(request, decision: .allowAlways)
        case .deny:
            resolve(request, decision: .deny(message: nil))
        case .collapse:
            break
        }
        return true
    }

    /// 카드에 보이는 권한 요청이 바뀌면 그 시각을 기록한다 (`mode(for:)` 에서 호출)
    private func noteDisplayed(_ mode: IslandMode) {
        guard case let .permission(request, _) = mode, displayedPermission?.id != request.id else { return }
        displayedPermission = (request.id, ProcessInfo.processInfo.systemUptime)
    }

    /// 이 요청이 카드에 보인 지 `shortcutSettleDelay` 이상 지났는지
    private func isSettled(_ request: PermissionRequestInfo) -> Bool {
        guard let shown = displayedPermission, shown.id == request.id else { return false }
        return ProcessInfo.processInfo.systemUptime - shown.since >= Self.shortcutSettleDelay
    }

    // MARK: - 신호 처리

    func handleLatestSignal() {
        pruneTransientState()
        guard let event = store.latestSignal, event.seq != lastSignalSeq else { return }
        lastSignalSeq = event.seq

        switch event.signal {
        case let .edited(sessionID, diff):
            guard preferences.peekOnEdit, sessionID == store.focusedSessionID else { return }
            // 완료/실패 요약이 떠 있으면 피크로 덮지 않는다
            if let current = transient {
                switch current {
                case .done, .failed: return
                case .peek: break
                }
            }
            showTransient(.peek(sessionID: sessionID, diff: diff), duration: preferences.peekDuration)
        case let .completed(sessionID):
            showTransient(.done(sessionID: sessionID), duration: preferences.completionDisplayDuration)
        case let .failed(sessionID):
            showTransient(.failed(sessionID: sessionID), duration: preferences.completionDisplayDuration)
        case let .needsInput(sessionID, message):
            inputMessages[sessionID] = message
            suppressedInputKey = nil
        case .permissionRequested, .sessionStarted:
            break
        }
    }

    private func showTransient(_ value: Transient, duration: Double) {
        transient = value
        transientTask?.cancel()
        let seconds = max(0.5, duration)
        transientTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.transient == value else { return }
            self.transient = nil
        }
    }

    /// 타이머 없이 일시 펼침을 띄운다 (스냅숏 렌더링용)
    func setTransientForSnapshot(_ value: Transient) {
        transientTask?.cancel()
        transientTask = nil
        transient = value
    }

    private func clearTransient() {
        transientTask?.cancel()
        transientTask = nil
        if transient != nil { transient = nil }
    }

    /// 해결된 요청·사라진 세션에 대한 일시 상태 정리
    private func pruneTransientState() {
        if !suppressedPermissionIDs.isEmpty {
            let pendingIDs = Set(store.pendingPermissions.map(\.id))
            let kept = suppressedPermissionIDs.intersection(pendingIDs)
            if kept != suppressedPermissionIDs { suppressedPermissionIDs = kept }
        }
        if suppressedInputKey != nil {
            let current = pendingInput().map { Self.inputKey($0.sessionID, $0.message) }
            if current != suppressedInputKey { suppressedInputKey = nil }
        }
        let stale = inputMessages.keys.filter { store.sessions[$0]?.phase != .waitingInput }
        for key in stale { inputMessages.removeValue(forKey: key) }
    }
}

// MARK: - 권한 카드 내용

/// 권한 카드에 무엇을 얼마나 보여줄지. 레이아웃(높이)과 뷰 · 단축키가 같은 값을 쓴다.
struct PermissionCardModel {
    /// 상세(고정폭) 상자 줄 수 (최대 `IslandMetrics.maxDetailLines`)
    let detailLines: Int
    /// 상세가 승인 대상 전체를 보여주지 못함 (줄 수 초과 · 글자 수 제한) → 허용 · 항상 허용을 막고 터미널로 안내
    let isClipped: Bool
    /// 항상 허용 사용 가능 (규칙이 있고, 내용이 다 보일 때)
    let canAllowAlways: Bool
    /// 항상 허용 시 저장될 규칙 (항상 허용을 쓸 수 있을 때만, 최대 `maxScopeLines` 줄)
    let scopeLines: [String]
    /// 툴팁용 전체 규칙
    let fullScope: [String]

    static let maxScopeLines = 3
    static let clippedNote = "요청이 길어서 다 못 보여줘 · 터미널에서 확인해 줘"

    var canAllow: Bool { !isClipped }

    init(request: PermissionRequestInfo, cardWidth: CGFloat) {
        typealias M = IslandMetrics
        let width = cardWidth - M.bodyPadding * 2 - M.detailHorizontalPadding * 2
        // 측정과 실제 그리기의 줄바꿈 위치가 조금 달라도 내용이 잘려 보이지 않게, 한 글자 좁게 재서 넉넉히 잡는다
        let measured = TextMeasure.lineCount(
            request.detail, font: IslandFont.monoNS, lineHeight: M.monoLineHeight,
            width: width - IslandFont.monoCharWidth, maxLines: .max
        )
        detailLines = min(measured, M.maxDetailLines)
        isClipped = PermissionReplyBuilder.isDetailClipped(request, measuredLines: measured, visibleLines: M.maxDetailLines)
        canAllowAlways = !isClipped && PermissionReplyBuilder.canAllowAlways(request)

        let scope = canAllowAlways ? PermissionReplyBuilder.scopeSummary(request.suggestions) : []
        fullScope = scope
        if scope.count > Self.maxScopeLines {
            let shown = Self.maxScopeLines - 1
            scopeLines = Array(scope.prefix(shown)) + ["외 \(scope.count - shown)개 규칙"]
        } else {
            scopeLines = scope
        }
    }

    /// 카드 본문 높이 (상단 행 제외)
    var bodyHeight: CGFloat {
        typealias M = IslandMetrics
        let box = CGFloat(detailLines) * M.monoLineHeight + M.detailVerticalPadding * 2
        let note = isClipped ? M.permissionNoteGap + M.permissionNoteHeight : 0
        let scope = scopeLines.isEmpty ? 0 : M.permissionNoteGap + CGFloat(scopeLines.count) * M.scopeLineHeight
        return M.bodyTop + M.lineHeight + 6 + box + note + scope + 12 + M.buttonHeight + 14
    }
}
