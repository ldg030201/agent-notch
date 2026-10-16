import AppKit
import Observation
import NotchCore
import NotchShared
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
    enum Shortcut: Equatable {
        case allow, allowAlways, deny, collapse
        /// ↩ (질문 카드: 다음 · 보내기, 계획 카드: 승인)
        case submit
        /// 숫자 키 1–4 (질문 카드 선택지, 0부터)
        case pick(Int)
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
    /// 사용자가 직접 펼친 화면 (클릭한 화면에서만 펼친다). 펼친 동안엔 세션을 넘기지 않고, 닫으면 넘기는 시계를 처음부터 잰다
    private(set) var expandedScreenID: ScreenID? {
        didSet {
            if oldValue != nil, expandedScreenID == nil { restartRotationClock() }
        }
    }
    /// 풀스크린 앱이 덮고 있는 화면 (best-effort)
    private(set) var fullscreenScreenIDs: Set<ScreenID> = []
    private(set) var reduceMotion = false
    /// 화면별 메뉴바 빈 공간 측정값
    private(set) var spaces: [ScreenID: MenuBarSpace] = [:]
    /// 열린 메뉴 · 팝오버가 아일랜드 + 카드 자리와 겹친 화면 (알림 펼침을 미루고 일시 펼침은 보이지 않는다)
    private(set) var occludedScreenIDs: Set<ScreenID> = []
    /// 그중 메뉴가 접힌 아일랜드에 닿아 접힌 상태를 투명하게 숨긴 화면
    private(set) var concealedScreenIDs: Set<ScreenID> = []
    /// 업데이트 상태 (없으면 배지 · 버전 탭 숨김)
    var updateProvider: UpdateProvider?

    private var transient: Transient?
    /// ⎋ 로 접어 둔 권한 요청 (요청은 계속 대기)
    private var suppressedPermissionIDs: Set<UUID> = []
    /// ⎋ 로 접어 둔 입력 대기 알림
    private var suppressedInputKey: String?
    /// needsInput 신호로 받은 메시지 (세션별 최신)
    private var inputMessages: [String: String] = [:]

    /// 카드 내용이 화면에 보이기 시작한 권한 요청 · 그 화면 · 보이기 시작한 시각(부팅 후 초).
    /// 아일랜드 뷰가 내용 교체를 끝내 그 요청 카드가 나타날 때 기록하고(`contentDidAppear`), 그 화면 내용이 바뀌기 시작하면 지운다.
    /// 막 보인 요청은 승인하지 않는다 (`acceptsDecision`)
    @ObservationIgnored private var displayedPermission: (id: UUID, screen: ScreenID, since: TimeInterval)?
    /// 질문 카드에서 고르는 중인 답 (요청 ID → 답). 요청이 대기열에서 빠지면 지운다
    @ObservationIgnored private var questionDrafts: [UUID: QuestionDraft] = [:]
    /// 권한 · 질문 카드 내용 (요청 · 카드 폭마다 한 번 계산해 레이아웃 · 뷰 · 단축키가 함께 쓴다). 요청이 대기열에서 빠지면 지운다
    @ObservationIgnored private var permissionCards: [CardKey: PermissionCardModel] = [:]
    @ObservationIgnored private var questionCards: [CardKey: QuestionCardModel] = [:]
    private struct CardKey: Hashable {
        var request: UUID
        var width: CGFloat
    }
    /// 요청이 카드에 보이고 나서 승인(허용 · 항상 허용 · 계획 승인 · 답 보내기)을 받기 시작할 때까지의 시간 (클릭 · 단축키 모두)
    static let shortcutSettleDelay: TimeInterval = 0.5
    /// 지금 시각 (부팅 후 초). 승인 대기 · 접힌 폭 안정화 · 접히는 동안 붙잡은 띠가 함께 쓴다.
    /// 스냅숏은 멈춘 시계를 넣어 렌더링 속도와 관계없이 같은 그림을 만들고, 검사는 시간을 돌려 승인 대기를 확인한다
    @ObservationIgnored var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    @ObservationIgnored private var transientTask: Task<Void, Never>?
    /// 세션 자동 넘기기 시계 (`restartRotationClock`)
    @ObservationIgnored private var rotationTask: Task<Void, Never>?
    /// 넘기는 간격 하한 (초). 설정 슬라이더보다 짧게 저장된 값이 와도 너무 자주 넘기지 않게
    static let minimumRotationInterval: Double = 2

    /// 접힌 상태 폭 안정화 (툴 이름 · `+N −M` 폭이 이벤트마다 바뀌어도 알약이 출렁이지 않게). 커밋에서만 옮긴다
    @ObservationIgnored private var compactHold = CompactMetricsHold()
    /// 붙잡아 둔 접힌 폭을 줄이거나 접히는 동안 붙잡은 카드 띠를 놓을 때가 되면 올려서 다시 계산 · 커밋하게 한다
    private var holdRevision = 0
    @ObservationIgnored private var compactHoldTask: (task: Task<Void, Never>, deadline: TimeInterval)?
    /// 피크 카드 본문 높이: 피크가 이어지는 동안엔 커지기만 한다 (diff 줄 수마다 카드가 출렁이지 않게). 커밋에서만 키운다
    @ObservationIgnored private var peekBodyHold: CGFloat = 0

    /// 화면마다 커밋한 배치 이력 (`commit` 만 바꾼다)
    @ObservationIgnored private var histories: [ScreenID: LayoutHistory] = [:]
    /// 접히는 동안 붙잡은 카드 띠를 놓을 때 다시 계산하게 하는 예약 (화면마다)
    @ObservationIgnored private var collapseHoldTasks: [ScreenID: Task<Void, Never>] = [:]
    /// 마지막으로 로그에 남긴 레이아웃 (화면마다, 바뀔 때만 남긴다)
    @ObservationIgnored private var loggedLayouts: [ScreenID: LayoutLogEntry] = [:]
    /// 접히는 동안 카드 띠를 붙잡는 시간: 접히는 모양(resize 스프링)이 다 자리 잡을 때까지 (`IslandMotion.settleDelay`)
    static let collapseHoldDuration: Duration = IslandMotion.settleDelay

    @ObservationIgnored private var lastSignalSeq: Int?
    @ObservationIgnored private var observing = false
    /// stop/start 를 반복해도 관찰 루프가 겹치지 않게 하는 세대 번호
    @ObservationIgnored private var generation = 0
    /// 사용자 동작으로 펼쳤을 때 해당 화면 패널을 키 윈도우로 만든다 (ScreenManager 가 연결)
    @ObservationIgnored var onRequestKey: ((ScreenID) -> Void)?
    /// 설정 창 열기 (NotchUIController 가 연결한다. 스냅숏은 열지 않는다)
    @ObservationIgnored var onOpenSettings: (SettingsSection?) -> Void = { _ in }

    @ObservationIgnored private let logger = Logger(subsystem: NotchWire.logSubsystem, category: "Presentation")

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
        armFocusObservation()
        restartRotationClock()
    }

    func stop() {
        observing = false
        transientTask?.cancel()
        transientTask = nil
        rotationTask?.cancel()
        rotationTask = nil
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

    /// 보여주는 세션이 바뀌면(넘김 · 알림 · 직접 고름 · 고정) 그 세션을 넘기는 간격만큼 온전히 보여주도록 시계를 다시 잰다
    private func armFocusObservation() {
        guard observing else { return }
        let current = generation
        withObservationTracking {
            _ = store.focusedSessionID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observing, self.generation == current else { return }
                self.restartRotationClock()
                self.armFocusObservation()
            }
        }
    }

    // MARK: - 세션 자동 넘기기

    /// 넘기는 시계를 처음부터 다시 잰다: 넘기는 간격(설정, 매번 지금 값)마다 한 번 넘긴다.
    /// 그때 접힌 상태를 보고 있지 않으면(`isShowingCompact`) 돌아올 때까지 기다렸다가, 접힌 상태를 잠깐(`rotationResumeDelay`) 보여준 뒤 넘긴다
    func restartRotationClock() {
        rotationTask?.cancel()
        rotationTask = nil
        guard observing else { return }
        rotationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.rotationInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
                guard self?.preferences.rotatesSessions == true else { continue }
                var waited = false
                while !Task.isCancelled, self?.isShowingCompact == false {
                    waited = true
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if waited { try? await Task.sleep(for: Self.rotationResumeDelay) }
                guard !Task.isCancelled, let self else { return }
                if self.preferences.rotatesSessions, self.isShowingCompact { self.store.rotateFocus() }
            }
        }
    }

    /// 접힌 상태로 돌아온 뒤 넘기기 전에 보여주는 시간
    static let rotationResumeDelay: Duration = .seconds(2)

    private var rotationInterval: Double {
        max(Self.minimumRotationInterval, preferences.sessionRotationInterval)
    }

    /// 접힌 상태를 보고 있는지: 펼친 카드(사용자가 연 펼침 · 알림 · 미리보기 · 완료)가 없고 마우스가 아일랜드 위에 없을 때
    /// (보이는 세션을 누르려는 중엔 넘기지 않는다). 고정 · 승인 대기는 스토어가 따진다 (`SessionStore.rotateFocus`)
    private var isShowingCompact: Bool {
        expandedScreenID == nil && transient == nil && hoveredScreenID == nil && alertMode() == nil
    }

    // MARK: - 외부 상태 갱신 (ScreenManager)

    func updateScreens(_ list: [NotchGeometry]) {
        let map = Dictionary(list.map { ($0.screenID, $0) }, uniquingKeysWith: { first, _ in first })
        let order = list.map(\.screenID)
        // 사라진 화면의 배치 이력은 다음 커밋이 지운다 (화면 구성을 바꾸면 관찰 패스가 바로 다시 계산 · 커밋한다)
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

    /// 열린 메뉴와 겹친 화면 · 접힌 상태를 숨길 화면 (`OverlapMonitor`). 겹치기 시작하면 일시 펼침(피크/완료)은 바로 접는다.
    func setOccluded(_ ids: Set<ScreenID>, concealed: Set<ScreenID> = []) {
        let concealed = concealed.intersection(ids)
        if concealedScreenIDs != concealed { concealedScreenIDs = concealed }
        guard occludedScreenIDs != ids else { return }
        occludedScreenIDs = ids
        if let target = transientTargetScreenID, ids.contains(target), transient != nil {
            clearTransient()
        }
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
            return occluded ? compactMode(for: id) : alert
        }
        // 사용자가 직접 연 펼침은 풀스크린 설정보다 우선
        if expandedScreenID == id { return .expanded }
        if fullscreen && behavior != .showAll { return .hidden }
        if isTarget, !occluded, let transient = transientMode() { return transient }
        return compactMode(for: id)
    }

    /// 열린 메뉴가 접힌 아일랜드에 닿아 투명하게 숨기는 중인지 (알림이 대기 중이면 숨기지 않음)
    func isConcealed(_ id: ScreenID) -> Bool {
        isConcealed(id, mode: mode(for: id))
    }

    private func isConcealed(_ id: ScreenID, mode: IslandMode) -> Bool {
        guard concealedScreenIDs.contains(id), mode.isCompact else { return false }
        return !(id == transientTargetScreenID && alertMode() != nil)
    }

    /// 접힌 상태에서 보여줄 세션: 포커스 세션이 활동 중(넘기기 대상)이거나 고정한 세션이면 그것 (고정한 세션은 쉬는 중이어도),
    /// 아니면 작업 중인 첫 세션
    var compactSession: AgentSession? {
        if let focused = store.focusedSession,
           FocusEngine.isRotationCandidate(focused) || focused.id == store.pinnedSessionID {
            return focused
        }
        return store.rankedSessions.first { $0.phase.isWorking }
    }

    /// 접힌 상태의 세션 상태 요약: 펼친 목록 머리와 같은 모든 세션 요약 (`compactSummary(showing:)`)
    var compactSummary: SessionStatusSummary {
        compactSummary(showing: compactSession)
    }

    /// 접힌 상태의 세션 상태 요약. 보여주는 세션도 함께 센다: 예전처럼 빼고 세면 같은 순간 펼친 머리("● 2")와
    /// 접힌 상태("● 1")의 개수가 달라 보였고, 보여주는 세션이 바뀔 때마다 개수가 바뀌었다.
    /// 세션이 보여주는 세션 하나뿐이면 비운다 (그 세션이 이미 보이므로)
    private func compactSummary(showing session: AgentSession?) -> SessionStatusSummary {
        let sessions = store.rankedSessions
        if session != nil, sessions.count <= 1 { return .empty }
        return SessionStatusSummary(sessions: sessions)
    }

    /// 펼친 목록 머리의 요약: 모든 세션 (목록에 다 있으므로)
    var allSessionsSummary: SessionStatusSummary {
        SessionStatusSummary(sessions: store.rankedSessions)
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

    /// 입력 대기 중이거나, 훅 대기 없이 터미널(또는 Claude 앱)에서 승인을 기다리는 세션
    private func pendingInput() -> (sessionID: String, message: String, isPermissionPrompt: Bool)? {
        var candidates: [AgentSession] = []
        if let focused = store.focusedSession { candidates.append(focused) }
        candidates.append(contentsOf: store.rankedSessions)
        let hookPendingSessions = Set(store.pendingPermissions.map(\.sessionID))

        for session in candidates {
            switch session.phase {
            case .waitingInput where !hookPendingSessions.contains(session.id) && !store.isInputHandedOff(session.id):
                // 노치에서 답하는 질문 카드가 있거나(접어 둔 경우 포함) "터미널로" 넘긴 질문이면 입력 대기 카드를 따로 띄우지 않는다
                let message = inputMessages[session.id] ?? session.lastNotification ?? "입력이 필요해"
                return (session.id, message, false)
            case .waitingPermission where !hookPendingSessions.contains(session.id):
                // 버튼("터미널로" · "Claude로")과 같은 곳을 가리킨다
                return (session.id, "\(SessionHost(session.terminal).placeName)에서 승인 필요", true)
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

    // MARK: - 레이아웃 (순수 계산)

    // 모드 · 레이아웃 · 접힌 내용은 스토어 · 설정 · 화면 정보 · 시각과 화면마다 커밋한 배치 이력(`LayoutHistory`)만으로 정해진다.
    // 계산은 아무 상태도 바꾸지 않아서, 뷰 · 관찰 패스 · 겹침 감시가 어떤 순서로 몇 번 불러도 같은 값이다.
    // 배치 이력은 관찰 패스(`ScreenManager`)가 모든 화면을 한 번에 계산한 뒤 `commit` 에서만 옮긴다

    /// 화면 하나의 배치 이력: 직전에 그린 접힌 모양 · 열린 카드 띠 · 접히는 동안 붙잡는 띠 (`commit` 만 바꾼다).
    /// - 접힌 상태 → 카드: 카드는 직전 접힌 모양(부분 1 · 알약 · 접힌 내용)으로 부분 1 을 그리고, 열린 동안 그 카드 띠를 기억한다
    /// - 카드 → 접힌 상태: 카드 띠를 접히는 모양이 자리 잡을 때까지 붙잡는다 (`collapseHold`)
    /// - 숨김: 접힌 모양 이력을 지운다. 사라진 화면은 통째로 지운다
    struct LayoutHistory: Equatable {
        /// 직전에 그린 부분 1 (접힌 모양 또는 열린 카드 위의 접힌 모양). 카드를 펼치고 접는 동안 부분 1 을 그대로 두는 데 쓴다
        var part1: IslandLayout?
        /// 직전 메뉴바 알약 (노치 없는 화면). 펼친 카드가 같은 알약을 부분 1 로 쓴다
        var pill: CompactPlacement?
        /// 직전에 그린 접힌 내용 (폭 측정값). 펼친 카드는 지금 접힌 내용이 아니라 이 내용으로 부분 1 을 그린다:
        /// 카드를 여는 순간 · 열린 동안 접힌 내용이 바뀌어도(완료 확인 · 권한 요청 · 보여주는 세션 · 요약 · 툴) 부분 1 은 직전 접힌 모양 그대로.
        /// 접힌 상태를 그리지 않고(숨김) 카드를 열었으면 처음 계산한 내용을 카드가 열린 동안 쓴다
        var compactContent: CompactContent?
        /// 지금 열린 카드의 띠 · 목 알약 자리 (`IslandLayoutEngine.cardBand`). 카드가 접히기 시작하면 `collapseHold` 로 넘긴다
        var cardBand: CompactPlacement?
        /// 접히는 동안 붙잡는 카드 띠와 놓을 시각 (부팅 후 초, `uptime`).
        /// 카드가 열려 있는 동안 접힌 내용(다른 세션 요약 · 보여주는 세션 · 작업 중 ↔ 쉬는 중)이 바뀌었어도
        /// 접히는 동안엔 띠가 그대로이고, 모양이 자리 잡은 뒤 접힌 상태 안의 변화로 새 띠가 된다
        var collapseHold: CollapseHold?

        struct CollapseHold: Equatable {
            var band: CompactPlacement
            var until: TimeInterval
        }

        /// 접힌 상태 배치 이력(직전 부분 1 · 알약 · 접힌 내용)을 지운다. 다음 접힌 상태 · 카드는 지금 내용으로 새로 계산한다
        mutating func forgetCompact() {
            part1 = nil
            pill = nil
            compactContent = nil
        }

        /// 이번 모드로 계산할 때 쓰는 이력: 모드가 바뀌며 일어날 일을 미리 적용한다 (커밋도 이 값에서 시작한다).
        /// 카드가 접히기 시작하면 카드 띠를 붙잡고, 숨기거나 다시 펼치면 놓고, 놓을 시각이 지났으면 놓는다
        /// - Returns: 카드 띠를 이번에 붙잡기 시작했는지
        mutating func advance(to mode: IslandMode, now: TimeInterval) -> Bool {
            guard mode.isCompact else {
                collapseHold = nil
                if !mode.isOpen { cardBand = nil }
                return false
            }
            if let band = cardBand {
                cardBand = nil
                collapseHold = CollapseHold(band: band, until: now + IslandMotion.settleSeconds)
                return true
            }
            if let hold = collapseHold, hold.until <= now { collapseHold = nil }
            return false
        }
    }

    /// 관찰 패스가 화면 하나를 계산한 결과: 그릴 모드 · 레이아웃 · 투명 숨김과, 커밋하면 남을 배치 이력
    struct ScreenFrame {
        let mode: IslandMode
        let layout: IslandLayout
        let concealed: Bool
        /// 커밋하면 이 화면의 배치 이력이 될 값
        let history: LayoutHistory
        /// 레이아웃을 고른 접힌 자리 (접힌 상태면 그 자리, 펼친 카드면 카드 뒤의 접힌 자리, 숨김이면 nil. 로그용)
        let placement: CompactPlacement?
        /// 카드를 접기 시작해 카드 띠를 이번에 붙잡았는지 (커밋이 놓을 때 다시 계산하게 예약한다)
        let startsCollapseHold: Bool
        /// 접힌 폭 안정화에 넣은 측정값 (접힌 작업 중 세션을 그렸을 때. 커밋이 `CompactMetricsHold` 를 한 단계 옮긴다)
        let measuredCompact: CompactMeasurement?
        /// 피크 카드 본문 높이 (커밋이 붙잡는다)
        let peekBody: CGFloat?
    }

    /// 접힌 상태가 보여주는 세션의 폭 측정값 (안정화 전)
    struct CompactMeasurement {
        let metrics: CompactMetrics
        let session: String
    }

    /// 화면 하나를 지금 상태로 계산한다 (상태를 바꾸지 않는다)
    func frame(for id: ScreenID) -> ScreenFrame {
        let mode = mode(for: id)
        guard let resolved = resolve(id, mode: mode, now: uptime()) else {
            return ScreenFrame(
                mode: mode, layout: Self.emptyLayout, concealed: false, history: LayoutHistory(),
                placement: nil, startsCollapseHold: false, measuredCompact: nil, peekBody: nil
            )
        }
        return ScreenFrame(
            mode: mode,
            layout: resolved.layout,
            concealed: isConcealed(id, mode: mode),
            history: resolved.history,
            placement: resolved.placement,
            startsCollapseHold: resolved.startsCollapseHold,
            measuredCompact: resolved.measuredCompact,
            peekBody: resolved.peekBody
        )
    }

    /// 여러 화면을 한 번에 계산한다 (관찰 패스)
    func frames(for ids: [ScreenID]) -> [ScreenID: ScreenFrame] {
        Dictionary(ids.map { ($0, frame(for: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    func layout(for id: ScreenID, mode: IslandMode) -> IslandLayout {
        resolve(id, mode: mode, now: uptime())?.layout ?? Self.emptyLayout
    }

    private static let emptyLayout = IslandLayout(size: .zero, origin: .zero, shape: IslandShapeSpec(), compact: nil)

    /// 커밋한 배치 이력으로 만든 레이아웃 엔진 (접힌 자리 · 겹침 감시 영역 계산용. 놓을 시각이 지난 띠는 쓰지 않는다)
    func layoutEngine(for id: ScreenID) -> IslandLayoutEngine? {
        guard let geometry = geometries[id] else { return nil }
        var past = histories[id] ?? LayoutHistory()
        if let hold = past.collapseHold, hold.until <= uptime() { past.collapseHold = nil }
        return layoutEngine(geometry: geometry, id: id, history: past)
    }

    private func layoutEngine(geometry: NotchGeometry, id: ScreenID, history past: LayoutHistory) -> IslandLayoutEngine {
        IslandLayoutEngine(
            geometry: geometry,
            space: spaces[id],
            externalStyle: preferences.externalDisplayStyle,
            previousPill: past.pill,
            collapseHold: past.collapseHold?.band,
            previousPart1: past.part1
        )
    }

    /// 화면 하나를 계산한 값: 레이아웃 · 그때 쓴 엔진 · 접힌 자리와 이 계산을 커밋하면 남을 배치 이력
    private struct Resolution {
        var layout: IslandLayout
        var engine: IslandLayoutEngine
        var placement: CompactPlacement?
        var history: LayoutHistory
        var startsCollapseHold: Bool
        var measuredCompact: CompactMeasurement?
        var peekBody: CGFloat?
    }

    /// 모드 `mode` 의 레이아웃 (커밋한 배치 이력 + 모드가 바뀌며 일어날 일). 상태는 바꾸지 않는다
    private func resolve(_ id: ScreenID, mode: IslandMode, now: TimeInterval) -> Resolution? {
        // 붙잡은 폭 · 띠를 놓을 때가 되면 다시 계산한다
        _ = holdRevision
        guard let geometry = geometries[id] else { return nil }
        var history = histories[id] ?? LayoutHistory()
        let startsHold = history.advance(to: mode, now: now)
        let engine = layoutEngine(geometry: geometry, id: id, history: history)
        let resolved = resolvedLayout(for: mode, engine: engine, history: history)
        let result = resolved.layout
        let placement = resolved.placement

        // 커밋하면 남길 배치 이력
        if mode.isCompact {
            history.part1 = result
            history.compactContent = resolved.content
            if case .menuBarPill? = placement { history.pill = placement } else { history.pill = nil }
        } else if mode.isOpen, let placement {
            // 펼친 카드의 부분 1 (띠 · 알약)을 접힌 이력으로 기억한다:
            // 카드가 열려 있는 동안 부분 1 이 그대로이고, 접을 때도 같은 부분 1 에서 시작해(`collapseHold`) 접힌 뒤 이력대로 접힌 모양을 고른다
            if let part1 = resolved.part1 { history.part1 = part1 }
            if let content = resolved.content { history.compactContent = content }
            let band = engine.cardBand(for: placement)
            history.cardBand = band
            if case .menuBarPill = band { history.pill = band }
        } else if mode == .hidden {
            // 숨겼다가 여는 카드는 그때 내용으로 부분 1 을 새로 그린다: 숨기기 전 접힌 모양(두 줄 띠 등) · 알약 이력을 쓰지 않는다
            // (풀스크린 "알림만" 처럼 알림마다 숨김 → 카드가 되는 화면에서 카드 목이 지금 내용과 다른 높이로 열리지 않게)
            history.forgetCompact()
        }
        return Resolution(
            layout: result, engine: engine, placement: placement, history: history, startsCollapseHold: startsHold,
            measuredCompact: resolved.measured, peekBody: resolved.peekBody
        )
    }

    /// 접힌 상태 내용 (레이아웃 선택용 폭 측정).
    /// 세션 요약 폭도 툴 이름 · `+N −M` 처럼 붙잡아 둬서 개수가 바뀌어도 알약이 출렁이지 않는다 (붙잡은 값은 커밋에서 옮긴다)
    func compactContent(for mode: IslandMode) -> CompactContent {
        if mode == .working, let measured = compactMeasurement() {
            _ = holdRevision
            return .session(compactHold.value(for: measured.metrics, key: measured.session, now: uptime()))
        }
        return .idle(content: CompactText.summaryWidth(allSessionsSummary))
    }

    /// 접힌 상태가 보여주는 세션의 폭 측정값 (안정화 전). 작업 중인 세션이 없으면 nil
    private func compactMeasurement() -> CompactMeasurement? {
        guard let session = compactSession else { return nil }
        let summary = compactSummary(showing: session)
        return CompactMeasurement(metrics: CompactMetrics(session: session, summary: summary), session: session.id)
    }

    // MARK: - 커밋 (관찰 패스)

    /// 관찰 패스가 계산한 화면들을 커밋한다: 배치 이력 · 접힌 폭 안정화 · 피크 본문 높이를 이 한 곳에서만 옮긴다.
    /// 화면이 사라졌으면 그 화면 이력을 지운다 (덮개를 닫았다 연 내장 화면처럼 같은 ScreenID 로 돌아온 화면이
    /// 예전 띠를 붙잡거나 예전 부분 1 을 쓰지 않게). 카드 띠를 붙잡기 시작했거나 붙잡은 폭을 줄일 수 있게 되면
    /// 그때 다시 계산하도록 예약한다 (`holdRevision`)
    func commit(_ frames: [ScreenID: ScreenFrame]) {
        for id in Set(histories.keys).union(collapseHoldTasks.keys).union(loggedLayouts.keys) where geometries[id] == nil {
            forgetScreen(id)
        }
        let now = uptime()
        var measured: CompactMeasurement?
        for (id, frame) in frames where geometries[id] != nil {
            if histories[id] != frame.history { histories[id] = frame.history }
            if frame.startsCollapseHold {
                scheduleCollapseHoldRelease(on: id)
            } else if frame.history.collapseHold == nil, let task = collapseHoldTasks.removeValue(forKey: id) {
                task.cancel()
            }
            if let body = frame.peekBody { peekBodyHold = max(peekBodyHold, body) }
            if let value = frame.measuredCompact { measured = value }
            logLayoutChange(id, mode: frame.mode, layout: frame.layout, placement: frame.placement)
        }
        if let measured {
            compactHold.stabilize(measured.metrics, key: measured.session, now: now)
            scheduleCompactHoldRelease(at: compactHold.releaseAt, now: now)
        }
    }

    /// 지금 화면 정보로 모든 화면을 계산해 커밋한다 (관찰 패스 한 번. 스냅숏이 실제 앱의 패스 대신 부른다)
    @discardableResult
    func commitScreens() -> [ScreenID: ScreenFrame] {
        let frames = frames(for: screenOrder.filter { geometries[$0] != nil })
        commit(frames)
        return frames
    }

    /// 접히는 동안 붙잡은 카드 띠를 놓을 시각에 다시 계산하게 한다 (계산이 놓을 시각이 지난 띠를 쓰지 않고, 커밋이 지운다)
    private func scheduleCollapseHoldRelease(on id: ScreenID) {
        collapseHoldTasks[id]?.cancel()
        collapseHoldTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.collapseHoldDuration + .milliseconds(20))
            guard !Task.isCancelled, let self else { return }
            self.collapseHoldTasks[id] = nil
            self.holdRevision &+= 1
        }
    }

    /// 붙잡아 둔 폭을 줄일 수 있는 시각에 다시 계산하게 한다
    private func scheduleCompactHoldRelease(at deadline: TimeInterval?, now: TimeInterval) {
        guard let deadline else { return }
        if let pending = compactHoldTask, pending.deadline <= deadline + 0.01 { return }
        compactHoldTask?.task.cancel()
        let delay = max(0.05, deadline - now + 0.02)
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.compactHoldTask = nil
            self.holdRevision &+= 1
        }
        compactHoldTask = (task, deadline)
    }

    /// 사라진 화면의 배치 이력 · 붙잡은 띠 · 로그 기록을 모두 지운다
    private func forgetScreen(_ id: ScreenID) {
        histories.removeValue(forKey: id)
        collapseHoldTasks.removeValue(forKey: id)?.cancel()
        loggedLayouts.removeValue(forKey: id)
    }

    /// 로그에 남기는 레이아웃 값 (숫자 · 모드 종류 · 자리 종류만, 세션 이름 · 내용 없음)
    private struct LayoutLogEntry: Equatable {
        var mode: IslandMode.Kind
        var frame: CGRect
        var part1: CGRect
        var placement: String
    }

    /// 화면의 레이아웃이 바뀌었을 때만 디버그 로그를 남긴다 (`log stream --level debug --predicate 'category == "Presentation"'`)
    private func logLayoutChange(_ id: ScreenID, mode: IslandMode, layout: IslandLayout, placement: CompactPlacement?) {
        let entry = LayoutLogEntry(
            mode: mode.kind, frame: layout.panelRect, part1: layout.shape.part1.rect, placement: placement?.kindName ?? "none"
        )
        guard loggedLayouts[id] != entry else { return }
        loggedLayouts[id] = entry
        let f = entry.frame
        let p = entry.part1
        logger.debug("""
            레이아웃 화면 \(id, privacy: .public) \(String(describing: entry.mode), privacy: .public) \
            크기 \(Double(f.width), privacy: .public)×\(Double(f.height), privacy: .public) \
            원점 (\(Double(f.minX), privacy: .public), \(Double(f.minY), privacy: .public)) \
            부분1 (\(Double(p.minX), privacy: .public), \(Double(p.minY), privacy: .public), \
            \(Double(p.width), privacy: .public), \(Double(p.height), privacy: .public)) \
            자리 \(entry.placement, privacy: .public)
            """)
    }

    /// 레이아웃과 그때 쓴 접힌 자리 (접힌 상태면 그 자리, 펼친 카드면 카드 뒤의 접힌 자리, 숨김이면 nil),
    /// 펼친 카드의 부분 1, 접힌 자리를 고른 접힌 내용 (접힌 상태 · 펼친 카드), 접힌 폭 안정화에 넣은 측정값, 피크 본문 높이
    private func resolvedLayout(
        for mode: IslandMode,
        engine: IslandLayoutEngine,
        history: LayoutHistory
    ) -> (
        layout: IslandLayout, placement: CompactPlacement?, part1: IslandLayout?, content: CompactContent?,
        measured: CompactMeasurement?, peekBody: CGFloat?
    ) {
        typealias M = IslandMetrics
        let contentWidth: (CGFloat) -> CGFloat = { $0 - M.bodyPadding * 2 }

        func card(
            _ width: CGFloat, radius: CGFloat, peekBody: CGFloat? = nil, body: @escaping (CGFloat) -> CGFloat
        ) -> (IslandLayout, CompactPlacement?, IslandLayout?, CompactContent?, CompactMeasurement?, CGFloat?) {
            // 부분 1 은 직전에 그린 접힌 내용으로 (지금 접힌 내용이 바뀌었어도 카드가 열린 동안 그대로)
            var measured: CompactMeasurement?
            let content: CompactContent
            if let past = history.compactContent {
                content = past
            } else {
                let compactMode: IslandMode = compactSession == nil ? .idle : .working
                content = compactContent(for: compactMode)
                if compactMode == .working { measured = compactMeasurement() }
            }
            let compact = engine.compactPlacement(for: content)
            let part1 = engine.cardPart1(for: compact, content: content)
            let layout = engine.cardLayout(preferredWidth: width, radius: radius, part1: part1, bodyHeight: body)
            return (layout, compact, part1, content, measured, peekBody)
        }

        switch mode {
        case .hidden:
            return (engine.hiddenLayout(), nil, nil, nil, nil, nil)

        case .idle, .working:
            let content = compactContent(for: mode)
            let compact = engine.compactLayoutAndPlacement(for: content)
            return (compact.layout, compact.placement, nil, content, mode == .working ? compactMeasurement() : nil, nil)

        case let .peek(sessionID, diff):
            let rows = DiffPresentation.visibleLines(diff).count
            let hasText = streamingLine(for: sessionID) != nil
            let measured = M.bodyTop + M.lineHeight + 6 + M.diffRowsHeight(count: rows)
                + (hasText ? 8 + M.lineHeight : 0) + M.bodyBottom
            // 피크가 이어지는 동안엔 줄이지 않는다 (내용은 위쪽 정렬이라 아래가 조금 빈다)
            let body = max(measured, peekBodyHold)
            return card(M.peekWidth, radius: 22, peekBody: body) { _ in body }

        case let .permission(request, _):
            switch request.kind {
            case .permission:
                return card(M.permissionWidth, radius: 22) { width in
                    self.permissionCard(for: request, width: width).bodyHeight
                }
            case let .question(questions):
                return card(M.permissionWidth, radius: 22) { width in
                    self.questionCard(for: request, questions: questions, width: width).bodyHeight
                }
            case let .plan(plan):
                let body = PlanCardModel(plan: plan).bodyHeight
                return card(M.permissionWidth, radius: 22) { _ in body }
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

    /// 열린 메뉴와 겹치는지 볼 영역 (패널 기준). `layout` 은 지금 그린 레이아웃
    /// - zone: 지금 아일랜드 + 카드가 펼쳐질 자리 (겹치면 알림 펼침을 미루고 일시 펼침을 접는다)
    /// - island: 지금 아일랜드 + 그 아래 메뉴바 끝까지 6pt 더 (메뉴바 아이템에서 내려온 메뉴 · 팝오버).
    ///   여기와 겹칠 때만 접힌 상태를 숨긴다 (카드 자리 아래쪽에 뜬 다른 앱 팝업 · 툴팁엔 숨지 않는다)
    func overlapZones(for id: ScreenID, layout: IslandLayout) -> (zone: CGRect, island: CGRect)? {
        guard let engine = layoutEngine(for: id) else { return nil }
        let current = layout.panelRect
        let bottom = max(current.maxY, engine.menuBarHeight) + 6
        let island = CGRect(x: current.minX - 4, y: current.minY, width: current.width + 8, height: bottom - current.minY)
        return (current.union(engine.cardZone()), island)
    }

    /// 설정이 켜져 있을 때만 보여줄 최근 응답 한 줄
    func streamingLine(for sessionID: String) -> String? {
        guard preferences.showStreamingText else { return nil }
        return store.latestTextLine(for: sessionID)
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
        onOpenSettings(section)
    }

    /// 권한 카드 버튼 · 단축키의 결정. 승인하는 결정은 요청이 보인 지 `shortcutSettleDelay` 가 지나야 전달한다
    func resolve(_ request: PermissionRequestInfo, decision: PermissionDecision) {
        guard acceptsDecision(decision, for: request) else { return }
        logger.debug("권한 결정 전달")
        actions.resolvePermission(id: request.id, decision: decision)
    }

    /// 결정을 지금 전달해도 되는지. 승인(허용 · 항상 허용 · 계획 승인 · 답)은 그 요청이 카드에 보인 지
    /// `shortcutSettleDelay` 가 지나야 받는다 (클릭 · 단축키 모두): 대기열의 다음 요청이 같은 자리에 바뀌어 들어온 순간
    /// 두 번째 클릭 · 키가 보지 못한 요청을 승인하지 않게. 거부 · 넘기기는 바로 받는다
    private func acceptsDecision(_ decision: PermissionDecision, for request: PermissionRequestInfo) -> Bool {
        switch decision {
        case .deny, .passthrough:
            return true
        case .allow, .allowAlways, .answer:
            guard isSettled(request) else {
                logger.debug("새 요청 직후 승인 무시")
                return false
            }
            return true
        }
    }

    /// 터미널로: 노치에서 결정하지 않고 Claude Code 기본 프롬프트로 넘긴 뒤 터미널로 이동.
    /// 질문 · 계획 승인은 그 다이얼로그에 답할 때까지 입력 대기 카드를 다시 띄우지 않는다 (`SessionStore.handOff`)
    func sendToTerminal(_ request: PermissionRequestInfo) {
        actions.handOff(requestID: request.id)
        actions.jumpToTerminal(sessionID: request.sessionID)
    }

    // MARK: - 질문 · 계획 승인 카드

    /// 알림 카드(질문 · 계획 승인)의 행 · 버튼을 누름: 카드가 보이는 화면 패널을 키 윈도우로 만들어
    /// 이어서 숫자 키 · ↩ · "기타" 글자 입력을 받는다 (카드가 뜨기만 해서는 다른 앱의 키보드 포커스를 뺏지 않는다)
    func requestAlertKey() {
        guard let id = transientTargetScreenID else { return }
        onRequestKey?(id)
    }

    /// 권한 카드 내용 (요청 · 카드 폭마다 한 번 계산한다)
    func permissionCard(for request: PermissionRequestInfo, width: CGFloat) -> PermissionCardModel {
        let key = CardKey(request: request.id, width: width)
        if let card = permissionCards[key] { return card }
        if !permissionCards.isEmpty { permissionCards = permissionCards.filter { isPending($0.key.request) } }
        let card = PermissionCardModel(request: request, cardWidth: width)
        permissionCards[key] = card
        return card
    }

    /// 질문 카드 내용 (요청 · 카드 폭마다 한 번 계산한다)
    func questionCard(for request: PermissionRequestInfo, questions: [QuestionItem], width: CGFloat) -> QuestionCardModel {
        let key = CardKey(request: request.id, width: width)
        if let card = questionCards[key] { return card }
        if !questionCards.isEmpty { questionCards = questionCards.filter { isPending($0.key.request) } }
        let card = QuestionCardModel(questions: questions, cardWidth: width)
        questionCards[key] = card
        return card
    }

    private func isPending(_ requestID: UUID) -> Bool {
        store.pendingPermissions.contains { $0.id == requestID }
    }

    /// 질문 카드의 답 (요청마다 하나, 처음 부를 때 만든다). 질문이 아니면 nil
    func questionDraft(for request: PermissionRequestInfo) -> QuestionDraft? {
        guard case let .question(questions) = request.kind else { return nil }
        if let draft = questionDrafts[request.id] { return draft }
        let pendingIDs = Set(store.pendingPermissions.map(\.id))
        questionDrafts = questionDrafts.filter { pendingIDs.contains($0.key) }
        let draft = QuestionDraft(questions: questions)
        questionDrafts[request.id] = draft
        return draft
    }

    /// 선택지를 고름 (클릭 · 숫자 키). 한 개만 고르는 질문이면 그 질문의 답이 되어 다음 쪽으로 넘어가고
    /// (아직 답하지 않은 질문 먼저), 마지막 쪽에서 모두 답했으면 바로 보낸다. 여러 개 고르는 질문은 켜고 끄기만 한다.
    /// 카드가 막 보였을 때(`shortcutSettleDelay` 안)는 고르기만 하고 보내지 않는다 (카드가 뜨는 순간의 잘못된 클릭, `submitAnswers`)
    func pickOption(_ option: Int, in request: PermissionRequestInfo) {
        guard let draft = questionDraft(for: request) else { return }
        let question = draft.page
        draft.pick(option, question: question)
        guard !draft.questions[question].multiSelect, draft.isAnswered(question) else { return }
        if !draft.isLastPage {
            draft.go(to: draft.nextUnanswered ?? question + 1)
        } else if draft.allAnswered {
            submitAnswers(request)
        } else if let next = draft.nextUnanswered {
            draft.go(to: next)
        }
    }

    /// 질문 카드 주 버튼 (↩): 지금 질문에 답했으면 다음 질문으로, 마지막 쪽에서 모두 답했으면 보낸다
    func advanceOrSubmit(_ request: PermissionRequestInfo) {
        guard let draft = questionDraft(for: request) else { return }
        if draft.isLastPage {
            if draft.allAnswered {
                submitAnswers(request)
            } else if let next = draft.nextUnanswered {
                draft.go(to: next)
            }
        } else if draft.isAnswered(draft.page) {
            draft.go(to: draft.page + 1)
        }
    }

    /// 고른 답을 보낸다 (모든 질문에 답했고, 질문이 보인 지 `shortcutSettleDelay` 가 지났을 때만)
    func submitAnswers(_ request: PermissionRequestInfo) {
        guard let answers = questionDraft(for: request)?.answers else { return }
        let decision = PermissionDecision.answer(answers)
        guard acceptsDecision(decision, for: request) else { return }
        logger.debug("질문 답 전달")
        actions.resolvePermission(id: request.id, decision: decision)
    }

    /// 계획 승인 (계획이 보인 지 `shortcutSettleDelay` 가 지났을 때만)
    func approvePlan(_ request: PermissionRequestInfo) {
        guard case .plan = request.kind, acceptsDecision(.allow, for: request) else { return }
        logger.debug("계획 승인 전달")
        actions.resolvePermission(id: request.id, decision: .allow)
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
        switch request.kind {
        case .permission:
            // ↩ · 숫자 키는 권한 카드에서 쓰지 않는다
            if case .submit = shortcut { return false }
            if case .pick = shortcut { return false }
        case .question, .plan:
            return performInteraction(shortcut, request: request)
        }
        // 방금 바뀐 요청은 아직 읽지 못했을 수 있다 → 결정하지 않고 키만 소비 (경고음 없이 무시)
        guard isSettled(request) else {
            logger.debug("새 권한 요청 직후 단축키 무시")
            return true
        }
        let card = permissionCard(for: request, width: layout(for: id, mode: mode).cardWidth)
        switch shortcut {
        case .allow:
            guard card.canAllow else { return true }
            resolve(request, decision: .allow)
        case .allowAlways:
            guard card.canAllowAlways else { return true }
            resolve(request, decision: .allowAlways)
        case .deny:
            resolve(request, decision: .deny(message: nil))
        case .collapse, .submit, .pick:
            break
        }
        return true
    }

    /// 질문 · 계획 승인 카드의 단축키: ↩ · ⌘↩ 다음 · 보내기 · 승인, 숫자 키 선택지. 거부 · 항상 허용은 없다 (키만 소비)
    private func performInteraction(_ shortcut: Shortcut, request: PermissionRequestInfo) -> Bool {
        switch shortcut {
        case .pick(let option):
            guard case .question = request.kind else { return false }
            pickOption(option, in: request)
        case .allow, .submit:
            guard isSettled(request) else {
                logger.debug("새 질문 직후 단축키 무시")
                return true
            }
            if case .plan = request.kind {
                approvePlan(request)
            } else {
                advanceOrSubmit(request)
            }
        case .allowAlways, .deny, .collapse:
            break
        }
        return true
    }

    // MARK: - 승인 대기 시계 (아일랜드 뷰가 알린다)

    /// 화면의 내용 구조가 바뀌기 시작했다 (`IslandContainer`: 이전 내용이 흐려지기 시작 · 바로 바뀜).
    /// 그 화면에 보이던 요청 카드의 승인 대기를 지워서, 다시 보일 때 처음부터 잰다
    func contentWillChange(on screen: ScreenID) {
        if displayedPermission?.screen == screen { displayedPermission = nil }
    }

    /// 화면에 내용이 보이기 시작했다 (`IslandContainer`: 내용 교체가 끝나 새 내용이 나타남 · 교체 없이 바로 보임 · 패널이 붙음).
    /// 요청 카드(권한 · 질문 · 계획)면 이때부터 승인 대기(`shortcutSettleDelay`)를 잰다: 모드가 바뀐 때가 아니라
    /// 그 요청 내용이 실제로 나타난 때부터라, 내용 교체 지연이 길어져도 승인을 막는 시간이 줄지 않는다
    func contentDidAppear(_ key: IslandContentKey, on screen: ScreenID) {
        guard let request = key.request else {
            if displayedPermission?.screen == screen { displayedPermission = nil }
            return
        }
        if let shown = displayedPermission, shown.id == request, shown.screen == screen { return }
        displayedPermission = (request, screen, uptime())
    }

    /// 이 요청 카드가 보인 지 `shortcutSettleDelay` 이상 지났고, 그 화면이 아직 이 요청을 보여주는지
    private func isSettled(_ request: PermissionRequestInfo) -> Bool {
        guard let shown = displayedPermission, shown.id == request.id,
              case let .permission(current, _) = mode(for: shown.screen), current.id == request.id
        else { return false }
        return uptime() - shown.since >= Self.shortcutSettleDelay
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
        if case .peek = value, case .peek? = transient {} else { peekBodyHold = 0 }
        transient = value
        transientTask?.cancel()
        let seconds = max(0.5, duration)
        transientTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.transient == value else { return }
            self.peekBodyHold = 0
            self.transient = nil
        }
    }

    /// 다른 표시 상태가 커밋한 배치 이력(부분 1 · 알약 · 접힌 내용 · 열린 카드 띠)으로 이 표시 상태의 이력을 채운다.
    /// 붙잡은 띠는 그대로 (스냅숏 전환 시트용: 전 · 후 상태를 다른 가짜 세계로 만들어서, 전 상태를 그린 앱이 후 상태를 계산하는 것과 같게)
    func adoptLayoutHistory(from other: PresentationController) {
        for id in Set(histories.keys).union(other.histories.keys) {
            let source = other.histories[id] ?? LayoutHistory()
            var target = histories[id] ?? LayoutHistory()
            target.part1 = source.part1
            target.pill = source.pill
            target.compactContent = source.compactContent
            target.cardBand = source.cardBand
            histories[id] = target
        }
    }

    /// 타이머 없이 일시 펼침을 띄운다 (스냅숏 렌더링용)
    func setTransientForSnapshot(_ value: Transient) {
        transientTask?.cancel()
        transientTask = nil
        peekBodyHold = 0
        transient = value
    }

    private func clearTransient() {
        transientTask?.cancel()
        transientTask = nil
        peekBodyHold = 0
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
        if !questionDrafts.isEmpty || !permissionCards.isEmpty || !questionCards.isEmpty {
            let pendingIDs = Set(store.pendingPermissions.map(\.id))
            questionDrafts = questionDrafts.filter { pendingIDs.contains($0.key) }
            permissionCards = permissionCards.filter { pendingIDs.contains($0.key.request) }
            questionCards = questionCards.filter { pendingIDs.contains($0.key.request) }
        }
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
    /// 상세가 잘렸을 때 안내 (세션을 띄운 앱에서 확인하라고)
    static func clippedNote(_ host: SessionHost) -> String {
        "요청이 길어서 다 못 보여줘 · \(host.placeName)에서 확인해 줘"
    }

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
