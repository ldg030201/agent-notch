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
/// NOTE: 공개 API 시그니처는 다른 모듈(UI, Services, App)이 의존하는 계약이므로 변경하지 않는다.
@MainActor
@Observable
public final class SessionStore {
    /// session_id → 세션
    public private(set) var sessions: [String: AgentSession] = [:]
    /// 포커스 우선순위 순으로 정렬된 세션 목록 (UI 목록용, 종료된 세션 제외)
    public private(set) var rankedSessions: [AgentSession] = []
    /// 지금 노치가 주로 보여줄 세션
    public private(set) var focusedSessionID: String?
    /// 사용자가 고정한 세션
    public private(set) var pinnedSessionID: String?
    /// 응답 대기 중인 권한 요청 · 질문 · 계획 승인 (오래된 순)
    public private(set) var pendingPermissions: [PermissionRequestInfo] = []
    /// 노치에서 답하지 않고 세션 앱(터미널 · Claude 앱)으로 넘긴 질문 · 계획 승인 (세션 ID → tool_use_id).
    /// 그 다이얼로그에 답할 때까지(입력 대기가 끝나거나 새 입력 요청이 올 때까지) 입력 대기 카드를 다시 띄우지 않는다
    public private(set) var handedOffInputs: [String: String] = [:]
    /// UI 일시 반응용 최신 신호
    public private(set) var latestSignal: SignalEvent?

    /// 권한 요청에 대한 사용자 결정이 나면 호출된다 (SocketServer 가 훅 프로세스에 응답을 전달).
    public var onPermissionResolved: (@MainActor (PermissionRequestInfo, PermissionDecision) -> Void)?

    /// Claude 데스크톱 앱 확인 카드 추정 규칙 (`checkStalledTools()`)
    @ObservationIgnored public var appConsent: AppConsentHeuristic = .default

    private let clock: () -> Date

    /// 사용자가 직접 선택한 세션 (세션이 제거되면 해제)
    @ObservationIgnored private var manualFocusID: String?
    /// 권한 요청 ID → 요청이 발생한 서브에이전트 ID (메인 에이전트면 없음)
    @ObservationIgnored private var pendingAgentIDs: [UUID: String] = [:]
    /// PreCompact 직전 phase (PostCompact 에서 복귀)
    @ObservationIgnored private var phaseBeforeCompact: [String: SessionPhase] = [:]
    /// Claude 앱 확인 카드를 띄울 수 있어 지켜보는 실행 중인 툴 (세션 ID → tool_use_id → 상태)
    @ObservationIgnored private var consentWatches: [String: [String: ConsentWatch]] = [:]
    /// 세션별로 시작을 본(SubagentStart) 서브에이전트 `agent_id`. 턴 끝 목록에서만 아는 작업은 "task:<id>".
    /// `activeSubagents` 는 이 집합의 크기다
    @ObservationIgnored private var runningSubagents: [String: Set<String>] = [:]
    @ObservationIgnored private var signalSeq = 0

    private static let logger = Logger(subsystem: "com.ldg.agent-notch", category: "SessionStore")
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

        // 다른 경로(터미널)에서 이미 답한 권한 요청 정리
        let released = dropStalePendings(event: event, sessionID: sessionID, agentID: agentID, payload: payload)

        let isNew = sessions[sessionID] == nil
        var session = sessions[sessionID] ?? makeSession(id: sessionID, payload: payload, now: now)
        applyCommonFields(&session, payload: payload, environment: envelope.env, now: now)

        // 메인 답변이 끝난 뒤 서브에이전트(백그라운드 에이전트)가 쓰는 툴은 타임라인에만 쌓고 세션 단계 · 지금 활동은 그대로 둔다.
        // 그러지 않으면 백그라운드 툴 호출마다 끝난 세션이 "생각 중" 으로 바뀌었다가 다음 Stop 까지 그대로 남는다
        let backgroundTool = agentID != nil && Self.turnHasEnded(session)
            && (event == "PreToolUse" || event == "PostToolUse" || event == "PostToolUseFailure")
        let phaseBefore = session.phase
        let activityBefore = session.currentActivity

        var signal: IslandSignal?
        var requestID: UUID?
        switch event {
        case "SessionStart":
            signal = handleSessionStart(&session, payload: payload, isNew: isNew)
        case "UserPromptSubmit":
            handleUserPromptSubmit(&session, payload: payload, now: now)
        case "PreToolUse":
            signal = handlePreToolUse(&session, payload: payload, now: now)
            // 헬퍼가 답을 기다리는 질문 · 계획 승인이면 노치에서 답하도록 대기열에 넣는다 (예전 설정의 fire-and-forget 이면 입력 대기 카드만)
            if envelope.expectsReply {
                requestID = queueInteraction(&session, payload: payload, agentID: agentID, now: now)?.id
            }
        case "PostToolUse":
            signal = handlePostToolUse(&session, payload: payload, now: now)
        case "PostToolUseFailure":
            handlePostToolUseFailure(&session, payload: payload, now: now)
        case "PermissionRequest":
            if let toolName = payload.string("tool_name"), Self.userInteractionTools.contains(toolName) {
                // 답 · 계획 승인은 Claude Code 다이얼로그에서만 할 수 있다 (updatedInput 없는 allow 는 무시됨).
                // 대기열에 넣지 않고 nil → 훅에 바로 "결정 없음" 응답, 카드는 입력 대기로 보여준다.
                signal = handleUserInteractionRequest(&session, toolName: toolName, payload: payload)
            } else {
                let info = handlePermissionRequest(&session, payload: payload, agentID: agentID, now: now)
                requestID = info.id
                signal = .permissionRequested(id: info.id, sessionID: sessionID)
                linkConsentWatch(info, toolInput: Self.isShrunk(payload) ? nil : payload["tool_input"], in: session)
                restartConsentClocks(sessionID, at: now)
            }
        case "Notification":
            signal = handleNotification(&session, payload: payload, now: now)
        case "MessageDisplay":
            handleMessageDisplay(&session, payload: payload)
        case "Stop":
            signal = handleStop(&session, payload: payload, now: now)
        case "StopFailure":
            signal = handleStopFailure(&session, payload: payload, now: now)
        case "SubagentStart":
            handleSubagentStart(&session, payload: payload, now: now)
        case "SubagentStop":
            handleSubagentStop(&session, payload: payload, now: now)
        case "PreCompact":
            handlePreCompact(&session, now: now)
        case "PostCompact":
            handlePostCompact(&session, payload: payload, now: now)
        default:
            // 알 수 없는 이벤트: 공통 필드(lastEventAt 등)만 갱신
            break
        }
        // 질문 · 권한처럼 사용자가 봐야 하는 단계로 바뀐 경우는 그대로 둔다
        if backgroundTool, session.phase == .runningTool || session.phase == .thinking {
            session.phase = phaseBefore
            session.currentActivity = activityBefore
        }

        // 끝난 툴은 지켜보기에서 빼고, 이미 확인 대기로 알린 툴이 아직 실행 중이면 입력 대기 유지 (새 신호는 checkStalledTools 에서만).
        // 다른 곳에서 답한 권한 요청의 툴은 실행됐는지 모른다 (거부면 PostToolUse 가 오지 않는다) → 지켜보지 않는다
        for request in released { dropConsentWatch(permissionID: request.id, sessionID: sessionID) }
        if !released.isEmpty { restartConsentClocks(sessionID, at: now) }
        pruneConsentWatches(session)
        _ = applyConsentWait(&session, now: now, allowSignal: false)

        // 다른 에이전트(서브에이전트)의 권한 요청 · 질문이 아직 남아 있으면 승인 · 입력 대기로 표시
        if let waiting = pendingPhase(sessionID), session.phase == .thinking || session.phase == .runningTool {
            session.phase = waiting
        }
        // 넘긴 다이얼로그가 끝났거나(입력 대기가 아님) 새 입력 요청이 왔으면 다시 카드로 알린다
        if handedOffInputs[sessionID] != nil {
            var asksAgain = false
            if case .needsInput? = signal { asksAgain = true }
            if session.phase != .waitingInput || asksAgain { handedOffInputs[sessionID] = nil }
        }
        trimActivities(&session)
        sessions[sessionID] = session

        if let signal { emit(signal, at: now) }
        recomputeFocus()
        releasePassthrough(released)
        return requestID
    }

    // MARK: - 앱을 새로 띄웠을 때 되살리기

    /// 대화 기록으로 되살린 세션을 넣는다 (`TranscriptTail`). 앱을 새로 띄운 사이 이미 돌고 있던 세션을
    /// 다음 훅 이벤트 전에도 보여주려는 것이라 알림(완료 · 미리보기 · 입력 대기 카드)은 띄우지 않는다.
    /// 이미 이벤트로 알게 된 세션은 건드리지 않는다 (이벤트가 더 정확하다)
    public func restore(_ restored: [RestoredSession]) {
        var count = 0
        for item in restored where sessions[item.id] == nil {
            var session = AgentSession(
                id: item.id,
                cwd: item.cwd,
                projectName: TextUtils.projectName(forCwd: item.cwd),
                gitBranch: item.gitBranch ?? Self.lookupBranch(cwd: item.cwd, transcriptPath: nil),
                startedAt: item.lastEventAt,
                lastEventAt: item.lastEventAt,
                // 턴을 본 세션으로 둔다 (끝난 세션이면 백그라운드 서브에이전트 규칙이 적용되게)
                turnStartedAt: item.lastEventAt
            )
            session.terminal = TerminalContext(entrypoint: item.entrypoint)
            switch item.state {
            case let .runningTool(name, input, toolUseID):
                let summary = ToolSummarizer.summarize(toolName: name, toolInput: input, cwd: item.cwd)
                let activity = ActivityItem(
                    id: toolUseID ?? UUID().uuidString,
                    kind: .tool,
                    toolName: name,
                    title: summary.title,
                    detail: summary.detail,
                    symbolName: summary.symbolName,
                    label: summary.label,
                    status: .running,
                    startedAt: item.lastEventAt
                )
                appendActivity(&session, activity)
                session.currentActivity = activity
                session.phase = Self.userInteractionTools.contains(name) ? .waitingInput : .runningTool
            case .thinking:
                session.phase = .thinking
            case .finished:
                session.phase = .completed
            }
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
        guard let index = pendingPermissions.firstIndex(where: { $0.id == id }) else { return }
        let info = pendingPermissions.remove(at: index)
        let decision = PermissionReplyBuilder.effectiveDecision(for: info, decision: decision)
        pendingAgentIDs[id] = nil
        // 거부하면 툴이 실행되지 않아 PostToolUse 가 오지 않을 수 있고, 터미널로 넘기면 결과를 모른다 → 그 호출은 지켜보지 않는다.
        // 허용이면 승인 대기 동안 툴이 실행되지 않았으니 앱 확인 카드 지연은 지금부터 잰다
        switch decision {
        case .allow, .allowAlways, .answer: unlinkConsentWatch(permissionID: id, sessionID: info.sessionID)
        case .deny, .passthrough: dropConsentWatch(permissionID: id, sessionID: info.sessionID)
        }
        restartConsentClocks(info.sessionID, at: clock())

        // 권한 요청은 승인 대기, 질문 · 계획 승인은 입력 대기에서 풀린다
        let waiting: SessionPhase = info.isInteraction ? .waitingInput : .waitingPermission
        if var session = sessions[info.sessionID], session.phase == waiting, !hasPending(info.sessionID) {
            switch decision {
            case .allow, .allowAlways, .answer:
                session.phase = .runningTool
            case .deny:
                session.phase = .thinking
            case .passthrough:
                // 터미널(세션 앱)에서 직접 답해야 하므로 대기 유지
                break
            }
            sessions[info.sessionID] = session
        }
        recomputeFocus()
        onPermissionResolved?(info, decision)
    }

    /// 카드의 "터미널로" · "Claude로": 노치에서 정하지 않고 결정 없이 풀어 세션 앱의 다이얼로그로 넘긴다.
    /// 질문 · 계획 승인이면 그 다이얼로그에 답할 때까지 같은 호출로 입력 대기 카드를 다시 띄우지 않게 기억한다
    /// (이어서 오는 같은 툴의 PermissionRequest · permission_prompt 알림 포함). 권한 요청은 `.passthrough` 와 같다
    public func handOff(id: UUID) {
        guard let info = pendingPermissions.first(where: { $0.id == id }) else { return }
        if info.isInteraction { handedOffInputs[info.sessionID] = info.toolUseID ?? "" }
        resolvePermission(id: id, decision: .passthrough)
    }

    /// 이 세션의 질문 · 계획 승인을 사용자가 세션 앱으로 넘겼고 아직 그 다이얼로그를 기다리는 중인지
    public func isInputHandedOff(_ sessionID: String) -> Bool {
        handedOffInputs[sessionID] != nil
    }

    /// 훅 연결이 응답 전에 끊김 → 대기열에서만 제거 (`onPermissionResolved` 호출 안 함).
    /// 질문 · 계획 승인이면 Claude Code 가 기다리던 훅을 끊은 것(Esc · 중단 · 종료)이라 다이얼로그도 뜨지 않는다 →
    /// 입력 대기를 풀고(쉬는 중) 그 툴을 실패로 닫는다 (카드도, 이어지는 입력 대기 카드도 남지 않게)
    public func cancelPermission(id: UUID) {
        guard let info = takePending(id) else { return }
        if info.isInteraction, var session = sessions[info.sessionID], session.phase == .waitingInput, !hasPending(info.sessionID) {
            let now = clock()
            if let toolUseID = info.toolUseID {
                for index in session.activities.indices
                where session.activities[index].id == toolUseID && session.activities[index].status == .running {
                    session.activities[index].status = .failed
                    session.activities[index].endedAt = now
                }
                if session.currentActivity?.id == toolUseID { session.currentActivity = nil }
            }
            session.phase = .idle
            sessions[info.sessionID] = session
        }
        recomputeFocus()
    }

    /// 노치에서 기다리는 시간(`permissionTimeout`)이 지나 결정 없이 풀어 줌 (SocketServer 가 이미 "결정 없음" 으로 응답함).
    /// 권한 요청은 `cancelPermission` 과 같다. 질문 · 계획 승인은 이어서 Claude Code 다이얼로그가 뜨므로 입력 대기를 그대로 둔다
    /// (그 다이얼로그로 안내하는 입력 대기 카드)
    public func expirePermission(id: UUID) {
        guard takePending(id) != nil else { return }
        recomputeFocus()
    }

    /// 대기열에서 하나를 꺼낸다 (결정 없이 끝난 요청: 허용됐는지 모르므로 그 호출은 앱 확인 카드 추정에서 뺀다)
    private func takePending(_ id: UUID) -> PermissionRequestInfo? {
        guard let index = pendingPermissions.firstIndex(where: { $0.id == id }) else { return nil }
        let info = pendingPermissions.remove(at: index)
        pendingAgentIDs[id] = nil
        // 다른 곳(Claude 앱 · 터미널)에서 먼저 답했거나 시간이 지났다: 허용됐는지 모른다 → 그 호출은 지켜보지 않는다
        dropConsentWatch(permissionID: id, sessionID: info.sessionID)
        restartConsentClocks(info.sessionID, at: clock())
        return info
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

    /// 완료 알림 확인 처리
    public func markSeen(sessionID: String) {
        guard var session = sessions[sessionID] else { return }
        session.hasUnseenCompletion = false
        if session.phase == .completed || session.phase == .failed {
            session.phase = .idle
        }
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
    /// - `appConsent` 목록의 툴이 PostToolUse 없이 `appConsent.delay` 이상 실행 중 (훅 승인 대기 시간은 빼고 잰다)
    /// - 훅 권한 요청 대기가 없음
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
            pruneConsentWatches(session)
            let signal = applyConsentWait(&session, now: now, allowSignal: true)
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
            refreshBranch(&session)
        }
        session.phase = .idle
        session.currentActivity = nil
        phaseBeforeCompact[session.id] = nil
        return .sessionStarted(sessionID: session.id)
    }

    private func handleUserPromptSubmit(_ session: inout AgentSession, payload: HookPayload, now: Date) {
        let prompt = payload["prompt"]?.stringValue.map(TextUtils.cleanPrompt)
        // 이전 턴에서 끝나지 않은 활동(인터럽트 등)은 실패로 닫는다
        closeRunningActivities(&session, status: .failed, at: now)
        session.phase = .thinking
        session.turnStartedAt = now
        session.turn = TurnSummary(startedAt: now)
        session.lastPrompt = TextUtils.nonEmpty(prompt)
        session.streamingText = ""
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
            refreshBranch(&session)
        }
    }

    private func handlePreToolUse(_ session: inout AgentSession, payload: HookPayload, now: Date) -> IslandSignal? {
        let toolName = payload.string("tool_name") ?? "Tool"
        let toolInput = payload["tool_input"]
        let summary = ToolSummarizer.summarize(toolName: toolName, toolInput: toolInput, cwd: session.cwd)
        let item = ActivityItem(
            id: payload.string("tool_use_id") ?? UUID().uuidString,
            kind: .tool,
            toolName: toolName,
            title: summary.title,
            detail: summary.detail,
            symbolName: summary.symbolName,
            label: summary.label,
            status: .running,
            startedAt: now
        )
        if appendActivity(&session, item) {
            session.turn.toolCount += 1
        }
        session.currentActivity = item
        if session.terminal.isClaudeDesktopApp,
           appConsent.watches(toolName: toolName, toolInput: toolInput),
           consentWatches[session.id]?[item.id] == nil {
            consentWatches[session.id, default: [:]][item.id] = ConsentWatch(
                since: now, toolName: toolName, toolInput: Self.isShrunk(payload) ? nil : toolInput
            )
        }

        if Self.userInteractionTools.contains(toolName) {
            session.phase = .waitingInput
            return .needsInput(sessionID: session.id, message: Self.inputMessage(toolName: toolName, toolInput: toolInput))
        }
        session.phase = .runningTool
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
        pendingPermissions.append(info)
        if let agentID { pendingAgentIDs[info.id] = agentID }
        if handedOffInputs[session.id] != nil { handedOffInputs[session.id] = nil }
        session.phase = .waitingInput
        return info
    }

    private static func inputMessage(toolName: String, toolInput: JSONValue?) -> String {
        if toolName == "ExitPlanMode" { return "계획 승인 필요" }
        return ToolSummarizer.firstQuestion(in: toolInput) ?? "질문에 답변 필요"
    }

    /// AskUserQuestion · ExitPlanMode 의 PermissionRequest: 입력 대기로만 표시 (PreToolUse 를 놓쳤을 때만 신호)
    private func handleUserInteractionRequest(
        _ session: inout AgentSession,
        toolName: String,
        payload: HookPayload
    ) -> IslandSignal? {
        guard session.phase != .waitingInput else { return nil }
        session.phase = .waitingInput
        return .needsInput(sessionID: session.id, message: Self.inputMessage(toolName: toolName, toolInput: payload["tool_input"]))
    }

    private func handlePostToolUse(_ session: inout AgentSession, payload: HookPayload, now: Date) -> IslandSignal? {
        let toolName = payload.string("tool_name") ?? "Tool"
        let outcome = DiffEngine.outcome(
            toolName: toolName,
            toolInput: payload["tool_input"],
            toolResponse: payload["tool_response"]
        )
        let index = toolActivityIndex(&session, payload: payload, toolName: toolName, now: now)
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

    private func handlePostToolUseFailure(_ session: inout AgentSession, payload: HookPayload, now: Date) {
        let toolName = payload.string("tool_name") ?? "Tool"
        let index = toolActivityIndex(&session, payload: payload, toolName: toolName, now: now)
        session.activities[index].status = .failed
        session.activities[index].endedAt = now

        if payload.bool("is_interrupt") == true {
            // 사용자 인터럽트: 에러가 아니라 턴 중단 (Stop 이벤트가 오지 않음)
            closeRunningActivities(&session, status: .failed, at: now)
            session.currentActivity = nil
            session.phase = .idle
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
        pendingPermissions.append(info)
        if let agentID { pendingAgentIDs[info.id] = agentID }
        session.phase = .waitingPermission
        return info
    }

    private func handleNotification(_ session: inout AgentSession, payload: HookPayload, now: Date) -> IslandSignal? {
        let message = payload.string("message")
        if let message { session.lastNotification = message }

        switch payload.string("notification_type") {
        case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
            session.phase = .waitingInput
            return .needsInput(sessionID: session.id, message: message ?? "입력 필요")
        case "permission_prompt":
            // 훅 대기 요청이 있으면 PermissionRequest 로 이미 표시 중
            guard !hasPending(session.id) else { return nil }
            // 노치에서 "터미널로" 넘긴 질문 · 계획 승인 다이얼로그 알림: 사용자는 이미 그쪽으로 갔다
            if session.phase == .waitingInput, handedOffInputs[session.id] != nil { return nil }
            session.phase = .waitingPermission
            return .needsInput(sessionID: session.id, message: message ?? "승인 필요")
        case "elicitation_complete", "elicitation_response":
            if session.phase == .waitingInput { session.phase = .thinking }
            return nil
        case "idle_prompt":
            // 프롬프트 입력 대기 알림 = 턴이 끝났고 열린 다이얼로그도 없다.
            // - 아직 작업 중으로 보이면 종료 이벤트를 놓친 것 (인터럽트 등)
            // - 훅 대기 없는 승인 대기 · 입력 대기는 터미널에서 거부/Esc 로 끝난 것 (그때는 아무 이벤트도 오지 않는다)
            let endedWait = (session.phase == .waitingPermission || session.phase == .waitingInput) && !hasPending(session.id)
            if session.phase.isWorking || endedWait {
                for index in session.activities.indices
                where session.activities[index].kind == .tool && session.activities[index].status == .running {
                    session.activities[index].status = .failed
                    session.activities[index].endedAt = now
                }
                session.phase = .idle
                session.currentActivity = nil
            }
            return nil
        default:
            return nil
        }
    }

    private func handleMessageDisplay(_ session: inout AgentSession, payload: HookPayload) {
        guard let delta = payload["delta"]?.stringValue, !delta.isEmpty else { return }
        var text = session.streamingText
        // 새 메시지의 첫 조각이면 이전 메시지와 줄바꿈으로 구분
        if payload.int("index") == 0, !text.isEmpty, !text.hasSuffix("\n") {
            text += "\n"
        }
        text += delta
        if text.count > AgentSession.maxStreamingCharacters {
            text = String(text.suffix(AgentSession.maxStreamingCharacters))
        }
        session.streamingText = text
    }

    private func handleStop(_ session: inout AgentSession, payload: HookPayload, now: Date) -> IslandSignal {
        if let message = payload.string("last_assistant_message") {
            session.lastAssistantMessage = String(message.suffix(Self.maxAssistantMessageCharacters))
        }
        closeRunningActivities(&session, status: .succeeded, at: now)
        reconcileBackgroundTasks(&session, payload: payload, includesSubagents: true)
        session.currentActivity = nil
        session.phase = .completed
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
        session.phase = .failed
        session.hasUnseenCompletion = true
        phaseBeforeCompact[session.id] = nil
        return .failed(sessionID: session.id)
    }

    /// 메인 답변이 끝난 걸 본 세션인지 (이때 오는 서브에이전트 툴 호출은 백그라운드 작업).
    /// 완료 · 실패, 또는 턴을 본 뒤 유휴가 된 세션만. 앱을 새로 띄운 뒤 처음 보는 세션(유휴 · 턴 모름)은 아니다:
    /// 그 세션의 서브에이전트 툴 호출은 메인이 서브에이전트를 기다리는 중일 수 있어 예전처럼 작업 중으로 보여준다
    static func turnHasEnded(_ session: AgentSession) -> Bool {
        switch session.phase {
        case .completed, .failed: return true
        case .idle: return session.turnStartedAt != nil
        default: return false
        }
    }

    private func handleSubagentStart(_ session: inout AgentSession, payload: HookPayload, now: Date) {
        let agentID = payload.string("agent_id") ?? "unknown:\(UUID().uuidString)"
        runningSubagents[session.id, default: []].insert(agentID)
        session.activeSubagents = runningSubagents[session.id]?.count ?? 0
        appendActivity(&session, ActivityItem(
            id: Self.subagentActivityID(payload.string("agent_id")),
            kind: .subagent,
            title: Self.subagentTitle(payload.string("agent_type")),
            symbolName: "person.2",
            status: .running,
            startedAt: now
        ))
    }

    /// 시작을 본 서브에이전트만 끝낸다. 시작 없이 오는 종료(Claude 앱이 턴이 끝날 때마다 내부에서 돌리는 보조 작업 등)는 무시한다:
    /// 세면 실제로 도는 서브에이전트 수가 줄고, 타임라인에 가짜 "Agent" 가 붙고, 그 이벤트의 작업 목록으로 셸 수까지 지워진다
    private func handleSubagentStop(_ session: inout AgentSession, payload: HookPayload, now: Date) {
        guard let agentID = payload.string("agent_id"), runningSubagents[session.id]?.remove(agentID) != nil else {
            Self.logger.debug("시작을 못 본 SubagentStop 무시")
            return
        }
        if runningSubagents[session.id]?.isEmpty == true { runningSubagents[session.id] = nil }
        session.activeSubagents = runningSubagents[session.id]?.count ?? 0
        let id = Self.subagentActivityID(agentID)
        if let index = session.activities.lastIndex(where: { $0.id == id }) {
            session.activities[index].status = .succeeded
            session.activities[index].endedAt = now
        }
        if session.currentActivity?.id == id { session.currentActivity = nil }
        reconcileBackgroundTasks(&session, payload: payload, includesSubagents: false)
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
        runningSubagents[session.id] = next.isEmpty ? nil : next
        session.activeSubagents = next.count
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
        if session.phase != .compacting {
            phaseBeforeCompact[session.id] = session.phase
        }
        session.phase = .compacting
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
        guard session.phase == .compacting else { return }
        // 직전 상태를 모르면: 수동 압축은 입력 대기, 자동 압축은 턴 진행 중
        session.phase = previous ?? (payload.string("trigger") == "manual" ? .idle : .thinking)
    }

    // MARK: - 세션 헬퍼

    // MARK: - 브랜치

    /// 세션 브랜치를 다시 찾는다. 보호 폴더 프로젝트에서 대화 기록에 아직 브랜치가 없으면 알던 값을 그대로 둔다
    private func refreshBranch(_ session: inout AgentSession) {
        let branch = Self.lookupBranch(cwd: session.cwd, transcriptPath: session.transcriptPath)
        if branch != nil || !ProtectedLocations.contains(session.cwd) {
            session.gitBranch = branch
        }
    }

    /// 작업 폴더의 git 브랜치.
    /// - 보통은 `.git` 을 직접 읽는다 (`GitInfo`, 정확하고 빠름).
    /// - 작업 폴더가 macOS 보호 폴더(문서 · 데스크탑 · 다운로드 · iCloud 등, `ProtectedLocations`)면 읽지 않는다:
    ///   읽기만 해도 "AgentNotch 가 '문서' 폴더에 접근하려고 합니다" 창이 뜨고, ad-hoc 서명이라 빌드 · 업데이트마다 다시 묻는다.
    ///   대신 Claude Code 대화 기록(`~/.claude`) 끝부분에 적힌 `gitBranch` 를 쓴다
    static func lookupBranch(cwd: String, transcriptPath: String?, home: String? = nil) -> String? {
        guard !cwd.isEmpty else { return nil }
        let home = home ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard ProtectedLocations.contains(cwd, home: home) else { return GitInfo.branch(forDirectory: cwd) }
        guard let transcriptPath, !ProtectedLocations.contains(transcriptPath, home: home) else { return nil }
        return TranscriptTail.lastGitBranch(atPath: transcriptPath)
    }

    private func makeSession(id: String, payload: HookPayload, now: Date) -> AgentSession {
        let cwd = payload.string("cwd") ?? ""
        return AgentSession(
            id: id,
            cwd: cwd,
            projectName: TextUtils.projectName(forCwd: cwd),
            gitBranch: Self.lookupBranch(cwd: cwd, transcriptPath: payload.string("transcript_path")),
            startedAt: now,
            lastEventAt: now
        )
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
                refreshBranch(&session)
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
        now: Date
    ) -> Int {
        let toolUseID = payload.string("tool_use_id")
        if let toolUseID, let index = session.activities.lastIndex(where: { $0.id == toolUseID }) {
            return index
        }
        let summary = ToolSummarizer.summarize(toolName: toolName, toolInput: payload["tool_input"], cwd: session.cwd)
        session.activities.append(ActivityItem(
            id: toolUseID ?? UUID().uuidString,
            kind: .tool,
            toolName: toolName,
            title: summary.title,
            detail: summary.detail,
            symbolName: summary.symbolName,
            label: summary.label,
            status: .running,
            startedAt: now
        ))
        session.turn.toolCount += 1
        return session.activities.count - 1
    }

    /// 툴이 끝난 뒤: 아직 실행 중인 다른 툴(병렬 · 서브에이전트)이 있으면 그것을 현재 활동으로, 없으면 thinking
    private func settleAfterTool(_ session: inout AgentSession) {
        let turnStart = session.turnStartedAt ?? .distantPast
        if let running = session.activities.last(where: {
            ($0.kind == .tool || $0.kind == .subagent) && $0.status == .running && $0.startedAt >= turnStart
        }) {
            session.currentActivity = running
            session.phase = .runningTool
        } else {
            session.currentActivity = nil
            session.phase = .thinking
        }
    }

    private func closeRunningActivities(_ session: inout AgentSession, status: ActivityStatus, at date: Date) {
        for index in session.activities.indices where session.activities[index].status == .running {
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
        phaseBeforeCompact[sessionID] = nil
        if handedOffInputs[sessionID] != nil { handedOffInputs[sessionID] = nil }
        consentWatches[sessionID] = nil
        runningSubagents[sessionID] = nil
        if manualFocusID == sessionID { manualFocusID = nil }
        if pinnedSessionID == sessionID { pinnedSessionID = nil }
        return takePendings { request, _ in request.sessionID == sessionID }
    }

    // MARK: - Claude 앱 확인 카드 추정

    /// 지켜보는 툴 한 건
    private struct ConsentWatch {
        /// 지연을 재기 시작한 시각 (PreToolUse, 훅 승인 대기가 끝나면 그 시각으로 미룬다)
        var since: Date
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

    /// 확인 대기로 볼 툴이 있으면 입력 대기로 바꾼다.
    /// 이미 알린 툴이 아직 실행 중이면 조용히 유지하고, `allowSignal` 일 때만 새로 멈춘 툴을 찾아 신호를 돌려준다.
    private func applyConsentWait(_ session: inout AgentSession, now: Date, allowSignal: Bool) -> IslandSignal? {
        guard var watches = consentWatches[session.id], !watches.isEmpty else { return nil }
        if hasPending(session.id) {
            // 훅 권한 카드가 우선. 승인 대기 동안은 툴이 실행되지 않으므로 지연도 세지 않는다
            restartConsentClocks(session.id, at: now)
            return nil
        }
        // 승인 대기(터미널 다이얼로그) · 질문 · 압축 등 다른 대기는 건드리지 않는다
        guard session.phase == .runningTool || session.phase == .thinking else { return nil }

        let running = session.activities.filter { $0.kind == .tool && $0.status == .running && watches[$0.id] != nil }
        if let waiting = running.last(where: { watches[$0.id]?.signaled == true }) {
            session.phase = .waitingInput
            session.currentActivity = waiting
            return nil
        }
        // 새로 알리는 것은 툴 실행 중일 때만 (thinking 이면 Claude Code 는 실행 중인 툴이 없다고 본다. 예: 거부 직후)
        guard allowSignal, session.phase == .runningTool,
              let stalled = running.first(where: { item in
                  watches[item.id].map { now.timeIntervalSince($0.since) >= appConsent.delay } == true
              })
        else { return nil }

        watches[stalled.id]?.signaled = true
        consentWatches[session.id] = watches
        session.phase = .waitingInput
        session.currentActivity = stalled
        return .needsInput(sessionID: session.id, message: AppConsentHeuristic.message(toolTitle: stalled.title))
    }

    // MARK: - 권한 대기열 헬퍼

    private func hasPending(_ sessionID: String) -> Bool {
        pendingPermissions.contains { $0.sessionID == sessionID }
    }

    /// 훅 대기 요청이 남은 세션의 대기 상태: 권한 요청이 하나라도 있으면 승인 대기, 질문 · 계획 승인만 있으면 입력 대기
    private func pendingPhase(_ sessionID: String) -> SessionPhase? {
        var phase: SessionPhase?
        for request in pendingPermissions where request.sessionID == sessionID {
            if !request.isInteraction { return .waitingPermission }
            phase = .waitingInput
        }
        return phase
    }

    /// 조건에 맞는 권한 요청을 대기열에서 꺼낸다 (agentID: 요청이 발생한 서브에이전트, 메인이면 nil)
    private func takePendings(where predicate: (PermissionRequestInfo, String?) -> Bool) -> [PermissionRequestInfo] {
        var taken: [PermissionRequestInfo] = []
        var kept: [PermissionRequestInfo] = []
        for request in pendingPermissions {
            if predicate(request, pendingAgentIDs[request.id]) {
                taken.append(request)
            } else {
                kept.append(request)
            }
        }
        guard !taken.isEmpty else { return [] }
        pendingPermissions = kept
        for request in taken { pendingAgentIDs[request.id] = nil }
        return taken
    }

    /// 이 이벤트가 왔다는 건 대기 중인 권한 요청이 이미 다른 곳(터미널)에서 처리됐다는 뜻
    private func dropStalePendings(
        event: String,
        sessionID: String,
        agentID: String?,
        payload: HookPayload
    ) -> [PermissionRequestInfo] {
        switch event {
        case "UserPromptSubmit", "Stop", "StopFailure":
            return takePendings { request, _ in request.sessionID == sessionID }
        case "PostToolUse", "PostToolUseFailure":
            // 같은 호출이 터미널에서 승인돼 실행(또는 실패)된 경우에만 정리.
            // PermissionRequest 에는 tool_use_id 가 없어 같은 에이전트 · 툴 이름 · 입력으로 같은 호출인지 본다.
            // PreToolUse 는 신호로 쓰지 않는다: 병렬로 도는 형제 호출(Read · Grep · WebFetch 등)일 수 있다.
            let toolName = payload.string("tool_name") ?? "Tool"
            // 헬퍼가 큰 payload 를 줄였으면 입력이 잘렸을 수 있어 비교하지 않는다
            let toolInput = Self.isShrunk(payload) ? nil : payload["tool_input"]
            return takePendings { request, requestAgentID in
                request.sessionID == sessionID && requestAgentID == agentID
                    && request.toolName == toolName
                    && (toolInput == nil || request.toolInput.isNull || request.toolInput == toolInput)
            }
        case "SubagentStop":
            guard let agentID else { return [] }
            return takePendings { request, requestAgentID in
                request.sessionID == sessionID && requestAgentID == agentID
            }
        default:
            return []
        }
    }

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

    /// notch-hook 의 PayloadShrinker 가 payload 를 줄였다는 표시 (같은 키를 쓴다)
    static let shrunkMarkerKey = "_agent_notch_truncated"

    private static func isShrunk(_ payload: HookPayload) -> Bool {
        payload.bool(shrunkMarkerKey) == true
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
