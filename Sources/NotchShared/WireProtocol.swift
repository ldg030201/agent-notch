import Foundation

/// 훅 헬퍼(`notch-hook`)와 앱 사이의 통신 규약.
///
/// 전송 방식: Unix 도메인 소켓, 줄바꿈(`\n`)으로 끝나는 JSON 한 줄씩.
/// 1. 헬퍼가 `HookEnvelope` 한 줄을 보낸다.
/// 2. `expectsReply == true`(PermissionRequest, 질문 · 계획 승인 툴의 PreToolUse)인 경우에만 앱이 `HookReply` 한 줄로 응답한다.
///    헬퍼는 `reply.output`이 있으면 그 JSON을 stdout에 출력하고, 없으면 아무것도 출력하지 않는다.
/// 3. 그 외 이벤트는 보내고 바로 연결을 닫는다 (fire-and-forget). `expectsReply(event:toolName:hasReplyTimeout:)` 가 정한다.
///
/// 앱이 실행 중이 아니면 헬퍼는 조용히 exit 0 으로 종료해 Claude Code 동작에 영향을 주지 않는다.
public enum NotchWire {
    public static let protocolVersion = 1
    public static let appFolderName = "AgentNotch"
    public static let socketFileName = "notch.sock"

    /// 테스트·개발용으로 소켓 경로를 바꿀 때 쓰는 환경변수
    public static let socketPathEnvironmentKey = "AGENT_NOTCH_SOCKET"

    /// 늘 응답을 기다리는 훅 이벤트
    public static let replyEvents: Set<String> = ["PermissionRequest"]

    /// 노치에서 직접 답을 받는 툴 (질문 · 계획 승인). 이 툴의 PreToolUse 는 앱의 답을 기다린다
    public static let interactiveTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// 헬퍼가 앱의 응답을 기다려야 하는 훅 호출인지.
    /// - `PermissionRequest`: 늘 기다린다.
    /// - `PreToolUse`: 질문 · 계획 승인 툴(`interactiveTools`)이고, 훅 명령에 응답 대기 시간(`--reply-timeout`)이 있을 때만.
    ///   예전에 설치한 설정(훅 timeout 10초, 대기 시간 없음)으로 불리면 Claude Code 가 10초 만에 훅을 끊으므로 기다리지 않는다
    ///   (앱이 설정을 고칠 때까지 예전처럼 다이얼로그로 답한다).
    /// - 그 밖: 보내고 바로 끝낸다. 다른 툴의 PreToolUse 도 그대로 fire-and-forget.
    public static func expectsReply(event: String, toolName: String?, hasReplyTimeout: Bool) -> Bool {
        if replyEvents.contains(event) { return true }
        guard event == "PreToolUse", hasReplyTimeout, let toolName else { return false }
        return interactiveTools.contains(toolName)
    }

    /// 한 envelope 의 최대 크기 (이보다 크면 payload 를 버리고 요약만 전송)
    public static let maxEnvelopeBytes = 4 * 1024 * 1024

    /// 훅 프로세스 환경변수 중 앱으로 전달해도 되는 키 화이트리스트.
    /// 환경변수에는 API 키 같은 비밀 정보가 섞여 있을 수 있으므로 여기 없는 키는 절대 전송하지 않는다.
    public static let forwardedEnvironmentKeys: [String] = [
        "TERM_PROGRAM",          // iTerm.app, Apple_Terminal, vscode, WarpTerminal, ghostty …
        "ITERM_SESSION_ID",      // iTerm2 탭/세션 식별 (w0t1p0:UUID)
        "TERM_SESSION_ID",       // Terminal.app 세션 식별
        "__CFBundleIdentifier",  // 세션을 띄운 앱의 번들 ID (터미널 포커스용)
        "CLAUDE_CODE_ENTRYPOINT",// cli / desktop 등 실행 경로
        "TMUX_PANE",
    ]

    /// `~/Library/Application Support/AgentNotch`
    public static var appSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appFolderName, isDirectory: true)
    }

    public static var defaultSocketPath: String {
        appSupportDirectory.appendingPathComponent(socketFileName).path
    }

    /// 환경변수 오버라이드를 반영한 실제 소켓 경로
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment[socketPathEnvironmentKey], !override.isEmpty {
            return override
        }
        return defaultSocketPath
    }
}

/// 헬퍼 → 앱 메시지
public struct HookEnvelope: Codable, Hashable, Sendable {
    /// 프로토콜 버전
    public var v: Int
    /// `hook_event_name` (예: "PreToolUse")
    public var event: String
    /// 헬퍼가 보낸 시각 (Unix epoch, 초)
    public var sentAt: Double
    /// 화이트리스트 환경변수만 담는다 (`NotchWire.forwardedEnvironmentKeys`)
    public var env: [String: String]
    /// 앱의 응답을 기다리는지 여부
    public var expectsReply: Bool
    /// 훅이 stdin 으로 받은 원본 JSON
    public var payload: JSONValue

    public init(
        v: Int = NotchWire.protocolVersion,
        event: String,
        sentAt: Double,
        env: [String: String],
        expectsReply: Bool,
        payload: JSONValue
    ) {
        self.v = v
        self.event = event
        self.sentAt = sentAt
        self.env = env
        self.expectsReply = expectsReply
        self.payload = payload
    }
}

/// 앱 → 헬퍼 응답 (PermissionRequest · 질문 · 계획 승인처럼 응답이 필요한 호출에서만 사용)
public struct HookReply: Codable, Hashable, Sendable {
    public var v: Int
    /// 헬퍼가 stdout 으로 그대로 출력할 훅 출력 JSON. nil 이면 아무것도 출력하지 않는다 (= 결정 위임).
    public var output: JSONValue?

    public init(v: Int = NotchWire.protocolVersion, output: JSONValue?) {
        self.v = v
        self.output = output
    }
}
