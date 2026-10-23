import Foundation
import NotchShared

// MARK: - 세션 상태

/// 세션이 지금 어떤 단계에 있는지
public enum SessionPhase: String, Codable, Sendable, CaseIterable {
    /// 프롬프트 입력 대기 (턴 없음)
    case idle
    /// 턴 진행 중이지만 툴 실행은 아님 (응답 생성/추론)
    case thinking
    /// 툴 실행 중
    case runningTool
    /// 권한 승인 대기
    case waitingPermission
    /// 질문/입력 대기 (elicitation, idle_prompt 알림 등)
    case waitingInput
    /// 컨텍스트 압축 중
    case compacting
    /// 턴 완료 (Stop)
    case completed
    /// 턴 실패 (StopFailure)
    case failed

    /// 사용자의 주의가 필요한 상태인지
    public var needsAttention: Bool {
        switch self {
        case .waitingPermission, .waitingInput, .failed: return true
        default: return false
        }
    }

    /// 에이전트가 일하는 중인지
    public var isWorking: Bool {
        switch self {
        case .thinking, .runningTool, .compacting: return true
        default: return false
        }
    }

    /// 단계 이름 (아일랜드 목록 부제 · 메뉴바 메뉴 공용).
    /// 쉬는 중 · 툴 실행 · 완료는 화면마다 더 자세한 문구(경과 시간 · 툴 이름 · 백그라운드 작업)를 쓸 수 있다
    public var label: String {
        switch self {
        case .idle: return "대기 중"
        case .thinking: return "생각 중"
        case .runningTool: return "작업 중"
        case .waitingPermission: return "승인 대기"
        case .waitingInput: return "입력 대기"
        case .compacting: return "압축 중"
        case .completed: return "완료"
        case .failed: return "실패"
        }
    }
}

/// 세션을 실행한 터미널/앱 정보 (터미널로 점프할 때 사용)
public struct TerminalContext: Hashable, Sendable, Codable {
    public var termProgram: String?
    public var itermSessionID: String?
    public var bundleIdentifier: String?
    public var entrypoint: String?
    /// 세션 앱이 붙이는 세션 ID. Claude 데스크톱 앱은 `CLAUDE_CODE_HOST_SESSION_ID`(`local_…`), Codex 는 스레드 ID.
    /// 앱 안의 그 세션을 열 때 쓴다 (`claudeDesktopSessionURL` · `codexDesktopThreadURL`)
    public var hostSessionID: String?
    /// Codex 를 띄운 앱 이름 (`CODEX_INTERNAL_ORIGINATOR_OVERRIDE`, Codex 앱이면 "Codex")
    public var originator: String?

    public init(
        termProgram: String? = nil,
        itermSessionID: String? = nil,
        bundleIdentifier: String? = nil,
        entrypoint: String? = nil,
        hostSessionID: String? = nil,
        originator: String? = nil
    ) {
        self.termProgram = termProgram
        self.itermSessionID = itermSessionID
        self.bundleIdentifier = bundleIdentifier
        self.entrypoint = entrypoint
        self.hostSessionID = hostSessionID
        self.originator = originator
    }

    /// `HookEnvelope.env` (화이트리스트 환경변수)로부터 생성.
    /// 다른 에이전트의 키는 읽지 않는다: Codex 앱 터미널에서 띄운 Claude Code 에는 Codex 키가, Claude 앱 안에서 띄운 Codex 에는
    /// Claude 키가 물려 있을 수 있어서 그 앱의 세션으로 잘못 알아보지 않게 한다
    public init(environment: [String: String], agent: AgentKind = .claude) {
        func value(_ key: String) -> String? {
            guard let raw = environment[key], !raw.isEmpty else { return nil }
            return raw
        }
        switch agent {
        case .claude:
            self.init(
                termProgram: value("TERM_PROGRAM"),
                itermSessionID: value("ITERM_SESSION_ID"),
                bundleIdentifier: value("__CFBundleIdentifier"),
                entrypoint: value("CLAUDE_CODE_ENTRYPOINT"),
                hostSessionID: value("CLAUDE_CODE_HOST_SESSION_ID")
            )
        case .codex:
            self.init(
                termProgram: value("TERM_PROGRAM"),
                itermSessionID: value("ITERM_SESSION_ID"),
                bundleIdentifier: value("__CFBundleIdentifier"),
                hostSessionID: value("CODEX_THREAD_ID"),
                originator: value("CODEX_INTERNAL_ORIGINATOR_OVERRIDE")
            )
        }
    }
}

// MARK: - Diff

public struct DiffLine: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case added
        case removed
        case context
    }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// 파일 한 개에 대한 작은 diff 요약 (노치에 3줄 정도 보여주는 용도)
public struct DiffSnippet: Hashable, Sendable {
    /// 노치/펼침 화면에서 보관할 최대 미리보기 줄 수
    public static let maxStoredLines = 8

    public var filePath: String
    public var added: Int
    public var removed: Int
    /// 새 파일 기준 첫 변경 줄 번호 (알 수 있을 때만)
    public var startLine: Int?
    /// 변경 줄 미리보기 (최대 `maxStoredLines`, 변경 줄 위주)
    public var lines: [DiffLine]
    public var isNewFile: Bool

    public init(
        filePath: String,
        added: Int,
        removed: Int,
        startLine: Int? = nil,
        lines: [DiffLine],
        isNewFile: Bool = false
    ) {
        self.filePath = filePath
        self.added = added
        self.removed = removed
        self.startLine = startLine
        self.lines = lines
        self.isNewFile = isNewFile
    }

    public var fileName: String { (filePath as NSString).lastPathComponent }
}

// MARK: - 활동 타임라인

public enum ActivityKind: String, Hashable, Sendable {
    case prompt
    case tool
    case compaction
    case subagent
}

public enum ActivityStatus: String, Hashable, Sendable {
    case running
    case succeeded
    case failed
}

public struct ActivityItem: Identifiable, Hashable, Sendable {
    /// tool_use_id 가 있으면 그것, 없으면 생성한 UUID 문자열
    public var id: String
    public var kind: ActivityKind
    public var toolName: String?
    /// 짧은 제목 (예: "Edit session.ts", "Bash npm test")
    public var title: String
    /// 보조 설명 (예: 전체 명령어, 파일 경로)
    public var detail: String?
    /// SF Symbol 이름
    public var symbolName: String
    /// 접힌 상태에 쓰는 짧은 툴 이름 (예: "Bash", MCP 는 서버 이름). 없으면 제목 첫 단어 (`shortLabel`)
    public var label: String?
    public var status: ActivityStatus
    public var startedAt: Date
    public var diff: DiffSnippet?
    /// 이 활동을 한 서브에이전트 `agent_id` (메인 에이전트면 nil). 서브에이전트 항목(`agent:<id>`)은 그 서브에이전트 자신.
    /// 메인 턴이 끝나도 계속 도는 서브에이전트의 활동은 턴 끝에서 닫지 않는다
    public var agentID: String?

    public init(
        id: String,
        kind: ActivityKind,
        toolName: String? = nil,
        title: String,
        detail: String? = nil,
        symbolName: String,
        label: String? = nil,
        status: ActivityStatus,
        startedAt: Date,
        diff: DiffSnippet? = nil,
        agentID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.toolName = toolName
        self.title = title
        self.detail = detail
        self.symbolName = symbolName
        self.label = label
        self.status = status
        self.startedAt = startedAt
        self.diff = diff
        self.agentID = agentID
    }

    /// 접힌 상태용 짧은 이름: `label`, 없으면 제목 첫 단어 (예: "Agent Explore" → "Agent")
    public var shortLabel: String {
        if let label = TextUtils.nonEmpty(label) { return label }
        return title.split(separator: " ").first.map(String.init) ?? title
    }
}

/// 현재(또는 직전) 턴에서 바뀐 내용 요약
public struct TurnSummary: Hashable, Sendable {
    /// 변경된 파일 경로 (처음 바뀐 순서, 중복 없음)
    public var changedFiles: [String]
    public var added: Int
    public var removed: Int
    /// 턴이 끝난 시각 (Stop · StopFailure). 그 뒤에 오는 이벤트(idle_prompt · 백그라운드 작업 등)로 소요 시간이 늘지 않게 따로 둔다
    public var endedAt: Date?

    public init(
        changedFiles: [String] = [],
        added: Int = 0,
        removed: Int = 0,
        endedAt: Date? = nil
    ) {
        self.changedFiles = changedFiles
        self.added = added
        self.removed = removed
        self.endedAt = endedAt
    }
}

// MARK: - 권한 요청

/// 훅이 노치의 결정을 기다리는 요청. 권한 요청(PermissionRequest)과
/// 노치에서 답하는 질문 · 계획 승인(AskUserQuestion · ExitPlanMode 의 PreToolUse)이 같은 대기열 · 시간 제한 · 정리 규칙을 쓴다 (`kind`).
public struct PermissionRequestInfo: Identifiable, Hashable, Sendable {
    /// 앱이 부여한 요청 ID (훅 연결과 매칭)
    public var id: UUID
    public var sessionID: String
    public var toolName: String
    /// 사람이 읽는 제목 (예: "Bash 실행 요청")
    public var title: String
    /// 핵심 내용 (명령어, 파일 경로 등). 숨은 문자는 드러낸 상태 (줄바꿈 → "⏎")
    public var detail: String
    public var toolInput: JSONValue
    /// 훅 입력의 `permission_suggestions` (항상 허용에 사용)
    public var suggestions: JSONValue?
    public var receivedAt: Date
    /// `detail` 이 `tool_input` 을 다 담지 못함 (글자 수 제한 등). 카드는 이때 허용을 막는다
    public var isDetailTruncated: Bool
    /// 권한 요청 · 질문 · 계획 승인
    public var kind: HookRequestKind
    /// 툴 호출 ID (PreToolUse 에서 온 질문 · 계획 승인만. PermissionRequest 에는 없다)
    public var toolUseID: String?

    public init(
        id: UUID,
        sessionID: String,
        toolName: String,
        title: String,
        detail: String,
        toolInput: JSONValue,
        suggestions: JSONValue?,
        receivedAt: Date,
        isDetailTruncated: Bool = false,
        kind: HookRequestKind = .permission,
        toolUseID: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.toolName = toolName
        self.title = title
        self.detail = detail
        self.toolInput = toolInput
        self.suggestions = suggestions
        self.receivedAt = receivedAt
        self.isDetailTruncated = isDetailTruncated
        self.kind = kind
        self.toolUseID = toolUseID
    }

    /// 노치에서 답하는 질문 · 계획 승인인지 (권한 요청이 아님)
    public var isInteraction: Bool { kind != .permission }
}

public enum PermissionDecision: Hashable, Sendable {
    /// 허용. 계획 승인(ExitPlanMode)에서는 계획 승인
    case allow
    /// `permission_suggestions` 를 `updatedPermissions` 로 적용해 다음부터 묻지 않음
    case allowAlways
    case deny(message: String?)
    /// 결정하지 않음 → Claude Code 기본 권한 프롬프트로 넘김
    case passthrough
    /// 질문(AskUserQuestion)의 답 (질문 순서대로)
    case answer([QuestionAnswer])
}

// MARK: - 세션

public struct AgentSession: Identifiable, Hashable, Sendable {
    public static let maxActivities = 40
    public static let maxStreamingCharacters = 2_000

    /// 훅의 `session_id` (Claude Code 세션 · Codex 스레드)
    public var id: String
    /// 세션을 돌리는 에이전트 (Claude Code · Codex)
    public var agent: AgentKind
    public var cwd: String
    /// cwd 의 마지막 경로 요소 (예: "api-server")
    public var projectName: String
    public var gitBranch: String?
    public var transcriptPath: String?

    /// 보이는 단계. 스토어가 남은 대기와 메인 턴 단계(`mainPhase`)로 정한다 (`SessionStore` 의 `finalize`)
    public var phase: SessionPhase
    public var startedAt: Date
    public var lastEventAt: Date
    public var turnStartedAt: Date?
    /// 메인 에이전트의 턴이 끝났는지 (Stop · StopFailure · 인터럽트 · idle_prompt, 끝난 채로 되살린 세션).
    /// 새 프롬프트 · SessionStart · 메인 에이전트의 툴 진행이 오면 false.
    /// 이때 오는 서브에이전트 이벤트는 백그라운드 작업이라 세션을 다시 작업 중으로 바꾸지 않는다 (단계로 추정하지 않고 따로 기억한다:
    /// 백그라운드 서브에이전트의 질문 · 승인에 답하면 단계가 바뀌어 "끝났다" 는 사실을 잃는다)
    public var mainTurnEnded: Bool
    /// 대기를 뺀 메인 턴의 단계 (유휴 · 생각 중 · 툴 실행 · 압축 · 완료 · 실패). 이벤트 처리는 이 값만 바꾸고
    /// 승인 · 입력 대기는 스토어의 대기 목록에 둔다. 메인 턴이 진행 중일 때는 서브에이전트의 툴 진행도 턴의 작업이라 반영하고
    /// (메인은 Agent 툴로 그 서브에이전트를 기다린다), 메인 턴이 끝난 뒤의 서브에이전트(백그라운드) 이벤트는 반영하지 않는다
    var mainPhase: SessionPhase

    public var lastPrompt: String?
    public var currentActivity: ActivityItem?
    /// 최신 항목이 마지막. 최대 `maxActivities`
    public var activities: [ActivityItem]
    public var lastDiff: DiffSnippet?
    public var turn: TurnSummary

    /// Stop 의 `last_assistant_message`
    public var lastAssistantMessage: String?
    public var lastNotification: String?
    public var errorMessage: String?

    /// 완료됐지만 사용자가 아직 확인하지 않음
    public var hasUnseenCompletion: Bool
    public var activeSubagents: Int
    /// 백그라운드 셸 수 (`run_in_background` Bash). 시작할 때 늘리고, 턴이 끝날 때 `background_tasks` 로 맞춘다
    public var backgroundShells: Int
    /// 그 밖의 백그라운드 작업 수 (모니터 · 워크플로 · 팀원 · MCP 작업 등). 셸과 같은 방식으로 센다
    public var backgroundOthers: Int
    public var terminal: TerminalContext

    public init(
        id: String,
        agent: AgentKind = .claude,
        cwd: String,
        projectName: String,
        gitBranch: String? = nil,
        transcriptPath: String? = nil,
        phase: SessionPhase = .idle,
        startedAt: Date,
        lastEventAt: Date,
        turnStartedAt: Date? = nil,
        mainTurnEnded: Bool = false,
        lastPrompt: String? = nil,
        currentActivity: ActivityItem? = nil,
        activities: [ActivityItem] = [],
        lastDiff: DiffSnippet? = nil,
        turn: TurnSummary = TurnSummary(),
        lastAssistantMessage: String? = nil,
        lastNotification: String? = nil,
        errorMessage: String? = nil,
        hasUnseenCompletion: Bool = false,
        activeSubagents: Int = 0,
        backgroundShells: Int = 0,
        backgroundOthers: Int = 0,
        terminal: TerminalContext = TerminalContext()
    ) {
        self.id = id
        self.agent = agent
        self.cwd = cwd
        self.projectName = projectName
        self.gitBranch = gitBranch
        self.transcriptPath = transcriptPath
        self.phase = phase
        // 대기 단계로 만든 세션은 그 대기를 일으킨 툴이 실행 중인 것으로 둔다
        self.mainPhase = phase == .waitingPermission || phase == .waitingInput ? .runningTool : phase
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.turnStartedAt = turnStartedAt
        self.mainTurnEnded = mainTurnEnded
        self.lastPrompt = lastPrompt
        self.currentActivity = currentActivity
        self.activities = activities
        self.lastDiff = lastDiff
        self.turn = turn
        self.lastAssistantMessage = lastAssistantMessage
        self.lastNotification = lastNotification
        self.errorMessage = errorMessage
        self.hasUnseenCompletion = hasUnseenCompletion
        self.activeSubagents = activeSubagents
        self.backgroundShells = backgroundShells
        self.backgroundOthers = backgroundOthers
        self.terminal = terminal
    }
}

extension AgentSession {
    /// 메인 대화와 따로 도는 작업 수: 서브에이전트 + 백그라운드 셸 + 그 밖의 작업
    public var backgroundTaskCount: Int {
        activeSubagents + backgroundShells + backgroundOthers
    }

    /// 이번(또는 직전) 턴 소요 시간: 턴 시작(`turnStartedAt`) → 끝난 시각(`turn.endedAt`). 끝난 시각을 모르면 마지막 이벤트까지, 시작을 모르면 nil
    public var turnDuration: TimeInterval? {
        guard let start = turnStartedAt else { return nil }
        return (turn.endedAt ?? lastEventAt).timeIntervalSince(start)
    }

    /// 아일랜드에 한 줄로 보여줄 최근 응답 텍스트.
    /// 스트리밍 중이면(`SessionStore.streamingTexts`) 그 마지막 비어 있지 않은 줄, 아니면 `lastAssistantMessage` 의 마지막 비어 있지 않은 줄.
    public func latestTextLine(streaming: String?) -> String? {
        streaming.flatMap(Self.lastNonEmptyLine) ?? lastAssistantMessage.flatMap(Self.lastNonEmptyLine)
    }

    /// 마지막 비어 있지 않은 줄 (앞뒤 공백 제거). 뒤에서부터 찾아 앞쪽 글은 나누지 않는다
    static func lastNonEmptyLine(_ text: String) -> String? {
        var end = text.endIndex
        while end > text.startIndex {
            let start = text[..<end].lastIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.startIndex
            let line = text[start..<end].trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line }
            guard start > text.startIndex else { return nil }
            end = text.index(before: start)  // 줄바꿈 앞으로
        }
        return nil
    }
}

// MARK: - UI 신호

/// UI 가 "잠깐 펼치기" 같은 일시적 반응을 하도록 스토어가 내보내는 신호
public enum IslandSignal: Hashable, Sendable {
    /// 파일 수정 → 미니 diff 피크
    case edited(sessionID: String, diff: DiffSnippet)
    /// 권한 요청 → 즉시 펼치고 해결될 때까지 유지
    case permissionRequested(id: UUID, sessionID: String)
    /// 턴 완료
    case completed(sessionID: String)
    /// 턴 실패
    case failed(sessionID: String)
    /// 질문/입력 필요
    case needsInput(sessionID: String, message: String)
    /// 새 세션 시작
    case sessionStarted(sessionID: String)
}

/// 같은 신호가 연달아 와도 UI 가 감지할 수 있도록 일련번호를 붙인 래퍼
public struct SignalEvent: Hashable, Sendable {
    public let seq: Int
    public let signal: IslandSignal

    public init(seq: Int, signal: IslandSignal) {
        self.seq = seq
        self.signal = signal
    }
}
