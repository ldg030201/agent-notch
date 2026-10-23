import Foundation
import NotchShared

/// 앱을 새로 띄웠을 때 Codex 대화 기록(`~/.codex/sessions/<연>/<월>/<일>/rollout-….jsonl`)으로 세션을 되살린다 (`RestoredSession`).
/// Claude Code 기록(`TranscriptTail`)과 같은 목적 · 같은 원칙이다: 상태(툴 실행 중 · 응답 중 · 끝남)만 고르고 내용은 담지 않는다.
///
/// 기록 모양 (줄마다 `{"timestamp", "type", "payload"}`):
/// - 첫 줄 `session_meta`: 스레드 `id` · 세션 `session_id`(서브에이전트는 부모의 ID) · `cwd` · `originator`("Codex Desktop" 등) ·
///   `thread_source`("user" · "subagent") · `git.branch`
/// - `event_msg`: `task_started`(턴 시작) · `task_complete`(턴 끝) · `turn_aborted`(사용자 중단)
/// - `response_item`: `function_call` · `custom_tool_call` · `local_shell_call`(툴 호출, `call_id`) 와 그 `…_output`, 응답 · 생각 줄
/// - `turn_context`: 턴의 `cwd`
public enum CodexRolloutTail {
    /// 첫 줄(`session_meta`)에서 읽은 세션 정보
    public struct Meta: Equatable, Sendable {
        public var threadID: String
        /// 훅의 `session_id` (메인 스레드는 스레드 ID 와 같다)
        public var sessionID: String
        public var cwd: String
        public var originator: String?
        public var gitBranch: String?
        /// 서브에이전트 스레드 (부모 세션의 훅으로 이미 보인다 → 되살리지 않는다)
        public var isSubagent: Bool

        public init(threadID: String, sessionID: String, cwd: String, originator: String? = nil, gitBranch: String? = nil, isSubagent: Bool = false) {
            self.threadID = threadID
            self.sessionID = sessionID
            self.cwd = cwd
            self.originator = originator
            self.gitBranch = gitBranch
            self.isSubagent = isSubagent
        }
    }

    /// 첫 줄 → 세션 정보. `session_meta` 가 아니거나 ID · 작업 폴더가 없으면 nil
    public static func meta<S: StringProtocol>(fromFirstLine line: S) -> Meta? {
        guard let value = try? JSONValue.parse(Data(String(line).utf8)),
              value["type"]?.stringValue == "session_meta",
              let payload = value["payload"],
              let threadID = TextUtils.nonEmpty(payload["id"]?.stringValue),
              let cwd = TextUtils.nonEmpty(payload["cwd"]?.stringValue)
        else { return nil }
        let sessionID = TextUtils.nonEmpty(payload["session_id"]?.stringValue) ?? threadID
        let source = payload["source"]
        let isSubagent = payload["thread_source"]?.stringValue == "subagent"
            || source?["subagent"] != nil
            || TextUtils.nonEmpty(payload["parent_thread_id"]?.stringValue) != nil
            || sessionID != threadID
        return Meta(
            threadID: threadID,
            sessionID: sessionID,
            cwd: cwd,
            originator: TextUtils.nonEmpty(payload["originator"]?.stringValue),
            gitBranch: TextUtils.nonEmpty(payload["git"]?["branch"]?.stringValue),
            isSubagent: isSubagent
        )
    }

    /// 기록 끝부분 줄들(오래된 것 → 최근 것) → 세션 상태. 서브에이전트 스레드 · 턴을 하나도 보지 못한 기록 · 시각을 모르면 nil.
    /// - 끝나지 않은 툴 호출(결과 줄이 아직 없음) 중 마지막 것을 실행 중으로 본다
    /// - `task_complete` · `turn_aborted` 로 끝났으면 끝남, 그 밖에 턴이 진행 중이면 응답 중
    public static func restore<S: Sequence>(meta: Meta, lines: S) -> RestoredSession? where S.Element: StringProtocol {
        guard !meta.isSubagent else { return nil }
        var cwd = meta.cwd
        var lastStamp: String?
        var pending: [(id: String?, name: String, input: JSONValue?)] = []
        var sawTurn = false
        var turnEnded = false

        for line in lines {
            guard let data = String(line).data(using: .utf8),
                  let value = try? JSONValue.parse(data),
                  let payload = value["payload"]
            else { continue }
            if let stamp = TextUtils.nonEmpty(value["timestamp"]?.stringValue) { lastStamp = stamp }

            switch value["type"]?.stringValue {
            case "turn_context":
                if let path = TextUtils.nonEmpty(payload["cwd"]?.stringValue) { cwd = path }
            case "event_msg":
                switch payload["type"]?.stringValue {
                case "task_started":
                    sawTurn = true
                    turnEnded = false
                    pending.removeAll()
                case "task_complete", "turn_aborted":
                    sawTurn = true
                    turnEnded = true
                    pending.removeAll()
                default:
                    break
                }
            case "response_item":
                let type = payload["type"]?.stringValue ?? ""
                if callTypes.contains(type) {
                    pending.append(toolCall(payload, type: type))
                    sawTurn = true
                    turnEnded = false
                } else if type.hasSuffix("_output") {
                    let callID = payload["call_id"]?.stringValue
                    pending.removeAll { $0.id != nil && $0.id == callID }
                } else if !turnEnded {
                    // 응답 · 생각 줄: 끝부분만 읽어 턴 시작을 못 봤어도 턴이 진행 중이다
                    sawTurn = true
                }
            default:
                break
            }
        }

        guard sawTurn, let lastEventAt = lastStamp.flatMap(TranscriptTail.parseTimestamp) else { return nil }
        let state: RestoredSession.State
        if turnEnded {
            state = .finished
        } else if let running = pending.last {
            state = .runningTool(name: running.name, input: running.input, toolUseID: running.id)
        } else {
            state = .thinking
        }
        return RestoredSession(
            id: meta.sessionID,
            agent: .codex,
            cwd: cwd,
            gitBranch: meta.gitBranch,
            originator: meta.originator,
            state: state,
            lastEventAt: lastEventAt
        )
    }

    /// 툴 호출 줄 종류
    static let callTypes: Set<String> = ["function_call", "custom_tool_call", "local_shell_call"]

    /// 기록의 툴 호출 → 훅과 같은 이름 · 입력 (셸은 "Bash" + `command`, apply_patch 는 `command` 에 패치 글).
    /// 그 밖의 툴은 인자 JSON 을 그대로 쓴다 (요약 제목에만 쓴다)
    static func toolCall(_ payload: JSONValue, type: String) -> (id: String?, name: String, input: JSONValue?) {
        let id = TextUtils.nonEmpty(payload["call_id"]?.stringValue)
        let name = type == "local_shell_call" ? "shell" : (TextUtils.nonEmpty(payload["name"]?.stringValue) ?? "Tool")
        // function_call 의 인자는 JSON 글, custom_tool_call 의 입력은 글 그대로
        let arguments = payload["arguments"]?.stringValue.flatMap { try? JSONValue.parse(Data($0.utf8)) }
        let rawInput = payload["input"]?.stringValue
        switch name {
        case "exec_command", "shell", "local_shell", "container.exec":
            let command = arguments?["cmd"]?.stringValue
                ?? ToolSummarizer.shellCommand(arguments)
                ?? ToolSummarizer.shellCommand(payload["action"])
            return (id, "Bash", command.map { .object(["command": .string($0)]) })
        case ApplyPatch.toolName:
            let patch = rawInput ?? arguments?["input"]?.stringValue
            return (id, name, patch.map { .object(["command": .string($0)]) })
        default:
            return (id, name, arguments)
        }
    }

    /// 파일 첫 줄 (`session_meta`). 일반 파일만 읽고(링크 · FIFO 는 nil) `maxBytes` 안에 줄바꿈이 없으면 nil
    public static func readFirstLine(atPath path: String, maxBytes: Int = 1024 * 1024) -> String? {
        guard maxBytes > 0, !path.isEmpty else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | O_NOCTTY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }

        var data: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < maxBytes {
            let count = chunk.withUnsafeMutableBytes { buffer in
                pread(fd, buffer.baseAddress!, min(buffer.count, maxBytes - data.count), off_t(data.count))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            if let newline = chunk[0..<count].firstIndex(of: UInt8(ascii: "\n")) {
                data.append(contentsOf: chunk[0..<newline])
                return String(decoding: data, as: UTF8.self)
            }
            data.append(contentsOf: chunk[0..<count])
        }
        return nil
    }
}
