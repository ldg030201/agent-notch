import Foundation
import Observation
import os
import NotchShared

/// 모든 세션 상태의 단일 진실 공급원.
///
/// - 훅 이벤트(`HookEnvelope`)를 받아 세션 상태를 갱신한다.
/// - 포커스(주로 볼 세션)를 계산한다.
/// - UI 가 일시적으로 반응할 신호(`latestSignal`)를 내보낸다.
/// - 권한 요청 대기열을 관리하고, 사용자 결정을 `onPermissionResolved` 로 알린다.
///   노치에서 답하는 질문 · 계획 승인(AskUserQuestion · ExitPlanMode 의 PreToolUse)도 같은 대기열을 쓴다 (`PermissionRequestInfo.kind`).
///
/// 단계 모델: 이벤트 처리 · 사용자 동작은 메인 턴의 단계(`AgentSession.mainPhase`) · `mainTurnEnded` 와 세션별 대기 목록(`waits`)만 바꾸고,
/// 보이는 단계(`AgentSession.phase`)는 모든 진입점의 끝에서 `finalize` 한 곳이 정한다:
/// 승인 대기 > 입력 대기 > Claude 앱 확인 추정(턴이 진행 중일 때) > 메인 턴 단계(끝난 턴이면 끝난 단계).
/// 대기는 이벤트로 끝나는 규칙(`releaseWaits`) 한 곳에서만 지우고, 사용자 결정 · 훅 연결 끊김 · 시간 초과는 그 요청 하나만 뺀다.
///
/// NOTE: 공개 API 시그니처는 다른 모듈(UI, Services, App)이 의존하는 계약이므로 변경하지 않는다.
@MainActor
@Observable
public final class SessionStore {
    /// session_id → 세션
    public private(set) var sessions: [String: AgentSession] = [:]
    /// 포커스 우선순위 순으로 정렬된 세션 목록 (UI 목록용)
    public private(set) var rankedSessions: [AgentSession] = []
    /// 지금 노치가 주로 보여줄 세션
    public private(set) var focusedSessionID: String?
    /// 사용자가 고정한 세션
    public private(set) var pinnedSessionID: String?
    /// 응답 대기 중인 권한 요청 · 질문 · 계획 승인 (오래된 순). 각 요청은 그 세션의 대기 목록(`waits`)에도 `.hook` 대기로 있다
    public private(set) var pendingPermissions: [PermissionRequestInfo] = []
    /// 세션별 대기 목록 (세션 ID → 대기). 훅 대기 요청과, 훅 없이 세션 앱(터미널 · Claude 앱) 다이얼로그를 기다리는 대기를 함께 둔다.
    /// 누가(어느 에이전트의 어느 호출이) 기다리는지 기억해서 병렬로 도는 다른 에이전트의 툴 진행으로 대기가 지워지지 않게 한다.
    /// 밖에서는 `isInputHandedOff` 로 넘긴 질문을 본다 (관찰 대상이라 `@ObservationIgnored` 를 붙이지 않는다)
    private var waits: [String: [Wait]] = [:]
    /// UI 일시 반응용 최신 신호
    public private(set) var latestSignal: SignalEvent?
    /// 세션별 응답 스트리밍 텍스트 (MessageDisplay delta 누적, 최근 `AgentSession.maxStreamingCharacters` 자).
    /// 세션과 따로 두는 이유: delta 는 초당 여러 번 오는데 이 글을 보여주는 곳은 미리보기 · 완료 · 펼친 상세뿐이다.
    /// `sessions` 에 쓰면 접힌 아일랜드 · 모든 화면 레이아웃이 delta 마다 다시 계산된다
    public private(set) var streamingTexts: [String: String] = [:]

    /// 권한 요청에 대한 사용자 결정이 나면 호출된다 (SocketServer 가 훅 프로세스에 응답을 전달).
    public var onPermissionResolved: (@MainActor (PermissionRequestInfo, PermissionDecision) -> Void)?

    /// Claude 데스크톱 앱 확인 카드 추정 규칙 (`checkStalledTools()`)
    @ObservationIgnored public var appConsent: AppConsentHeuristic = .default
    /// 대화 기록 브랜치를 읽어도 되는 `~/.claude` 의 홈 폴더 (`transcriptBranch`. 테스트는 가짜 홈)
    @ObservationIgnored var homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path

    private let clock: () -> Date

    /// 사용자가 직접 선택한 세션 (세션이 제거되면 해제)
    @ObservationIgnored private var manualFocusID: String?
    /// PreCompact 직전 메인 턴 단계 (PostCompact 에서 복귀)
    @ObservationIgnored private var phaseBeforeCompact: [String: SessionPhase] = [:]
    /// Claude 앱 확인 카드를 띄울 수 있어 지켜보는 실행 중인 툴 (세션 ID → tool_use_id → 상태)
    @ObservationIgnored private var consentWatches: [String: [String: ConsentWatch]] = [:]
    /// 세션별로 도는 것을 본 서브에이전트 `agent_id` (SubagentStart, 시작을 놓쳤으면 그 서브에이전트의 다른 이벤트).
    /// 턴 끝 목록에서만 아는 작업은 "task:<id>". `activeSubagents` 는 이 집합의 크기다
    @ObservationIgnored private var runningSubagents: [String: Set<String>] = [:]
    @ObservationIgnored private var signalSeq = 0

    private static let logger = Logger(subsystem: NotchWire.logSubsystem, category: "SessionStore")
    /// `lastAssistantMessage` 보관 최대 길이 (뒤쪽 유지)
    private static let maxAssistantMessageCharacters = 4_000

    public init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    public var focusedSession: AgentSession? {
        focusedSessionID.flatMap { sessions[$0] }
    }

    // MARK: - 이벤트 반영

    /// 훅 이벤트를 반영한다. 응답을 기다려야 하는 호출(PermissionRequest, 노치에서 답할 질문 · 계획 승인의 PreToolUse)이면
    /// 요청 ID 를 반환한다. nil 이면 훅은 바로 "결정 없음" 응답을 받는다.
    @discardableResult
    public func ingest(_ envelope: HookEnvelope) -> UUID? {
        let payload = HookPayload(envelope.payload)
        let event = TextUtils.nonEmpty(envelope.event) ?? payload.string("hook_event_name") ?? ""
        guard let sessionID = payload.string("session_id") else {
            Self.logger.debug("session_id 없는 이벤트 무시: \(event, privacy: .public)")
            return nil
        }
        Self.logger.debug("이벤트 \(event, privacy: .public) 세션 \(sessionID, privacy: .private)")
        let now = clock()
        let agentID = payload.string("agent_id")

        // 세션 종료: 제거하고 남은 권한 대기는 결정 없이 풀어준다
        if event == "SessionEnd" {
            let released = removeSession(sessionID)
            recomputeFocus()
            releasePassthrough(released)
            return nil
        }

        // 응답 스트리밍: 이미 아는 세션이면 글만 덧붙이고 끝낸다 (세션 · 포커스를 건드리지 않음)
        if event == "MessageDisplay", sessions[sessionID] != nil {
            appendStreaming(sessionID: sessionID, payload: payload)
            return nil
        }

        // 이 이벤트로 끝난 것으로 볼 수 있는 대기를 지운다 (다른 경로(터미널)에서 이미 답한 훅 요청은 꺼내 결정 없이 풀어 준다)
        let released = releaseWaits(event: event, sessionID: sessionID, agentID: agentID, payload: payload)

        let isNew = sessions[sessionID] == nil
        var session = sessions[sessionID] ?? makeSession(id: sessionID, payload: payload, now: now)
        applyCommonFields(&session, payload: payload, environment: envelope.env, now: now)
        // 시작을 못 본 서브에이전트(앱을 새로 띄움 등)도 이벤트가 오면 도는 중으로 센다.
        // SubagentStop 은 빼고: Claude 앱이 턴 끝마다 시작 없이 보내는 종료는 무시해야 한다
        if let agentID, event != "SubagentStart", event != "SubagentStop" {
            noteRunningSubagent(&session, agentID: agentID)
        }
        // 메인 에이전트가 툴을 쓰면 턴이 진행 중이다 (Stop 훅이 막아 이어진 턴, 되살린 뒤 놓친 프롬프트 등)
        if agentID == nil, Self.toolEvents.contains(event) { session.mainTurnEnded = false }

        var signal: IslandSignal?
        var requestID: UUID?
        switch event {
        case "SessionStart":
            signal = handleSessionStart(&session, payload: payload, isNew: isNew)
        case "UserPromptSubmit":
            handleUserPromptSubmit(&session, payload: payload, now: now)
        case "PreToolUse":
            signal = handlePreToolUse(&session, payload: payload, agentID: agentID, now: now)
            if let toolName = payload.string("tool_name"), Self.userInteractionTools.contains(toolName) {
                // 헬퍼가 답을 기다리는 질문 · 계획 승인이면 노치에서 답하도록 대기열에 넣는다.
                // 노치에서 답하지 않는 질문 · 계획 승인(예전 훅 설정 · 줄인 payload · 답할 수 없는 모양)은 세션 앱 다이얼로그에서 답한다
                if envelope.expectsReply {
                    requestID = queueInteraction(&session, payload: payload, agentID: agentID, now: now)?.id
                }
                if requestID == nil {
                    addSessionAppWait(sessionID, agentID: agentID, toolUseID: payload.string("tool_use_id"), kind: .input)
                }
            }
        case "PostToolUse":
            signal = handlePostToolUse(&session, payload: payload, agentID: agentID, now: now)
        case "PostToolUseFailure":
            handlePostToolUseFailure(&session, payload: payload, agentID: agentID, now: now)
        case "PermissionRequest":
            if let toolName = payload.string("tool_name"), Self.userInteractionTools.contains(toolName) {
                // 답 · 계획 승인은 Claude Code 다이얼로그에서만 할 수 있다 (updatedInput 없는 allow 는 무시됨).
                // 대기열에 넣지 않고 nil → 훅에 바로 "결정 없음" 응답, 카드는 입력 대기로 보여준다.
                signal = handleUserInteractionRequest(&session, toolName: toolName, payload: payload, agentID: agentID)
            } else {
                let info = handlePermissionRequest(&session, payload: payload, agentID: agentID, now: now)
                requestID = info.id
                signal = .permissionRequested(id: info.id, sessionID: sessionID)
                linkConsentWatch(info, toolInput: Self.isShrunk(payload) ? nil : payload["tool_input"], in: session)
                restartConsentClocks(sessionID, at: now)
            }
        case "Notification":
            signal = handleNotification(&session, payload: payload, agentID: agentID, now: now)
        case "MessageDisplay":
            // 처음 보는 세션의 첫 이벤트가 스트리밍인 경우 (세션은 위 공통 경로가 만든다)
            appendStreaming(sessionID: sessionID, payload: payload)
        case "Stop":
            signal = handleStop(&session, payload: payload, now: now)
        case "StopFailure":
            signal = handleStopFailure(&session, payload: payload, now: now)
        case "SubagentStart":
            handleSubagentStart(&session, payload: payload, now: now)
        case "SubagentStop":
            handleSubagentStop(&session, payload: payload, now: now)
            // 기다리던 서브에이전트가 끝나 그 대기가 풀렸으면 대기에서 나와 턴을 이어 간다 (남은 대기는 finalize 가 다시 보여준다)
            if released.any, Self.isWait(session.phase) { settleAfterTool(&session) }
        case "PreCompact":
            handlePreCompact(&session, now: now)
        case "PostCompact":
            handlePostCompact(&session, payload: payload, now: now)
        default:
            // 알 수 없는 이벤트: 공통 필드(lastEventAt 등)만 갱신
            break
        }

        // 다른 곳에서 답한 권한 요청의 툴은 실행됐는지 모른다 (거부면 PostToolUse 가 오지 않는다) → 지켜보지 않는다
        for request in released.requests { dropConsentWatch(permissionID: request.id, sessionID: sessionID) }
        if !released.requests.isEmpty { restartConsentClocks(sessionID, at: now) }
        finalize(&session, now: now)
        trimActivities(&session)
        sessions[sessionID] = session

        if let signal { emit(signal, at: now) }
        recomputeFocus()
        releasePassthrough(released.requests)
        return requestID
    }

    // MARK: - 보이는 단계

    /// 모든 진입점의 끝: 보이는 단계(`phase`)를 남은 대기와 메인 턴 단계로 정한다.
    /// - 승인 대기(훅 권한 요청 · 세션 앱 승인 다이얼로그)가 하나라도 있으면 승인 대기
    /// - 입력 대기(노치 질문 · 세션 앱 질문 · MCP 입력 요청)가 있으면 입력 대기
    /// - 턴이 진행 중(생각 중 · 툴 실행)이고 Claude 앱 확인 카드를 기다리는 것으로 알린 툴이 아직 실행 중이면 입력 대기 (현재 활동은 그 툴)
    /// - 아니면 메인 턴 단계. 끝난 턴은 작업 단계로 보이지 않는다 (끝난 단계: `settledPhase`)
    private func finalize(_ session: inout AgentSession, now: Date) {
        // 끝난(또는 타임라인에서 밀려난) 툴은 지켜보기에서 뺀다
        pruneConsentWatches(session)
        // 훅 권한 카드가 우선. 승인 대기 동안은 툴이 실행되지 않으므로 앱 확인 지연도 세지 않는다
        if hasPending(session.id) { restartConsentClocks(session.id, at: now) }

        let base = session.mainTurnEnded && Self.isTurnWork(session.mainPhase) ? Self.settledPhase(session) : session.mainPhase
        let sessionWaits = waits[session.id] ?? []
        if sessionWaits.contains(where: { $0.kind == .permission }) {
            session.phase = .waitingPermission
        } else if !sessionWaits.isEmpty {
            session.phase = .waitingInput
        } else if Self.isTurnWork(base), let waiting = consentWaitingActivity(session) {
            session.phase = .waitingInput
            session.currentActivity = waiting
        } else {
            session.phase = base
        }
    }

    /// 턴이 이어진다 (툴 시작 · 끝, 결정 반영): 메인 턴 단계를 생각 중 · 툴 실행으로 바꾼다.
    /// 메인 턴이 끝난 뒤(백그라운드 서브에이전트의 이벤트 · 질문 · 승인)에는 끝난 단계를 지킨다:
    /// 대기에서 풀리는 것이면 확인 여부로 정한 끝난 단계(`settledPhase`)로 돌아간다
    private func resumeTurn(_ session: inout AgentSession, phase: SessionPhase) {
        if session.mainTurnEnded {
            if Self.isWait(session.phase) { session.mainPhase = Self.settledPhase(session) }
        } else {
            session.mainPhase = phase
        }
    }

    /// `resumeTurn` 과 같고 현재 활동도 바꾼다. 메인 턴이 끝났으면 현재 활동은 아직 실행 중일 때만 남긴다
    private func resumeTurn(_ session: inout AgentSession, phase: SessionPhase, activity: ActivityItem?) {
        resumeTurn(&session, phase: phase)
        session.currentActivity = session.mainTurnEnded ? Self.stillRunning(session.currentActivity, in: session) : activity
    }

    // MARK: - 앱을 새로 띄웠을 때 되살리기

    /// 대화 기록으로 되살린 세션을 넣는다 (`TranscriptTail`). 앱을 새로 띄운 사이 이미 돌고 있던 세션을
    /// 다음 훅 이벤트 전에도 보여주려는 것이라 알림(완료 · 미리보기 · 입력 대기 카드)은 띄우지 않는다.
    /// 이미 이벤트로 알게 된 세션은 건드리지 않는다 (이벤트가 더 정확하다)
    public func restore(_ restored: [RestoredSession]) {
        let now = clock()
        var count = 0
        for item in restored where sessions[item.id] == nil {
            var session = AgentSession(
                id: item.id,
                cwd: item.cwd,
                projectName: TextUtils.projectName(forCwd: item.cwd),
                // 브랜치는 대화 기록에 적힌 것만 쓴다 (앱은 프로젝트 폴더를 읽지 않는다)
                gitBranch: item.gitBranch,
                startedAt: item.lastEventAt,
                lastEventAt: item.lastEventAt
            )
            session.terminal = TerminalContext(entrypoint: item.entrypoint)
            switch item.state {
            case let .runningTool(name, input, toolUseID):
                let activity = Self.toolActivity(
                    id: toolUseID, toolName: name, toolInput: input, cwd: item.cwd, agentID: nil, at: item.lastEventAt
                )
                appendActivity(&session, activity)
                session.currentActivity = activity
                session.turnStartedAt = item.lastEventAt
                session.mainPhase = .runningTool
                if Self.userInteractionTools.contains(name) {
                    // 세션 앱 다이얼로그에서 답하는 질문 (기록은 메인 대화 줄만 본다)
                    addSessionAppWait(item.id, agentID: nil, toolUseID: activity.id, kind: .input)
                }
            case .thinking:
                session.turnStartedAt = item.lastEventAt
                session.mainPhase = .thinking
            case .finished:
                // 메인 턴이 끝난 세션 (이후 서브에이전트 이벤트는 백그라운드 작업). 턴이 언제 시작했는지는 모르므로
                // 소요 시간을 지어내지 않고(`turnStartedAt` 없음) 끝난 시각만 기록의 마지막 시각으로 둔다
                session.mainPhase = .completed
                session.mainTurnEnded = true
                session.turn.endedAt = item.lastEventAt
            }
            finalize(&session, now: now)
            sessions[item.id] = session
            count += 1
        }
        if count > 0 {
            Self.logger.info("대화 기록으로 세션 \(count, privacy: .public)개 되살림")
            recomputeFocus()
        }
    }

    // MARK: - 사용자 동작

    /// 사용자가 권한 요청 · 질문 · 계획 승인에 대해 결정함 → 대기열에서 제거하고 `onPermissionResolved` 호출.
    /// 훅 출력을 만들 수 없는 결정(질문에 답이 빠짐 등)은 결정 없음(`.passthrough`)으로 바꿔 전달한다
    public func resolvePermission(id: UUID, decision: PermissionDecision) {
        resolve(id: id, decision: decision, handingOff: false)
    }

    /// 카드의 "터미널로" · "Claude로": 노치에서 정하지 않고 결정 없이 풀어 세션 앱의 다이얼로그로 넘긴다.
    /// 질문 · 계획 승인이면 그 다이얼로그에 답할 때까지 같은 호출로 입력 대기 카드를 다시 띄우지 않게 기억한다
    /// (이어서 오는 같은 툴의 PermissionRequest · permission_prompt 알림 포함). 권한 요청은 `.passthrough` 와 같다
    public func handOff(id: UUID) {
        resolve(id: id, decision: .passthrough, handingOff: true)
    }

    /// 이 세션의 질문 · 계획 승인을 사용자가 세션 앱으로 넘겼고 아직 그 다이얼로그를 기다리는 중인지
    public func isInputHandedOff(_ sessionID: String) -> Bool {
        waits[sessionID]?.contains { $0.handedOff } == true
    }

    private func resolve(id: UUID, decision: PermissionDecision, handingOff: Bool) {
        guard let taken = removePending(id) else { return }
        let (info, agentID) = taken
        let decision = PermissionReplyBuilder.effectiveDecision(for: info, decision: decision)
        // 거부하면 툴이 실행되지 않아 PostToolUse 가 오지 않을 수 있고, 터미널로 넘기면 결과를 모른다 → 그 호출은 지켜보지 않는다.
        // 허용이면 승인 대기 동안 툴이 실행되지 않았으니 앱 확인 카드 지연은 지금부터 잰다
        switch decision {
        case .allow, .allowAlways, .answer: unlinkConsentWatch(permissionID: id, sessionID: info.sessionID)
        case .deny, .passthrough: dropConsentWatch(permissionID: id, sessionID: info.sessionID)
        }
        let now = clock()
        restartConsentClocks(info.sessionID, at: now)

        if var session = sessions[info.sessionID] {
            // 이 요청이 마지막 훅 요청이고 그 대기로 보이던 중이면 턴이 이어진다 (권한 요청은 승인 대기, 질문 · 계획 승인은 입력 대기)
            let waiting: SessionPhase = info.isInteraction ? .waitingInput : .waitingPermission
            let leaves = session.phase == waiting && !hasPending(info.sessionID)
            switch decision {
            case .allow, .allowAlways, .answer:
                if leaves { resumeTurn(&session, phase: .runningTool) }
            case .deny:
                if leaves { resumeTurn(&session, phase: .thinking) }
            case .passthrough:
                // 세션 앱(터미널 · Claude 앱)에서 직접 답해야 하므로 대기 유지.
                // 다른 에이전트의 툴 진행으로 지워지지 않게 누가(어느 호출이) 기다리는지 기억한다
                let toolUseID = info.toolUseID
                    ?? Self.waitingToolUseID(in: session, agentID: agentID, toolName: info.toolName)
                addSessionAppWait(
                    info.sessionID, agentID: agentID, toolUseID: toolUseID,
                    kind: info.isInteraction ? .input : .permission, handedOff: handingOff && info.isInteraction
                )
            }
            finalize(&session, now: now)
            if session != sessions[info.sessionID] { sessions[info.sessionID] = session }
        }
        recomputeFocus()
        onPermissionResolved?(info, decision)
    }

    /// 훅 연결이 응답 전에 끊김 → 대기열에서만 제거 (`onPermissionResolved` 호출 안 함).
    /// 앱의 기다리는 시간(최대 585초)이 훅 시간 제한(600초)보다 먼저 끝나므로 끊김은 시간 초과가 아니다:
    /// - 질문 · 계획 승인: Claude Code 가 기다리던 훅을 끊은 것(Esc · 중단 · 종료)이라 다이얼로그도 뜨지 않는다 →
    ///   입력 대기를 풀고(쉬는 중) 그 툴을 실패로 닫는다 (카드도, 이어지는 입력 대기 카드도 남지 않게)
    /// - 권한 요청: Esc · 중단이거나 Claude 앱 자체 다이얼로그에서 답했다 → 승인 대기를 푼다 (`leavePermissionWait`).
    ///   그대로 두면 idle_prompt 가 올 때까지 "터미널에서 · Claude 앱에서 승인 필요" 카드가 남는다
    /// 다른 요청 · 세션 앱 다이얼로그 대기가 남아 있으면 그 대기로 보여준다
    public func cancelPermission(id: UUID) {
        guard let info = takePending(id)?.info else { return }
        if var session = sessions[info.sessionID] {
            if !hasPending(info.sessionID) {
                // 다른 에이전트의 세션 앱 다이얼로그가 아직 기다리면 턴이 끝났다고 보지 않는다 (그 대기로 보여준다)
                let othersWaiting = waits[info.sessionID]?.isEmpty == false
                if info.isInteraction, session.phase == .waitingInput {
                    let now = clock()
                    if let toolUseID = info.toolUseID {
                        for index in session.activities.indices
                        where session.activities[index].id == toolUseID && session.activities[index].status == .running {
                            session.activities[index].status = .failed
                            session.activities[index].endedAt = now
                        }
                        if session.currentActivity?.id == toolUseID { session.currentActivity = nil }
                    }
                    session.mainPhase = .idle
                    if !othersWaiting { session.mainTurnEnded = true }
                } else if !info.isInteraction, session.phase == .waitingPermission, !othersWaiting {
                    leavePermissionWait(&session)
                }
            }
            finalize(&session, now: clock())
            if session != sessions[info.sessionID] { sessions[info.sessionID] = session }
        }
        recomputeFocus()
    }

    /// 훅 연결이 끊긴 권한 요청의 승인 대기에서 나온다 (`cancelPermission`). 끊긴 이유는 알 수 없어 세션 앱으로 추정한다:
    /// - 메인 답변이 이미 끝났으면(백그라운드 서브에이전트의 요청) 끝난 단계로
    /// - Claude 앱 세션: 앱 자체 다이얼로그에서 답했을 가능성이 크다 → 허용이면 툴 실행 중, 거부면 응답을 이어 간다
    ///   (`settleAfterTool`: 요청한 툴이 실행 중으로 남아 있으면 툴 실행, 아니면 생각 중. 이어지는 툴 이벤트가 바로잡는다)
    /// - 터미널(CLI): 승인을 기다리던 훅은 Esc · 중단으로만 끊긴다 → 쉬는 중 (이어서 오는 이벤트가 없다)
    private func leavePermissionWait(_ session: inout AgentSession) {
        if session.mainTurnEnded {
            session.mainPhase = Self.settledPhase(session)
        } else if session.terminal.isClaudeDesktopApp {
            settleAfterTool(&session)
        } else {
            session.mainPhase = .idle
            session.currentActivity = nil
            session.mainTurnEnded = true
        }
    }

    /// 노치에서 기다리는 시간(`permissionTimeout`)이 지나 결정 없이 풀어 줌 (SocketServer 가 이미 "결정 없음" 으로 응답함).
    /// 이어서 Claude Code 다이얼로그가 뜨므로 승인 · 입력 대기를 그대로 두고(그 다이얼로그로 안내하는 카드),
    /// 다른 에이전트의 툴 진행으로 지워지지 않게 누가 기다리는지 기억한다
    public func expirePermission(id: UUID) {
        guard let taken = takePending(id) else { return }
        let (info, agentID) = taken
        if var session = sessions[info.sessionID] {
            let toolUseID = info.toolUseID
                ?? Self.waitingToolUseID(in: session, agentID: agentID, toolName: info.toolName)
            addSessionAppWait(
                info.sessionID, agentID: agentID, toolUseID: toolUseID, kind: info.isInteraction ? .input : .permission
            )
            finalize(&session, now: clock())
            if session != sessions[info.sessionID] { sessions[info.sessionID] = session }
        }
        recomputeFocus()
    }

    /// 대기열에서 하나를 꺼낸다 (결정 없이 끝난 요청: 허용됐는지 모르므로 그 호출은 앱 확인 카드 추정에서 뺀다)
    private func takePending(_ id: UUID) -> (info: PermissionRequestInfo, agentID: String?)? {
        guard let taken = removePending(id) else { return nil }
        // 다른 곳(Claude 앱 · 터미널)에서 먼저 답했거나 시간이 지났다: 허용됐는지 모른다 → 그 호출은 지켜보지 않는다
        dropConsentWatch(permissionID: id, sessionID: taken.info.sessionID)
        restartConsentClocks(taken.info.sessionID, at: clock())
        return taken
    }

    /// 고정 토글 (이미 고정된 세션이면 해제)
    public func togglePin(sessionID: String) {
        if pinnedSessionID == sessionID {
            pinnedSessionID = nil
        } else if sessions[sessionID] != nil {
            pinnedSessionID = sessionID
        } else {
            return
        }
        recomputeFocus()
    }

    /// 사용자가 명시적으로 세션을 선택함
    public func focus(sessionID: String) {
        guard sessions[sessionID] != nil else { return }
        manualFocusID = sessionID
        recomputeFocus()
    }

    /// 완료 알림 확인 처리 (끝난 단계는 유휴로. 대기가 남아 있으면 그 대기가 풀린 뒤 유휴)
    public func markSeen(sessionID: String) {
        guard var session = sessions[sessionID] else { return }
        session.hasUnseenCompletion = false
        if session.mainPhase == .completed || session.mainPhase == .failed {
            session.mainPhase = .idle
        }
        finalize(&session, now: clock())
        sessions[sessionID] = session
        recomputeFocus()
    }

    /// 목록에서 세션 제거
    public func dismiss(sessionID: String) {
        guard sessions[sessionID] != nil else { return }
        let released = removeSession(sessionID)
        recomputeFocus()
        releasePassthrough(released)
    }

    /// 오래 이벤트가 없는 세션 정리
    public func pruneStaleSessions(olderThan interval: TimeInterval) {
        let cutoff = clock().addingTimeInterval(-interval)
        let stale = sessions.values
            .filter { $0.lastEventAt < cutoff && !hasPending($0.id) }
            .map(\.id)
        guard !stale.isEmpty else { return }
        for id in stale {
            _ = removeSession(id)
        }
        recomputeFocus()
    }

    /// Claude 데스크톱 앱이 띄우는 확인 카드(예: "화면을 전체 제어할까요?")를 기다리는 것으로 보이는 툴을 찾는다.
    ///
    /// 이 카드는 훅이 오지 않으므로 앱이 1초마다 호출한다. 다음이 모두 맞으면 입력 대기 + `.needsInput` 신호:
    /// - Claude 데스크톱 앱 세션
    /// - `appConsent` 허용 목록의 툴이 PostToolUse 없이 그 툴의 지연(`AppConsentHeuristic.delay`) 이상 실행 중 (훅 승인 대기 시간은 빼고 잰다)
    /// - 다른 대기가 없고 툴 실행 중 (생각 중이면 Claude Code 는 실행 중인 툴이 없다고 본다. 예: 거부 직후)
    /// 같은 tool_use_id 에는 신호를 한 번만 보낸다. 툴이 끝나면(PostToolUse · Stop 등) 평소 상태로 돌아간다.
    public func checkStalledTools() {
        guard !consentWatches.isEmpty else { return }
        let now = clock()
        var changed = false
        for sessionID in Array(consentWatches.keys) {
            guard var session = sessions[sessionID] else {
                consentWatches[sessionID] = nil
                continue
            }
            finalize(&session, now: now)
            var signal: IslandSignal?
            if session.phase == .runningTool, let stalled = stalledConsentActivity(session, now: now) {
                consentWatches[sessionID]?[stalled.id]?.signaled = true
                finalize(&session, now: now)
                signal = .needsInput(sessionID: sessionID, message: AppConsentHeuristic.message(toolTitle: stalled.title))
            }
            if session != sessions[sessionID] {
                sessions[sessionID] = session
                changed = true
            }
            if let signal { emit(signal, at: now) }
        }
        if changed { recomputeFocus() }
    }

    // MARK: - 이벤트별 처리

    private func handleSessionStart(_ session: inout AgentSession, payload: HookPayload, isNew: Bool) -> IslandSignal? {
        // 압축 후 재시작(source: compact)은 진행 중인 턴을 그대로 둔다
        if !isNew, payload.string("source") == "compact" { return nil }
        if !isNew, !session.cwd.isEmpty {
            session.projectName = TextUtils.projectName(forCwd: session.cwd)
            refreshBranch(&session, payload: payload)
        }
        session.mainPhase = .idle
        session.mainTurnEnded = false
        session.currentActivity = nil
        phaseBeforeCompact[session.id] = nil
        return .sessionStarted(sessionID: session.id)
    }

    private func handleUserPromptSubmit(_ session: inout AgentSession, payload: HookPayload, now: Date) {
        let prompt = payload["prompt"]?.stringValue.map(TextUtils.cleanPrompt)
        // 이전 턴에서 끝나지 않은 활동(인터럽트 등)은 실패로 닫는다 (아직 도는 백그라운드 서브에이전트의 활동은 빼고)
        closeRunningActivities(&session, status: .failed, at: now)
        session.mainPhase = .thinking
        session.mainTurnEnded = false
        session.turnStartedAt = now
        session.turn = TurnSummary()
        session.lastPrompt = TextUtils.nonEmpty(prompt)
        // 새 턴에 이전 턴의 마지막 답변이 보이지 않게 (`latestTextLine` 은 스트리밍이 비면 이 값을 쓴다)
        if streamingTexts[session.id] != nil { streamingTexts[session.id] = nil }
        session.lastAssistantMessage = nil
        session.hasUnseenCompletion = false
        session.errorMessage = nil
        session.currentActivity = nil
        phaseBeforeCompact[session.id] = nil
        if let prompt = session.lastPrompt {
            appendActivity(&session, ActivityItem(
                id: UUID().uuidString,
                kind: .prompt,
                title: TextUtils.truncate(prompt, max: 80),
                detail: prompt,
                symbolName: "text.bubble",
                status: .succeeded,
                startedAt: now,
                endedAt: now
            ))
        }
        if !session.cwd.isEmpty {
            refreshBranch(&session, payload: payload)
        }
    }

    private func handlePreToolUse(
        _ session: inout AgentSession,
        payload: HookPayload,
        agentID: String?,
        now: Date
    ) -> IslandSignal? {
        let toolName = payload.string("tool_name") ?? "Tool"
        let toolInput = payload["tool_input"]
        let item = Self.toolActivity(
            id: payload.string("tool_use_id"), toolName: toolName, toolInput: toolInput, cwd: session.cwd, agentID: agentID, at: now
        )
        if appendActivity(&session, item) {
            session.turn.toolCount += 1
        }
        if session.terminal.isClaudeDesktopApp,
           let delay = appConsent.delay(toolName: toolName, toolInput: toolInput),
           consentWatches[session.id]?[item.id] == nil {
            consentWatches[session.id, default: [:]][item.id] = ConsentWatch(
                since: now, delay: delay, toolName: toolName, toolInput: Self.isShrunk(payload) ? nil : toolInput
            )
        }

        if Self.userInteractionTools.contains(toolName) {
            // 질문 · 계획 승인: 노치나 세션 앱 다이얼로그에서 답을 기다린다 (대기는 부르는 쪽이 넣는다).
            // 새 입력 요청이므로 넘긴 질문이 있어도 다시 카드로 알린다
            session.currentActivity = item
            if !session.mainTurnEnded { session.mainPhase = .runningTool }
            clearHandOff(session.id)
            return .needsInput(sessionID: session.id, message: Self.inputMessage(toolName: toolName, toolInput: toolInput))
        }
        resumeTurn(&session, phase: .runningTool, activity: item)
        return nil
    }

    /// 사용자가 직접 답하는 툴 (질문 · 계획 승인). 권한 카드의 허용만으로는 답할 수 없어서
    /// PreToolUse 에서 노치가 답을 받거나(`queueInteraction`), Claude Code 다이얼로그로 넘긴다
    static let userInteractionTools: Set<String> = NotchWire.interactiveTools

    /// 질문 · 계획 승인 툴의 PreToolUse (헬퍼가 답을 기다림): 노치에서 답할 수 있으면 대기열에 넣는다.
    /// 헬퍼가 payload 를 줄였거나(원래 입력을 그대로 돌려줄 수 없음) 노치에서 답할 수 없는 입력이면 nil →
    /// 훅은 바로 "결정 없음" 응답을 받고 Claude Code 다이얼로그로 답한다 (입력 대기 카드)
    private func queueInteraction(
        _ session: inout AgentSession,
        payload: HookPayload,
        agentID: String?,
        now: Date
    ) -> PermissionRequestInfo? {
        let toolName = payload.string("tool_name") ?? ""
        guard Self.userInteractionTools.contains(toolName), !Self.isShrunk(payload),
              let toolInput = payload["tool_input"],
              let kind = InteractionParser.kind(toolName: toolName, toolInput: toolInput)
        else { return nil }
        let info = PermissionRequestInfo(
            id: UUID(),
            sessionID: session.id,
            toolName: toolName,
            title: toolName == "ExitPlanMode" ? "계획 승인" : "질문",
            detail: Self.inputMessage(toolName: toolName, toolInput: toolInput),
            toolInput: toolInput,
            suggestions: nil,
            receivedAt: now,
            kind: kind,
            toolUseID: payload.string("tool_use_id")
        )
        addPending(info, agentID: agentID)
        return info
    }

    private static func inputMessage(toolName: String, toolInput: JSONValue?) -> String {
        if toolName == "ExitPlanMode" { return "계획 승인 필요" }
        return ToolSummarizer.firstQuestion(in: toolInput) ?? "질문에 답변 필요"
    }

    /// AskUserQuestion · ExitPlanMode 의 PermissionRequest: 입력 대기로만 표시 (PreToolUse 를 놓쳤을 때만 신호).
    /// 세션 앱 다이얼로그에서 답하므로 누가 기다리는지 기억한다 (넘긴 질문이면 이미 있는 대기와 합친다)
    private func handleUserInteractionRequest(
        _ session: inout AgentSession,
        toolName: String,
        payload: HookPayload,
        agentID: String?
    ) -> IslandSignal? {
        let toolUseID = Self.waitingToolUseID(in: session, agentID: agentID, toolName: toolName)
        // 노치에서 넘긴 그 질문이면 사용자는 이미 다이얼로그로 갔다 (다른 에이전트의 승인 대기가 보이는 중이어도 새로 알리지 않는다)
        let handedOff = waits[session.id]?.contains { wait in
            wait.handedOff && (wait.toolUseID == nil || toolUseID == nil || wait.toolUseID == toolUseID)
        } == true
        addSessionAppWait(session.id, agentID: agentID, toolUseID: toolUseID, kind: .input)
        if handedOff { return nil }
        guard session.phase != .waitingInput else { return nil }
        clearHandOff(session.id)
        return .needsInput(sessionID: session.id, message: Self.inputMessage(toolName: toolName, toolInput: payload["tool_input"]))
    }

    private func handlePostToolUse(
        _ session: inout AgentSession,
        payload: HookPayload,
        agentID: String?,
        now: Date
    ) -> IslandSignal? {
        let toolName = payload.string("tool_name") ?? "Tool"
        var outcome = DiffEngine.outcome(
            toolName: toolName,
            toolInput: payload["tool_input"],
            toolResponse: payload["tool_response"]
        )
        // 헬퍼가 payload 를 줄였는데 hunk(structuredPatch · bashEditDiff)가 없으면 입력이 64KB 로 잘렸거나 원본(originalFile)이 빠져
        // 직접 센 줄 수를 믿을 수 없다 (예: 큰 파일 덮어쓰기가 "+50000 −50000" 대신 "+1307 −0"). 바뀐 파일만 센다
        if let counted = outcome, Self.isShrunk(payload), !Self.hasReportedDiff(payload["tool_response"]) {
            outcome = DiffOutcome(snippet: nil, changedFiles: counted.changedFiles, added: 0, removed: 0)
        }
        let index = toolActivityIndex(&session, payload: payload, toolName: toolName, agentID: agentID, now: now)
        session.activities[index].status = .succeeded
        session.activities[index].endedAt = now
        session.activities[index].diff = outcome?.snippet

        var signal: IslandSignal?
        if let outcome {
            for path in outcome.changedFiles where !session.turn.changedFiles.contains(path) {
                session.turn.changedFiles.append(path)
            }
            session.turn.added += outcome.added
            session.turn.removed += outcome.removed
            if let snippet = outcome.snippet {
                session.lastDiff = snippet
                signal = .edited(sessionID: session.id, diff: snippet)
            }
        }
        noteBackgroundLaunch(&session, toolName: toolName, payload: payload)
        settleAfterTool(&session)
        return signal
    }

    private func handlePostToolUseFailure(
        _ session: inout AgentSession,
        payload: HookPayload,
        agentID: String?,
        now: Date
    ) {
        let toolName = payload.string("tool_name") ?? "Tool"
        let index = toolActivityIndex(&session, payload: payload, toolName: toolName, agentID: agentID, now: now)
        session.activities[index].status = .failed
        session.activities[index].endedAt = now

        if payload.bool("is_interrupt") == true {
            // 사용자 인터럽트: 에러가 아니라 턴 중단 (Stop 이벤트가 오지 않음). 예전처럼 실행 중인 활동을 모두 닫는다
            closeRunningActivities(&session, status: .failed, at: now, keepingRunningSubagents: false)
            session.currentActivity = nil
            session.mainPhase = .idle
            session.mainTurnEnded = true
        } else {
            settleAfterTool(&session)
        }
    }

    private func handlePermissionRequest(
        _ session: inout AgentSession,
        payload: HookPayload,
        agentID: String?,
        now: Date
    ) -> PermissionRequestInfo {
        let toolName = payload.string("tool_name") ?? "Tool"
        let toolInput = payload["tool_input"] ?? .null
        let summary = ToolSummarizer.permissionSummary(toolName: toolName, toolInput: toolInput, cwd: session.cwd)
        let info = PermissionRequestInfo(
            id: UUID(),
            sessionID: session.id,
            toolName: toolName,
            title: summary.title,
            detail: summary.detail,
            toolInput: toolInput,
            suggestions: payload["permission_suggestions"],
            receivedAt: now,
            // 헬퍼가 큰 payload 를 줄였으면 카드에 보이는 입력이 실제 실행될 입력과 다를 수 있다
            isDetailTruncated: summary.isTruncated || Self.isShrunk(payload)
        )
        addPending(info, agentID: agentID)
        return info
    }

    private func handleNotification(
        _ session: inout AgentSession,
        payload: HookPayload,
        agentID: String?,
        now: Date
    ) -> IslandSignal? {
        let message = payload.string("message")
        if let message { session.lastNotification = message }

        switch payload.string("notification_type") {
        case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
            addSessionAppWait(
                session.id, agentID: agentID,
                toolUseID: Self.waitingToolUseID(in: session, agentID: agentID, toolName: nil), kind: .input
            )
            // 새 입력 요청이므로 넘긴 질문이 있어도 다시 카드로 알린다
            clearHandOff(session.id)
            return .needsInput(sessionID: session.id, message: message ?? "입력 필요")
        case "permission_prompt":
            // 훅 대기 요청이 있으면 PermissionRequest 로 이미 표시 중
            guard !hasPending(session.id) else { return nil }
            // 노치에서 "터미널로" 넘긴 질문 · 계획 승인 다이얼로그 알림: 사용자는 이미 그쪽으로 갔다
            if isInputHandedOff(session.id) { return nil }
            // 알림에는 툴 정보가 없다: 그 에이전트(agent_id, 없으면 메인)가 실행 중인 툴이 하나뿐이면 그 호출로 본다
            addSessionAppWait(
                session.id, agentID: agentID,
                toolUseID: Self.waitingToolUseID(in: session, agentID: agentID, toolName: nil), kind: .permission
            )
            return .needsInput(sessionID: session.id, message: message ?? "승인 필요")
        case "elicitation_complete", "elicitation_response":
            if session.phase == .waitingInput { resumeTurn(&session, phase: .thinking) }
            return nil
        case "idle_prompt":
            // 프롬프트 입력 대기 알림 = 턴이 끝났고 열린 다이얼로그도 없다.
            // - 아직 작업 중으로 보이면 종료 이벤트를 놓친 것 (인터럽트 등)
            // - 훅 대기 없는 승인 대기 · 입력 대기는 터미널에서 거부/Esc 로 끝난 것 (그때는 아무 이벤트도 오지 않는다)
            // 훅이 아직 노치 결정을 기다리면 그대로 둔다 (그 요청이 풀릴 때 단계를 정한다)
            guard !hasPending(session.id) else { return nil }
            session.mainTurnEnded = true
            if session.phase.isWorking || Self.isWait(session.phase) {
                // 아직 도는 백그라운드 서브에이전트의 툴은 그대로 둔다
                for index in session.activities.indices
                where session.activities[index].kind == .tool && session.activities[index].status == .running
                    && !isRunningSubagent(session.activities[index].agentID, in: session.id) {
                    session.activities[index].status = .failed
                    session.activities[index].endedAt = now
                }
                session.mainPhase = .idle
                session.currentActivity = nil
            }
            return nil
        default:
            return nil
        }
    }

    /// 응답 스트리밍 텍스트에 MessageDisplay delta 를 덧붙인다 (`streamingTexts`)
    private func appendStreaming(sessionID: String, payload: HookPayload) {
        guard let delta = payload["delta"]?.stringValue, !delta.isEmpty else { return }
        var text = streamingTexts[sessionID] ?? ""
        // 새 메시지의 첫 조각이면 이전 메시지와 줄바꿈으로 구분
        if payload.int("index") == 0, !text.isEmpty, !text.hasSuffix("\n") {
            text += "\n"
        }
        text += delta
        // 바이트 수가 한도 안이면 글자 수도 한도 안이다 (`count` 는 매번 처음부터 세므로 먼저 거른다)
        if text.utf8.count > AgentSession.maxStreamingCharacters, text.count > AgentSession.maxStreamingCharacters {
            text = String(text.suffix(AgentSession.maxStreamingCharacters))
        }
        streamingTexts[sessionID] = text
    }

    /// 아일랜드에 한 줄로 보여줄 세션의 최근 응답 텍스트 (스트리밍 중이면 그 마지막 줄, 아니면 마지막 답변의 마지막 줄)
    public func latestTextLine(for sessionID: String) -> String? {
        sessions[sessionID]?.latestTextLine(streaming: streamingTexts[sessionID])
    }

    private func handleStop(_ session: inout AgentSession, payload: HookPayload, now: Date) -> IslandSignal {
        if let message = payload.string("last_assistant_message") {
            session.lastAssistantMessage = String(message.suffix(Self.maxAssistantMessageCharacters))
        }
        // 작업 목록으로 아직 도는 서브에이전트를 먼저 맞추고, 그 서브에이전트의 활동은 닫지 않는다
        reconcileBackgroundTasks(&session, payload: payload, includesSubagents: true)
        closeRunningActivities(&session, status: .succeeded, at: now)
        session.currentActivity = nil
        session.mainPhase = .completed
        session.mainTurnEnded = true
        session.turn.endedAt = now
        session.hasUnseenCompletion = true
        phaseBeforeCompact[session.id] = nil
        return .completed(sessionID: session.id)
    }

    private func handleStopFailure(_ session: inout AgentSession, payload: HookPayload, now: Date) -> IslandSignal {
        session.errorMessage = payload.string("error_details")
            ?? payload.string("error").map(Self.describeError)
            ?? "알 수 없는 오류"
        closeRunningActivities(&session, status: .failed, at: now)
        session.currentActivity = nil
        session.mainPhase = .failed
        session.mainTurnEnded = true
        session.turn.endedAt = now
        session.hasUnseenCompletion = true
        phaseBeforeCompact[session.id] = nil
        return .failed(sessionID: session.id)
    }

    private func handleSubagentStart(_ session: inout AgentSession, payload: HookPayload, now: Date) {
        noteRunningSubagent(&session, agentID: payload.string("agent_id") ?? "unknown:\(UUID().uuidString)")
        appendActivity(&session, ActivityItem(
            id: Self.subagentActivityID(payload.string("agent_id")),
            kind: .subagent,
            title: Self.subagentTitle(payload.string("agent_type")),
            symbolName: "person.2",
            status: .running,
            startedAt: now,
            agentID: payload.string("agent_id")
        ))
    }

    /// 도는 것을 본 서브에이전트만 끝낸다 (시작 · 다른 이벤트를 봤거나 턴 끝 목록의 "task:<id>").
    /// 그 밖의 종료(Claude 앱이 턴이 끝날 때마다 시작 없이 보내는 내부 보조 작업 등)는 무시한다:
    /// 세면 실제로 도는 서브에이전트 수가 줄고, 타임라인에 가짜 "Agent" 가 붙고, 그 이벤트의 작업 목록으로 셸 수까지 지워진다
    private func handleSubagentStop(_ session: inout AgentSession, payload: HookPayload, now: Date) {
        guard let agentID = payload.string("agent_id"),
              var running = runningSubagents[session.id],
              running.remove(agentID) != nil || running.remove("task:\(agentID)") != nil
        else {
            Self.logger.debug("시작을 못 본 SubagentStop 무시")
            return
        }
        setRunningSubagents(running, in: &session)
        // 그 서브에이전트 항목과, 결과가 오지 않은 채 남은 그 서브에이전트의 툴을 닫는다
        for index in session.activities.indices
        where session.activities[index].agentID == agentID && session.activities[index].status == .running {
            session.activities[index].status = .succeeded
            session.activities[index].endedAt = now
        }
        if let current = session.currentActivity,
           current.agentID == agentID || current.id == Self.subagentActivityID(agentID) {
            if session.phase == .runningTool {
                settleAfterTool(&session)
            } else {
                session.currentActivity = nil
            }
        }
        reconcileBackgroundTasks(&session, payload: payload, includesSubagents: false)
    }

    /// 서브에이전트가 도는 중으로 센다 (SubagentStart, 시작을 못 본 서브에이전트의 다른 이벤트 — 앱을 새로 띄우기 전에 시작한 서브에이전트 등).
    /// 턴 끝 목록에서만 알던 "task:<id>" 는 그 ID 로 바꾼다 (이후 SubagentStop 으로 끝낼 수 있게)
    private func noteRunningSubagent(_ session: inout AgentSession, agentID: String) {
        var running = runningSubagents[session.id] ?? []
        guard !running.contains(agentID) else { return }
        running.remove("task:\(agentID)")
        running.insert(agentID)
        setRunningSubagents(running, in: &session)
    }

    /// 도는 서브에이전트 집합과 세션의 `activeSubagents` 를 함께 바꾼다 (둘이 어긋나지 않게). 빈 집합은 지운다
    private func setRunningSubagents(_ running: Set<String>, in session: inout AgentSession) {
        runningSubagents[session.id] = running.isEmpty ? nil : running
        session.activeSubagents = running.count
    }

    /// 아직 도는 서브에이전트의 ID 인지 (메인 에이전트(nil)는 아님)
    private func isRunningSubagent(_ agentID: String?, in sessionID: String) -> Bool {
        guard let agentID, let running = runningSubagents[sessionID] else { return false }
        return running.contains(agentID) || running.contains("task:\(agentID)")
    }

    // MARK: - 백그라운드 작업

    /// 백그라운드로 시작한 툴 (Bash `run_in_background`, Monitor). 끝났다는 훅은 오지 않아서 턴이 끝날 때 맞춘다
    private func noteBackgroundLaunch(_ session: inout AgentSession, toolName: String, payload: HookPayload) {
        if toolName == "Bash", payload["tool_input"]?["run_in_background"]?.boolValue == true {
            session.backgroundShells += 1
        } else if Self.backgroundToolNames.contains(toolName) {
            session.backgroundOthers += 1
        }
    }

    /// 실행하면 그 자체로 백그라운드 작업이 되는 툴 (서브에이전트는 SubagentStart 로 따로 센다)
    static let backgroundToolNames: Set<String> = ["Monitor"]

    /// Stop · SubagentStop 의 `background_tasks`(아직 도는 작업 목록)로 개수를 맞춘다. 목록이 없으면(작업 목록을 못 읽음 · 줄인 payload) 그대로 둔다.
    /// SubagentStop 목록에는 지금 끝나는 서브에이전트가 남아 있을 수 있어서 서브에이전트 수는 Stop 에서만 맞춘다
    private func reconcileBackgroundTasks(_ session: inout AgentSession, payload: HookPayload, includesSubagents: Bool) {
        guard let tasks = payload["background_tasks"]?.arrayValue else {
            Self.logger.debug("백그라운드 작업 목록 없음 (그대로 둠)")
            return
        }
        let counts = Self.backgroundTaskCounts(tasks)
        Self.logger.debug("백그라운드 작업 목록: 셸 \(counts.shells, privacy: .public) · 서브에이전트 \(counts.subagentIDs.count, privacy: .public) · 기타 \(counts.others, privacy: .public) (서브에이전트 맞춤 \(includesSubagents, privacy: .public))")
        session.backgroundShells = counts.shells
        session.backgroundOthers = counts.others
        guard includesSubagents else { return }
        // 목록에 남은 서브에이전트만 남긴다. 시작을 본 ID 와 같으면 그 ID 로(이후 SubagentStop 으로 끝낼 수 있게),
        // 모르는 작업은 "task:<id>" 로 센다 (다음 턴 끝 목록에서 다시 맞춘다)
        let known = runningSubagents[session.id] ?? []
        var next = Set<String>()
        for taskID in counts.subagentIDs {
            if let taskID, known.contains(taskID) {
                next.insert(taskID)
            } else {
                next.insert("task:\(taskID ?? UUID().uuidString)")
            }
        }
        setRunningSubagents(next, in: &session)
    }

    /// `background_tasks` 를 종류별로 센 결과 (서브에이전트는 작업 ID 목록, ID 가 없으면 nil)
    struct BackgroundTaskCounts: Equatable {
        var shells = 0
        var subagentIDs: [String?] = []
        var others = 0
    }

    /// `background_tasks` 항목을 종류별로 센다 (끝난 상태로 남은 항목은 뺀다)
    static func backgroundTaskCounts(_ tasks: [JSONValue]) -> BackgroundTaskCounts {
        var counts = BackgroundTaskCounts()
        for task in tasks {
            let status = task["status"]?.stringValue?.lowercased() ?? ""
            if finishedTaskStatuses.contains(status) { continue }
            let type = task["type"]?.stringValue?.lowercased() ?? ""
            if type.contains("shell") || type.contains("bash") {
                counts.shells += 1
            } else if type == "subagent" || type.hasSuffix("agent") {
                counts.subagentIDs.append(TextUtils.nonEmpty(task["id"]?.stringValue))
            } else {
                counts.others += 1
            }
        }
        return counts
    }

    static let finishedTaskStatuses: Set<String> = [
        "completed", "complete", "done", "finished", "failed", "error", "killed", "stopped", "cancelled", "canceled",
    ]

    private func handlePreCompact(_ session: inout AgentSession, now: Date) {
        if session.mainPhase != .compacting {
            phaseBeforeCompact[session.id] = session.mainPhase
        }
        session.mainPhase = .compacting
        appendActivity(&session, ActivityItem(
            id: UUID().uuidString,
            kind: .compaction,
            title: "컨텍스트 압축",
            symbolName: "arrow.down.right.and.arrow.up.left",
            status: .running,
            startedAt: now
        ))
    }

    private func handlePostCompact(_ session: inout AgentSession, payload: HookPayload, now: Date) {
        for index in session.activities.indices
        where session.activities[index].kind == .compaction && session.activities[index].status == .running {
            session.activities[index].status = .succeeded
            session.activities[index].endedAt = now
        }
        let previous = phaseBeforeCompact.removeValue(forKey: session.id)
        guard session.mainPhase == .compacting else { return }
        // 직전 상태를 모르면: 수동 압축은 입력 대기, 자동 압축은 턴 진행 중
        session.mainPhase = previous ?? (payload.string("trigger") == "manual" ? .idle : .thinking)
    }

    // MARK: - 브랜치

    /// 세션 브랜치를 다시 정한다 (새 세션 · SessionStart · 새 프롬프트 · 작업 폴더를 처음 알았을 때).
    /// - 훅 헬퍼가 SessionStart · UserPromptSubmit 에 붙인 브랜치(`NotchWire.gitBranchKey`, 빈 문자열이면 저장소가 아님).
    ///   헬퍼는 Claude Code 프로세스 안에서 프로젝트 폴더를 읽으므로 앱은 프로젝트 폴더를 건드리지 않는다
    ///   (보호 폴더(문서 · 데스크탑 · 다운로드 · iCloud 등)는 읽기만 해도 앱에 접근 허락 창이 뜬다)
    /// - 키가 없으면(예전 헬퍼 · 다른 이벤트로 처음 본 세션) 대화 기록 끝부분의 `gitBranch` (`transcriptBranch`).
    ///   그것도 없으면 알던 값을 그대로 둔다
    private func refreshBranch(_ session: inout AgentSession, payload: HookPayload) {
        if let reported = payload[NotchWire.gitBranchKey]?.stringValue {
            session.gitBranch = TextUtils.nonEmpty(reported)
        } else if let branch = Self.transcriptBranch(atPath: session.transcriptPath, home: homeDirectory) {
            session.gitBranch = branch
        }
    }

    /// 대화 기록(`transcript_path`) 끝부분에 적힌 마지막 브랜치. 훅이 넘긴 경로이므로 `~/.claude` 아래 기록만 읽는다
    /// (그 밖은 보호 폴더일 수 있다)
    static func transcriptBranch(atPath path: String?, home: String) -> String? {
        guard let path, TranscriptTail.isInClaudeDirectory(path, home: home) else { return nil }
        return TranscriptTail.lastGitBranch(atPath: path)
    }

    // MARK: - 세션 헬퍼

    private func makeSession(id: String, payload: HookPayload, now: Date) -> AgentSession {
        let cwd = payload.string("cwd") ?? ""
        var session = AgentSession(
            id: id,
            cwd: cwd,
            projectName: TextUtils.projectName(forCwd: cwd),
            transcriptPath: payload.string("transcript_path"),
            startedAt: now,
            lastEventAt: now
        )
        if !cwd.isEmpty { refreshBranch(&session, payload: payload) }
        return session
    }

    private func applyCommonFields(
        _ session: inout AgentSession,
        payload: HookPayload,
        environment: [String: String],
        now: Date
    ) {
        session.lastEventAt = now
        if let path = payload.string("transcript_path") { session.transcriptPath = path }
        if let cwd = payload.string("cwd"), cwd != session.cwd {
            // 프로젝트명은 처음 알게 된 cwd 기준 (Claude 가 하위 폴더로 cd 해도 유지, SessionStart 에서 갱신)
            let hadCwd = !session.cwd.isEmpty
            session.cwd = cwd
            if !hadCwd {
                session.projectName = TextUtils.projectName(forCwd: cwd)
                refreshBranch(&session, payload: payload)
            }
        }
        if let mode = payload.string("permission_mode") { session.permissionMode = mode }
        if let model = payload.string("model")
            ?? TextUtils.nonEmpty(payload["model"]?["id"]?.stringValue)
            ?? TextUtils.nonEmpty(payload["model"]?["display_name"]?.stringValue) {
            session.model = model
        }
        let terminal = TerminalContext(environment: environment)
        if terminal != TerminalContext() { session.terminal = terminal }
    }

    /// 타임라인에 추가. 같은 ID 가 이미 있으면 교체하고 false
    @discardableResult
    private func appendActivity(_ session: inout AgentSession, _ item: ActivityItem) -> Bool {
        if let index = session.activities.lastIndex(where: { $0.id == item.id }) {
            session.activities[index] = item
            return false
        }
        session.activities.append(item)
        return true
    }

    /// PostToolUse(Failure) 에 해당하는 활동 위치. 없으면(PreToolUse 를 놓침) 새로 만든다.
    private func toolActivityIndex(
        _ session: inout AgentSession,
        payload: HookPayload,
        toolName: String,
        agentID: String?,
        now: Date
    ) -> Int {
        let toolUseID = payload.string("tool_use_id")
        if let toolUseID, let index = session.activities.lastIndex(where: { $0.id == toolUseID }) {
            return index
        }
        session.activities.append(Self.toolActivity(
            id: toolUseID, toolName: toolName, toolInput: payload["tool_input"], cwd: session.cwd, agentID: agentID, at: now
        ))
        session.turn.toolCount += 1
        return session.activities.count - 1
    }

    /// 실행 중인 툴 활동 (툴 이름 · 입력을 요약한 제목 · 아이콘). `tool_use_id` 가 없으면 새 ID 를 붙인다
    private static func toolActivity(
        id: String?, toolName: String, toolInput: JSONValue?, cwd: String, agentID: String?, at date: Date
    ) -> ActivityItem {
        let summary = ToolSummarizer.summarize(toolName: toolName, toolInput: toolInput, cwd: cwd)
        return ActivityItem(
            id: id ?? UUID().uuidString,
            kind: .tool,
            toolName: toolName,
            title: summary.title,
            detail: summary.detail,
            symbolName: summary.symbolName,
            label: summary.label,
            status: .running,
            startedAt: date,
            agentID: agentID
        )
    }

    /// 툴이 끝난 뒤: 아직 실행 중인 다른 툴(병렬 · 서브에이전트)이 있으면 그것을 현재 활동으로 툴 실행, 없으면 생각 중
    private func settleAfterTool(_ session: inout AgentSession) {
        let turnStart = session.turnStartedAt ?? .distantPast
        let running = session.activities.last {
            ($0.kind == .tool || $0.kind == .subagent) && $0.status == .running && $0.startedAt >= turnStart
        }
        resumeTurn(&session, phase: running == nil ? .thinking : .runningTool, activity: running)
    }

    /// 실행 중으로 남은 활동을 닫는다. 메인 턴이 끝나도 계속 도는 서브에이전트(백그라운드 에이전트)의 활동은 그대로 둔다
    /// (`keepingRunningSubagents`, 그 서브에이전트가 끝날 때 SubagentStop 에서 닫는다)
    private func closeRunningActivities(
        _ session: inout AgentSession,
        status: ActivityStatus,
        at date: Date,
        keepingRunningSubagents: Bool = true
    ) {
        for index in session.activities.indices where session.activities[index].status == .running {
            if keepingRunningSubagents, isRunningSubagent(session.activities[index].agentID, in: session.id) { continue }
            session.activities[index].status = status
            session.activities[index].endedAt = date
        }
    }

    private func trimActivities(_ session: inout AgentSession) {
        let overflow = session.activities.count - AgentSession.maxActivities
        if overflow > 0 { session.activities.removeFirst(overflow) }
    }

    /// 세션과 관련 상태를 제거하고, 남아 있던 권한 요청을 돌려준다
    private func removeSession(_ sessionID: String) -> [PermissionRequestInfo] {
        sessions[sessionID] = nil
        streamingTexts[sessionID] = nil
        phaseBeforeCompact[sessionID] = nil
        if waits[sessionID] != nil { waits[sessionID] = nil }
        consentWatches[sessionID] = nil
        runningSubagents[sessionID] = nil
        if manualFocusID == sessionID { manualFocusID = nil }
        if pinnedSessionID == sessionID { pinnedSessionID = nil }
        let requests = pendingPermissions.filter { $0.sessionID == sessionID }
        if !requests.isEmpty { pendingPermissions.removeAll { $0.sessionID == sessionID } }
        return requests
    }

    // MARK: - Claude 앱 확인 카드 추정

    /// 지켜보는 툴 한 건. 이미 알린(`signaled`) 툴이 아직 실행 중이면 그 세션은 입력 대기로 보인다 (`finalize`)
    private struct ConsentWatch {
        /// 지연을 재기 시작한 시각 (PreToolUse, 훅 승인 대기가 끝나면 그 시각으로 미룬다)
        var since: Date
        /// 이만큼 끝나지 않으면 확인 대기로 본다 (`AppConsentHeuristic.delay`)
        var delay: TimeInterval
        var toolName: String
        /// PreToolUse 의 `tool_input` (헬퍼가 payload 를 줄였으면 nil)
        var toolInput: JSONValue?
        /// 이 호출을 묻는 훅 권한 요청 (PermissionRequest 에는 tool_use_id 가 없어 툴 이름 · 입력으로 잇는다)
        var permissionID: UUID?
        /// 이 툴로 `.needsInput` 신호를 이미 보냄
        var signaled = false
    }

    /// 훅 권한 요청을 그 호출의 지켜보기에 잇는다 (거부 · 결과 모름이면 `dropConsentWatch` 로 뺀다).
    /// 같은 이름 · 입력의 실행 중인 호출 중 마지막 것, 입력이 다르면(PreToolUse 훅이 바꿈 등) 이름이 같은 호출이 하나뿐일 때 그것
    private func linkConsentWatch(_ request: PermissionRequestInfo, toolInput: JSONValue?, in session: AgentSession) {
        guard var watches = consentWatches[session.id] else { return }
        let candidates = session.activities.reversed().filter { item in
            item.kind == .tool && item.status == .running
                && watches[item.id].map { $0.permissionID == nil && $0.toolName == request.toolName } == true
        }
        let exact = candidates.first { item in
            guard let input = toolInput, let watched = watches[item.id]?.toolInput else { return true }
            return watched == input
        }
        guard let id = exact?.id ?? (candidates.count == 1 ? candidates[0].id : nil) else { return }
        watches[id]?.permissionID = request.id
        // 훅 승인을 기다리느라 늦어진 것을 앱 확인 대기로 알렸을 수 있다 → 승인 뒤 실행부터 다시 본다
        watches[id]?.signaled = false
        consentWatches[session.id] = watches
    }

    /// 허용된 권한 요청: 그 호출은 이제 실행되므로 계속 지켜본다
    private func unlinkConsentWatch(permissionID: UUID, sessionID: String) {
        guard let watches = consentWatches[sessionID],
              let id = watches.first(where: { $0.value.permissionID == permissionID })?.key
        else { return }
        consentWatches[sessionID]?[id]?.permissionID = nil
    }

    /// 거부됐거나 허용됐는지 모르는 권한 요청: 그 호출은 지켜보지 않는다.
    /// 거부된 툴은 PostToolUse 가 오지 않아 타임라인에서 실행 중으로 남으므로, 그대로 두면 지연으로 보고 잘못 알린다
    private func dropConsentWatch(permissionID: UUID, sessionID: String) {
        guard let watches = consentWatches[sessionID] else { return }
        let kept = watches.filter { $0.value.permissionID != permissionID }
        if kept.count != watches.count {
            consentWatches[sessionID] = kept.isEmpty ? nil : kept
        }
    }

    /// 실행이 끝난(또는 타임라인에서 밀려난) 툴은 지켜보기에서 뺀다
    private func pruneConsentWatches(_ session: AgentSession) {
        guard let watches = consentWatches[session.id] else { return }
        let kept = watches.filter { id, _ in
            session.activities.contains { $0.id == id && $0.kind == .tool && $0.status == .running }
        }
        if kept.count != watches.count {
            consentWatches[session.id] = kept.isEmpty ? nil : kept
        }
    }

    /// 아직 알리지 않은 툴의 지연을 다시 잰다 (훅 승인 대기 중 · 직후)
    private func restartConsentClocks(_ sessionID: String, at date: Date) {
        guard let watches = consentWatches[sessionID] else { return }
        consentWatches[sessionID] = watches.mapValues { watch in
            var watch = watch
            if !watch.signaled { watch.since = date }
            return watch
        }
    }

    /// 앱 확인 카드를 기다리는 것으로 이미 알린 툴 중 아직 실행 중인 마지막 것
    private func consentWaitingActivity(_ session: AgentSession) -> ActivityItem? {
        guard let watches = consentWatches[session.id] else { return nil }
        return session.activities.last { item in
            item.kind == .tool && item.status == .running && watches[item.id]?.signaled == true
        }
    }

    /// 그 툴의 지연이 지나도 끝나지 않은 지켜보는 툴 중 먼저 시작한 것
    private func stalledConsentActivity(_ session: AgentSession, now: Date) -> ActivityItem? {
        guard let watches = consentWatches[session.id] else { return nil }
        return session.activities.first { item in
            item.kind == .tool && item.status == .running
                && watches[item.id].map { now.timeIntervalSince($0.since) >= $0.delay } == true
        }
    }

    // MARK: - 대기

    /// 사용자 답을 기다리는 대기 한 건 (`waits`)
    private struct Wait: Equatable {
        enum Kind: Equatable {
            /// 승인 대기 (권한 요청 · 승인 다이얼로그)
            case permission
            /// 입력 대기 (질문 · 계획 승인 · MCP 입력 요청)
            case input
        }

        enum Source: Equatable {
            /// 훅 프로세스가 노치의 결정을 기다린다 (`pendingPermissions` 의 그 요청)
            case hook(UUID)
            /// 훅 대기 없이 세션 앱(터미널 · Claude 앱)의 Claude Code 다이얼로그를 기다린다
            /// (노치에서 넘긴 · 시간이 지난 요청, permission_prompt 알림, 노치에서 답하지 못하는 질문, MCP 입력 요청 등)
            case sessionApp
        }

        /// 기다리는 서브에이전트 `agent_id` (메인 에이전트면 nil)
        var agentID: String?
        /// 기다리는 툴 호출 (알 때만. 모르면 그 에이전트의 다음 툴 결과로 끝난 것으로 본다)
        var toolUseID: String?
        var kind: Kind
        var source: Source
        /// 노치에서 "터미널로" · "Claude로" 넘긴 질문 · 계획 승인 (그 다이얼로그에 답할 때까지 입력 대기 카드를 다시 띄우지 않는다)
        var handedOff = false
    }

    private func hasPending(_ sessionID: String) -> Bool {
        pendingPermissions.contains { $0.sessionID == sessionID }
    }

    /// 훅 대기 요청을 대기열과 그 세션의 대기 목록에 함께 넣는다
    private func addPending(_ request: PermissionRequestInfo, agentID: String?) {
        pendingPermissions.append(request)
        waits[request.sessionID, default: []].append(Wait(
            agentID: agentID, toolUseID: request.toolUseID,
            kind: request.isInteraction ? .input : .permission, source: .hook(request.id)
        ))
    }

    /// 훅 대기 요청 하나를 대기열과 대기 목록에서 함께 뺀다 (요청한 서브에이전트도 돌려준다, 메인이면 nil)
    private func removePending(_ id: UUID) -> (info: PermissionRequestInfo, agentID: String?)? {
        guard let index = pendingPermissions.firstIndex(where: { $0.id == id }) else { return nil }
        let info = pendingPermissions.remove(at: index)
        var list = waits[info.sessionID] ?? []
        let agentID = list.firstIndex { $0.source == .hook(id) }.flatMap { list.remove(at: $0).agentID }
        waits[info.sessionID] = list.isEmpty ? nil : list
        return (info, agentID)
    }

    /// 세션 앱 다이얼로그 대기를 넣는다. 같은 에이전트의 같은 호출(한쪽이 호출을 모르는 경우 포함) 대기가 이미 있으면
    /// 합친다 (예: 넘긴 질문의 PermissionRequest · 같은 다이얼로그의 알림). 종류는 나중 것을 따른다 (승인 대기가 되면 넘김 표시는 푼다)
    private func addSessionAppWait(
        _ sessionID: String, agentID: String?, toolUseID: String?, kind: Wait.Kind, handedOff: Bool = false
    ) {
        var list = waits[sessionID] ?? []
        if let index = list.firstIndex(where: { wait in
            wait.source == .sessionApp && wait.agentID == agentID
                && (wait.toolUseID == nil || toolUseID == nil || wait.toolUseID == toolUseID)
        }) {
            list[index].kind = kind
            if list[index].toolUseID == nil { list[index].toolUseID = toolUseID }
            if handedOff || kind == .permission { list[index].handedOff = handedOff }
        } else {
            list.append(Wait(agentID: agentID, toolUseID: toolUseID, kind: kind, source: .sessionApp, handedOff: handedOff))
        }
        waits[sessionID] = list
    }

    /// 새 입력 요청이 왔다: 넘긴 질문 표시를 풀어 다시 카드로 알린다
    private func clearHandOff(_ sessionID: String) {
        guard var list = waits[sessionID], list.contains(where: \.handedOff) else { return }
        for index in list.indices { list[index].handedOff = false }
        waits[sessionID] = list
    }

    /// 이벤트로 끝난 것으로 볼 수 있는 대기를 지운다 — 대기가 이벤트로 끝나는 규칙은 여기(`releases`) 하나뿐이다.
    /// 지운 훅 대기 요청은 대기열에서도 꺼내 돌려준다 (부르는 쪽이 훅 프로세스를 결정 없이 풀어 준다)
    private func releaseWaits(
        event: String, sessionID: String, agentID: String?, payload: HookPayload
    ) -> (requests: [PermissionRequestInfo], any: Bool) {
        guard let list = waits[sessionID] else { return ([], false) }
        var releasedRequests: Set<UUID> = []
        var kept: [Wait] = []
        for wait in list {
            let request: PermissionRequestInfo?
            if case let .hook(id) = wait.source {
                request = pendingPermissions.first { $0.id == id }
            } else {
                request = nil
            }
            if Self.releases(wait, request: request, event: event, agentID: agentID, payload: payload) {
                if let request { releasedRequests.insert(request.id) }
            } else {
                kept.append(wait)
            }
        }
        guard kept.count != list.count else { return ([], false) }
        waits[sessionID] = kept.isEmpty ? nil : kept
        let requests = pendingPermissions.filter { releasedRequests.contains($0.id) }
        if !requests.isEmpty { pendingPermissions.removeAll { releasedRequests.contains($0.id) } }
        return (requests, true)
    }

    /// 이 이벤트로 그 대기가 끝났는지. 다른 에이전트(병렬로 도는 서브에이전트 · 메인)의 이벤트로는 끝나지 않는다.
    ///
    /// 훅 대기 요청 (훅이 아직 노치의 결정을 기다린다 = 다른 곳(터미널 · Claude 앱)에서 이미 답했을 때만 끝난다):
    /// - 새 프롬프트 · Stop · StopFailure: 메인 에이전트의 요청만 (서브에이전트(백그라운드 에이전트)는 메인 턴이 끝나도 계속 돌며 답을 기다린다.
    ///   그 요청은 그 서브에이전트의 SubagentStop · 훅 연결 끊김 · 시간 초과로 정리)
    /// - PostToolUse(Failure): 같은 호출이 승인돼 실행(또는 실패)된 경우. PermissionRequest 에는 tool_use_id 가 없어
    ///   같은 에이전트 · 툴 이름 · 입력으로 본다. PreToolUse 는 신호로 쓰지 않는다: 병렬로 도는 형제 호출(Read · Grep · WebFetch 등)일 수 있다
    /// - SubagentStop: 그 서브에이전트의 요청
    ///
    /// 세션 앱 다이얼로그 대기 (끝났다는 이벤트가 따로 오지 않는다):
    /// - 새 프롬프트 · 새 대화(SessionStart) · 인터럽트 · idle_prompt: 열린 다이얼로그가 없다 → 모두
    /// - Stop · StopFailure: 메인 에이전트의 대기만 (백그라운드 서브에이전트는 메인 턴이 끝나도 계속 돌며 기다린다)
    /// - 기다리던 에이전트의 다음 툴 호출, 기다리던 호출의 결과 (호출을 모르면 그 에이전트의 툴 결과), 그 서브에이전트의 종료
    /// - MCP 입력 요청이 끝남: 그 에이전트의 입력 대기
    private static func releases(
        _ wait: Wait, request: PermissionRequestInfo?, event: String, agentID: String?, payload: HookPayload
    ) -> Bool {
        switch wait.source {
        case .hook:
            guard let request else { return true }
            switch event {
            case "UserPromptSubmit", "Stop", "StopFailure":
                return wait.agentID == nil
            case "PostToolUse", "PostToolUseFailure":
                // 헬퍼가 큰 payload 를 줄였으면 입력이 잘렸을 수 있어 비교하지 않는다
                let toolInput = isShrunk(payload) ? nil : payload["tool_input"]
                return wait.agentID == agentID && request.toolName == (payload.string("tool_name") ?? "Tool")
                    && (toolInput == nil || request.toolInput.isNull || request.toolInput == toolInput)
            case "SubagentStop":
                return agentID != nil && wait.agentID == agentID
            default:
                return false
            }
        case .sessionApp:
            switch event {
            case "UserPromptSubmit":
                return true
            case "SessionStart":
                return payload.string("source") != "compact"
            case "Stop", "StopFailure":
                return wait.agentID == nil
            case "PreToolUse":
                return wait.agentID == agentID
            case "PostToolUse", "PostToolUseFailure":
                if payload.bool("is_interrupt") == true { return true }
                guard wait.agentID == agentID else { return false }
                // 같은 에이전트가 병렬로 부른 다른 호출의 결과는 기다리던 호출과 무관
                guard let waited = wait.toolUseID, let toolUseID = payload.string("tool_use_id") else { return true }
                return waited == toolUseID
            case "SubagentStop":
                return agentID != nil && wait.agentID == agentID
            case "Notification":
                switch payload.string("notification_type") {
                case "idle_prompt":
                    return true
                case "elicitation_complete", "elicitation_response":
                    return wait.agentID == agentID && wait.kind == .input
                default:
                    return false
                }
            default:
                return false
            }
        }
    }

    /// 대기를 일으킨 툴 호출 추정: 그 에이전트가 실행 중인 툴(이름을 알면 같은 이름) 중 하나뿐이면 그 호출.
    /// 이름을 모르면(알림) 서브에이전트를 띄운 툴(Agent · Task)은 뺀다 (서브에이전트를 기다리는 중이지 묻는 게 아니다)
    private static func waitingToolUseID(in session: AgentSession, agentID: String?, toolName: String?) -> String? {
        let candidates = session.activities.filter { item in
            guard item.kind == .tool, item.status == .running, item.agentID == agentID else { return false }
            if let toolName { return item.toolName == toolName }
            return !subagentLauncherTools.contains(item.toolName ?? "")
        }
        return candidates.count == 1 ? candidates[0].id : nil
    }

    /// 서브에이전트를 띄우는 툴
    static let subagentLauncherTools: Set<String> = ["Agent", "Task"]

    /// 대기열에서 빠진 요청의 훅 프로세스를 결정 없이(passthrough) 풀어준다
    private func releasePassthrough(_ requests: [PermissionRequestInfo]) {
        guard !requests.isEmpty else { return }
        Self.logger.debug("오래된 권한 요청 \(requests.count, privacy: .public)건 정리")
        for request in requests {
            onPermissionResolved?(request, .passthrough)
        }
    }

    // MARK: - 포커스 · 신호

    private func recomputeFocus() {
        let decision = FocusEngine.decide(
            sessions: Array(sessions.values),
            pendingPermissions: pendingPermissions,
            manualFocusID: manualFocusID,
            pinnedID: pinnedSessionID,
            currentFocusID: focusedSessionID
        )
        let ranked = decision.rankedIDs.compactMap { sessions[$0] }
        if ranked != rankedSessions { rankedSessions = ranked }
        if decision.focusedID != focusedSessionID { focusedSessionID = decision.focusedID }
    }

    private func emit(_ signal: IslandSignal, at date: Date) {
        signalSeq += 1
        latestSignal = SignalEvent(seq: signalSeq, signal: signal, at: date)
    }

    /// notch-hook 의 PayloadShrinker 가 payload 를 줄였는지 (`NotchWire.truncatedMarkerKey`)
    private static func isShrunk(_ payload: HookPayload) -> Bool {
        payload.bool(NotchWire.truncatedMarkerKey) == true
    }

    /// 툴 응답에 Claude Code 가 계산한 diff(비어 있지 않은 structuredPatch · bashEditDiff)가 있는지.
    /// 줄인 payload 에서는 이것만 믿을 수 있다 (헬퍼는 1단계에서 이 둘만 남기고, 2단계부터 버린다)
    private static func hasReportedDiff(_ toolResponse: JSONValue?) -> Bool {
        toolResponse?["structuredPatch"]?.arrayValue?.isEmpty == false || toolResponse?["bashEditDiff"] != nil
    }

    // MARK: - 단계 헬퍼

    /// 툴 진행 이벤트
    private static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure"]

    /// 턴이 진행 중인 단계 (생각 중 · 툴 실행)
    private static func isTurnWork(_ phase: SessionPhase) -> Bool {
        phase == .thinking || phase == .runningTool
    }

    /// 사용자 답을 기다리는 단계 (승인 대기 · 입력 대기)
    private static func isWait(_ phase: SessionPhase) -> Bool {
        phase == .waitingPermission || phase == .waitingInput
    }

    /// 메인 턴이 끝난 세션이 대기에서 풀리면 돌아갈 단계: 아직 확인하지 않은 완료 · 실패면 그 단계, 확인했으면 유휴
    static func settledPhase(_ session: AgentSession) -> SessionPhase {
        guard session.hasUnseenCompletion else { return .idle }
        return session.errorMessage == nil ? .completed : .failed
    }

    /// 그 활동이 아직 실행 중이면 지금 상태로, 끝났으면 nil
    private static func stillRunning(_ item: ActivityItem?, in session: AgentSession) -> ActivityItem? {
        guard let item else { return nil }
        return session.activities.last { $0.id == item.id && $0.status == .running }
    }

    // MARK: - 표시 문자열

    private static func subagentActivityID(_ agentID: String?) -> String {
        agentID.map { "agent:\($0)" } ?? UUID().uuidString
    }

    private static func subagentTitle(_ agentType: String?) -> String {
        agentType.map { "Agent \($0)" } ?? "Agent"
    }

    /// StopFailure `error` 코드 → 짧은 설명
    static func describeError(_ code: String) -> String {
        switch code {
        case "rate_limit": return "사용량 한도 초과"
        case "overloaded": return "서버 과부하"
        case "authentication_failed": return "인증 실패"
        case "billing_error": return "결제 오류"
        case "invalid_request": return "잘못된 요청"
        case "model_not_found": return "모델을 찾을 수 없음"
        case "server_error": return "서버 오류"
        case "max_output_tokens": return "출력 길이 초과"
        case "unknown": return "알 수 없는 오류"
        default: return code
        }
    }
}
