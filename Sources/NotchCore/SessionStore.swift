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
    /// 응답 대기 중인 권한 요청 (오래된 순)
    public private(set) var pendingPermissions: [PermissionRequestInfo] = []
    /// UI 일시 반응용 최신 신호
    public private(set) var latestSignal: SignalEvent?

    /// 권한 요청에 대한 사용자 결정이 나면 호출된다 (SocketServer 가 훅 프로세스에 응답을 전달).
    public var onPermissionResolved: (@MainActor (PermissionRequestInfo, PermissionDecision) -> Void)?

    private let clock: () -> Date

    /// 사용자가 직접 선택한 세션 (세션이 제거되면 해제)
    @ObservationIgnored private var manualFocusID: String?
    /// 권한 요청 ID → 요청이 발생한 서브에이전트 ID (메인 에이전트면 없음)
    @ObservationIgnored private var pendingAgentIDs: [UUID: String] = [:]
    /// PreCompact 직전 phase (PostCompact 에서 복귀)
    @ObservationIgnored private var phaseBeforeCompact: [String: SessionPhase] = [:]
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

    /// 훅 이벤트를 반영한다. 응답을 기다려야 하는 이벤트(PermissionRequest)면 권한 요청 ID 를 반환한다.
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

        var signal: IslandSignal?
        var requestID: UUID?
        switch event {
        case "SessionStart":
            signal = handleSessionStart(&session, payload: payload, isNew: isNew)
        case "UserPromptSubmit":
            handleUserPromptSubmit(&session, payload: payload, now: now)
        case "PreToolUse":
            signal = handlePreToolUse(&session, payload: payload, now: now)
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

        // 다른 에이전트(서브에이전트)의 권한 요청이 아직 남아 있으면 승인 대기로 표시
        if hasPending(sessionID), session.phase == .thinking || session.phase == .runningTool {
            session.phase = .waitingPermission
        }
        trimActivities(&session)
        sessions[sessionID] = session

        if let signal { emit(signal, at: now) }
        recomputeFocus()
        releasePassthrough(released)
        return requestID
    }

    // MARK: - 사용자 동작

    /// 사용자가 권한 요청에 대해 결정함 → 대기열에서 제거하고 `onPermissionResolved` 호출
    public func resolvePermission(id: UUID, decision: PermissionDecision) {
        guard let index = pendingPermissions.firstIndex(where: { $0.id == id }) else { return }
        let info = pendingPermissions.remove(at: index)
        pendingAgentIDs[id] = nil

        if var session = sessions[info.sessionID], session.phase == .waitingPermission, !hasPending(info.sessionID) {
            switch decision {
            case .allow, .allowAlways:
                session.phase = .runningTool
            case .deny:
                session.phase = .thinking
            case .passthrough:
                // 터미널에서 직접 답해야 하므로 승인 대기 유지
                break
            }
            sessions[info.sessionID] = session
        }
        recomputeFocus()
        onPermissionResolved?(info, decision)
    }

    /// 훅 연결이 끊기거나 타임아웃 → 대기열에서만 제거 (`onPermissionResolved` 호출 안 함)
    public func cancelPermission(id: UUID) {
        guard let index = pendingPermissions.firstIndex(where: { $0.id == id }) else { return }
        pendingPermissions.remove(at: index)
        pendingAgentIDs[id] = nil
        recomputeFocus()
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

    // MARK: - 이벤트별 처리

    private func handleSessionStart(_ session: inout AgentSession, payload: HookPayload, isNew: Bool) -> IslandSignal? {
        // 압축 후 재시작(source: compact)은 진행 중인 턴을 그대로 둔다
        if !isNew, payload.string("source") == "compact" { return nil }
        if !isNew, !session.cwd.isEmpty {
            session.projectName = TextUtils.projectName(forCwd: session.cwd)
            session.gitBranch = GitInfo.branch(forDirectory: session.cwd)
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
            session.gitBranch = GitInfo.branch(forDirectory: session.cwd)
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
            status: .running,
            startedAt: now
        )
        if appendActivity(&session, item) {
            session.turn.toolCount += 1
        }
        session.currentActivity = item

        if Self.userInteractionTools.contains(toolName) {
            session.phase = .waitingInput
            return .needsInput(sessionID: session.id, message: Self.inputMessage(toolName: toolName, toolInput: toolInput))
        }
        session.phase = .runningTool
        return nil
    }

    /// 사용자가 터미널 다이얼로그에서 직접 답해야 하는 툴 (권한 카드로 승인할 수 없음)
    static let userInteractionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

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
            session.phase = .waitingPermission
            return .needsInput(sessionID: session.id, message: message ?? "승인 필요")
        case "elicitation_complete", "elicitation_response":
            if session.phase == .waitingInput { session.phase = .thinking }
            return nil
        case "idle_prompt":
            // 프롬프트 입력 대기 알림 = 턴이 끝났고 열린 다이얼로그도 없다.
            // - 아직 작업 중으로 보이면 종료 이벤트를 놓친 것 (인터럽트 등)
            // - 훅 대기 없는 승인 대기 · 입력 대기는 터미널에서 거부/Esc 로 끝난 것 (그때는 아무 이벤트도 오지 않는다)
            let endedWait = (session.phase == .waitingPermission && !hasPending(session.id))
                || session.phase == .waitingInput
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

    private func handleSubagentStart(_ session: inout AgentSession, payload: HookPayload, now: Date) {
        session.activeSubagents += 1
        appendActivity(&session, ActivityItem(
            id: Self.subagentActivityID(payload.string("agent_id")),
            kind: .subagent,
            title: Self.subagentTitle(payload.string("agent_type")),
            symbolName: "person.2",
            status: .running,
            startedAt: now
        ))
    }

    private func handleSubagentStop(_ session: inout AgentSession, payload: HookPayload, now: Date) {
        session.activeSubagents = max(0, session.activeSubagents - 1)
        let id = Self.subagentActivityID(payload.string("agent_id"))
        if let index = session.activities.lastIndex(where: { $0.id == id }) {
            session.activities[index].status = .succeeded
            session.activities[index].endedAt = now
        } else {
            appendActivity(&session, ActivityItem(
                id: id,
                kind: .subagent,
                title: Self.subagentTitle(payload.string("agent_type")),
                symbolName: "person.2",
                status: .succeeded,
                startedAt: now,
                endedAt: now
            ))
        }
        if session.currentActivity?.id == id { session.currentActivity = nil }
    }

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

    private func makeSession(id: String, payload: HookPayload, now: Date) -> AgentSession {
        let cwd = payload.string("cwd") ?? ""
        return AgentSession(
            id: id,
            cwd: cwd,
            projectName: TextUtils.projectName(forCwd: cwd),
            gitBranch: cwd.isEmpty ? nil : GitInfo.branch(forDirectory: cwd),
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
        if let cwd = payload.string("cwd"), cwd != session.cwd {
            // 프로젝트명은 처음 알게 된 cwd 기준 (Claude 가 하위 폴더로 cd 해도 유지, SessionStart 에서 갱신)
            let hadCwd = !session.cwd.isEmpty
            session.cwd = cwd
            if !hadCwd {
                session.projectName = TextUtils.projectName(forCwd: cwd)
                session.gitBranch = GitInfo.branch(forDirectory: cwd)
            }
        }
        if let path = payload.string("transcript_path") { session.transcriptPath = path }
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
        if manualFocusID == sessionID { manualFocusID = nil }
        if pinnedSessionID == sessionID { pinnedSessionID = nil }
        return takePendings { request, _ in request.sessionID == sessionID }
    }

    // MARK: - 권한 대기열 헬퍼

    private func hasPending(_ sessionID: String) -> Bool {
        pendingPermissions.contains { $0.sessionID == sessionID }
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
