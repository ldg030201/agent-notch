// Claude Code · Codex 훅 헬퍼 진입점 (Codex 훅 명령에는 `--agent codex` 가 붙는다).
//
// stdin 의 훅 JSON 을 앱의 Unix 소켓으로 한 줄(HookEnvelope) 보내고,
// 응답이 필요한 호출(PermissionRequest, 질문 · 계획 승인 툴의 PreToolUse)만 앱의 HookReply 를 기다려 stdout 으로 출력한다.
// 앱이 꺼져 있거나 어떤 오류가 나도 Claude Code 동작에 영향이 없도록 항상 조용히 exit 0 (--ping 제외).
import Foundation
import NotchShared
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum HookHelper {
    static let version = "1.0.1"
    /// 응답 대기 기본값. 훅 timeout(`NotchWire.hookTimeout`)보다 짧아야 한다.
    static let defaultReplyTimeout = Double(NotchWire.helperReplyTimeout)
    static let replyTimeoutEnvironmentKey = "AGENT_NOTCH_REPLY_TIMEOUT"
    static let debugEnvironmentKey = "AGENT_NOTCH_DEBUG"
    static let sendTimeout: TimeInterval = 2
    /// 이보다 큰 stdin 은 JSON 으로 해석하지 않는다 (이벤트 이름만 전달)
    static let maxInputBytes = 32 * 1024 * 1024
    /// 앱 응답 한 줄의 최대 크기
    static let maxReplyBytes = 1024 * 1024
}

signal(SIGPIPE, SIG_IGN)

let environment = ProcessInfo.processInfo.environment
let debug = HookDebug(enabled: environment[HookHelper.debugEnvironmentKey] == "1")
let options = HookOptions.parse(Array(CommandLine.arguments.dropFirst()))

if options.showVersion {
    StandardStream.write(Data((HookHelper.version + "\n").utf8), to: STDOUT_FILENO)
    exit(0)
}
if options.showHelp {
    StandardStream.write(Data((HookOptions.usage + "\n").utf8), to: STDOUT_FILENO)
    exit(0)
}

let socketPath = NotchWire.socketPath(environment: environment)

if options.ping {
    // 연결만 확인하고 아무것도 보내지 않는다
    guard let connection = HookSocket.connect(path: socketPath, sendTimeout: HookHelper.sendTimeout, debug: debug) else {
        exit(1)
    }
    connection.close()
    exit(0)
}

// 앱이 꺼져 있어도 stdin 은 먼저 다 읽는다 (Claude Code 쪽 파이프 쓰기 오류 방지)
let input = StandardStream.readAll(from: STDIN_FILENO, limit: HookHelper.maxInputBytes)
if input.overflowed {
    debug.log("stdin 이 너무 커서 payload 생략")
}

guard let connection = HookSocket.connect(path: socketPath, sendTimeout: HookHelper.sendTimeout, debug: debug) else {
    // 앱이 실행 중이 아님 → 조용히 종료
    exit(0)
}

let parsed = EnvelopeBuilder.reduceTaskLists(EnvelopeBuilder.parsePayload(input.data))
let event = EnvelopeBuilder.eventName(payload: parsed, argument: options.eventName)
// SessionStart · UserPromptSubmit 만: 작업 폴더의 git 브랜치를 읽어 붙인다.
// 헬퍼는 Claude Code 프로세스 안에서 돌아 프로젝트 폴더를 이미 볼 수 있다 (앱은 프로젝트 폴더를 읽지 않는다)
let payload = NotchWire.attachingGitBranch(to: parsed, event: event)
// 질문 · 계획 승인 툴의 PreToolUse 는 훅 명령에 --reply-timeout 이 있을 때만 기다린다 (예전 설정의 10초 timeout 보호)
let expectsReply = NotchWire.expectsReply(
    event: event,
    toolName: payload["tool_name"]?.stringValue,
    hasReplyTimeout: options.replyTimeout != nil
)
let line = EnvelopeBuilder.encodeLine(
    event: event,
    env: EnvelopeBuilder.forwardedEnvironment(environment),
    expectsReply: expectsReply,
    payload: payload,
    sentAt: Date().timeIntervalSince1970,
    agent: options.agent
)
debug.log("agent=\(options.agent ?? "claude") event=\(event) bytes=\(line.data.count) shrink=\(line.shrinkLevel) reply=\(expectsReply)")

guard connection.sendAll(line.data) else {
    debug.log("전송 실패 errno=\(errno)")
    connection.close()
    exit(0)
}

guard expectsReply else {
    // fire-and-forget: MessageDisplay 는 헬퍼가 끝날 때까지 렌더링이 멈추므로 바로 종료
    connection.close()
    exit(0)
}

let replyTimeout = options.replyTimeout
    ?? HookOptions.parseSeconds(environment[HookHelper.replyTimeoutEnvironmentKey])
    ?? HookHelper.defaultReplyTimeout

// Claude Code 가 먼저 종료되면(부모가 launchd 로 바뀜) 더 기다리지 않는다
let parentPID = getppid()
let replyLine = connection.readLine(timeout: replyTimeout, maxBytes: HookHelper.maxReplyBytes) {
    getppid() != parentPID
}
connection.close()

guard let replyLine else {
    debug.log("응답 없음 (타임아웃/연결 종료)")
    exit(0)
}
guard let reply = try? JSONDecoder().decode(HookReply.self, from: replyLine) else {
    debug.log("응답 해석 실패 (\(replyLine.count)바이트)")
    exit(0)
}
// Claude Code 는 stdout 전체가 JSON 객체 하나일 때만 해석하므로 객체만 출력한다
guard let output = reply.output, output.objectValue != nil, var data = try? output.serialized() else {
    debug.log("출력할 결정 없음")
    exit(0)
}
data.append(0x0A)
StandardStream.write(data, to: STDOUT_FILENO)
exit(0)
