import Foundation
import NotchShared

/// 앱을 새로 띄웠을 때 Claude Code 대화 기록(jsonl) 끝부분으로 되살린 세션 상태.
/// 앱이 꺼져 있던 사이 이미 돌고 있던 세션(예: 긴 Bash 실행 중)을 다음 훅 이벤트가 오기 전에도 보여주려고 쓴다.
/// 프롬프트 · 응답 내용은 담지 않는다. 실행 중인 툴 입력은 툴 요약(짧은 이름 · 제목)을 만드는 데만 쓰고 메모리에만 둔다
public struct RestoredSession: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// 툴 실행 중 (질문 · 계획 승인이면 입력 대기로 보여준다)
        case runningTool(name: String, input: JSONValue?, toolUseID: String?)
        /// 응답을 만드는 중
        case thinking
        /// 턴이 끝남 (Stop 훅이 돈 뒤, 끝까지 간 응답, 사용자가 중단)
        case finished
    }

    public var id: String
    public var cwd: String
    public var gitBranch: String?
    /// 기록의 `entrypoint` (예: "cli", "claude-desktop")
    public var entrypoint: String?
    public var state: State
    /// 기록의 마지막 시각
    public var lastEventAt: Date

    public init(id: String, cwd: String, gitBranch: String? = nil, entrypoint: String? = nil, state: State, lastEventAt: Date) {
        self.id = id
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.entrypoint = entrypoint
        self.state = state
        self.lastEventAt = lastEventAt
    }
}

/// 대화 기록 끝부분 → `RestoredSession`
public enum TranscriptTail {
    /// jsonl 줄들(오래된 것 → 최근 것)로 세션 상태를 만든다. 세션 ID · 작업 폴더 · 시각을 모르면 nil.
    /// - 메인 대화 줄만 본다 (`isSidechain` 인 서브에이전트 줄은 건너뜀).
    /// - 툴 호출(`tool_use`) 중 결과(`tool_result`)가 아직 없는 마지막 것을 실행 중으로 본다.
    /// - Stop 훅 요약(`system` · `stop_hook_summary`), `end_turn` 으로 끝난 응답, 사용자 중단은 턴 끝.
    /// - 새 사용자 입력은 새 턴 (응답을 만드는 중). 대화가 아닌 사용자 줄(`UserLine`)은 새 턴이 아니다:
    ///   슬래시 명령 · 백그라운드 작업 알림은 모델 응답이 이어질 때만 턴으로 보고, `!` 셸 모드 · 압축 요약은 무시한다.
    ///   로컬 명령 출력은 입력 대기 (턴 끝).
    /// - `/exit` · `/quit` 로 끝난 세션은 되살리지 않는다. `/clear` 는 대화를 새로 시작한다 (뒤에 진짜 입력이 없으면 되살리지 않음).
    public static func restore<S: Sequence>(lines: S) -> RestoredSession? where S.Element: StringProtocol {
        var sessionID: String?
        var cwd: String?
        var gitBranch: String?
        var entrypoint: String?
        var lastStamp: String?
        var pending: [(id: String?, name: String, input: JSONValue?)] = []
        var sawTurn = false
        var turnEnded = false
        /// 슬래시 명령 · 작업 알림 뒤: 모델 응답이 이어지면 그때 턴 (로컬 명령이면 응답 없이 끝난다)
        var awaitingReply = false
        /// 마지막 명령이 `/exit` · `/quit` (그 뒤에 진짜 활동이 없음)
        var exited = false

        for line in lines {
            guard let data = String(line).data(using: .utf8),
                  let value = try? JSONValue.parse(data),
                  let object = value.objectValue,
                  object["isSidechain"]?.boolValue != true
            else { continue }

            if let id = TextUtils.nonEmpty(object["sessionId"]?.stringValue) { sessionID = id }
            if let path = TextUtils.nonEmpty(object["cwd"]?.stringValue) { cwd = path }
            if let branch = object["gitBranch"]?.stringValue { gitBranch = TextUtils.nonEmpty(branch) }
            if let point = TextUtils.nonEmpty(object["entrypoint"]?.stringValue) { entrypoint = point }
            if let stamp = TextUtils.nonEmpty(object["timestamp"]?.stringValue) { lastStamp = stamp }

            switch object["type"]?.stringValue {
            case "assistant":
                let message = object["message"]
                var toolCalled = false
                for block in message?["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_use" {
                    guard let name = TextUtils.nonEmpty(block["name"]?.stringValue) else { continue }
                    pending.append((TextUtils.nonEmpty(block["id"]?.stringValue), name, block["input"]))
                    toolCalled = true
                }
                // 툴 호출, 또는 슬래시 명령(스킬 등) · 작업 알림에 이어진 응답: 턴이 진행 중
                if toolCalled || awaitingReply {
                    sawTurn = true
                    turnEnded = false
                    exited = false
                }
                awaitingReply = false
                if message?["stop_reason"]?.stringValue == "end_turn", pending.isEmpty {
                    turnEnded = true
                }
            case "user":
                let content = object["message"]?["content"]
                if let blocks = content?.arrayValue, blocks.contains(where: { $0["type"]?.stringValue == "tool_result" }) {
                    let finished = Set(blocks.compactMap { $0["tool_use_id"]?.stringValue })
                    pending.removeAll { $0.id.map(finished.contains) ?? false }
                    continue
                }
                guard object["isMeta"]?.boolValue != true, let text = userText(content) else { continue }
                let kind = UserLine(text: text, object: object)
                switch kind {
                case .prompt, .interrupted:
                    sawTurn = true
                    pending.removeAll()
                    // "[Request interrupted by user]" 등: 사용자가 멈춘 턴
                    turnEnded = kind == .interrupted
                    awaitingReply = false
                    exited = false
                case .command(let name):
                    awaitingReply = true
                    exited = false
                    if exitCommands.contains(name) {
                        awaitingReply = false
                        exited = true
                    } else if clearCommands.contains(name) {
                        // 대화를 새로 시작: 앞의 턴은 잊는다
                        awaitingReply = false
                        sawTurn = false
                        turnEnded = false
                        pending.removeAll()
                    }
                case .notification:
                    awaitingReply = true
                case .commandOutput:
                    // 로컬 명령(/model · /login · /compact …)이 끝났다: 모델 응답은 오지 않고 입력을 기다린다
                    // (실제 기록에서 로컬 명령 출력 뒤에 새 입력 없이 응답이 이어진 적은 없다)
                    awaitingReply = false
                    turnEnded = true
                case .ignored:
                    break
                }
            case "system":
                switch object["subtype"]?.stringValue {
                case "stop_hook_summary":
                    sawTurn = true
                    turnEnded = true
                    pending.removeAll()
                    awaitingReply = false
                case "local_command":
                    // 로컬 명령(/clear 등) 결과: 위와 같이 입력 대기
                    awaitingReply = false
                    turnEnded = true
                default:
                    break
                }
            default:
                break
            }
        }

        // 시각은 마지막 줄 것만 읽는다 (줄마다 날짜 변환기를 만들지 않게)
        guard !exited, let sessionID, let cwd, sawTurn, let lastEventAt = lastStamp.flatMap(parseTimestamp) else { return nil }
        let state: RestoredSession.State
        if turnEnded {
            state = .finished
        } else if let running = pending.last {
            state = .runningTool(name: running.name, input: running.input, toolUseID: running.id)
        } else {
            state = .thinking
        }
        return RestoredSession(
            id: sessionID, cwd: cwd, gitBranch: gitBranch, entrypoint: entrypoint, state: state, lastEventAt: lastEventAt
        )
    }

    static let interruptedPrefix = "[Request interrupted by user"
    /// 세션을 끝내는 명령 (뒤에 활동이 없으면 되살리지 않음)
    static let exitCommands: Set<String> = ["exit", "quit"]
    /// 대화를 새로 시작하는 명령 (`/clear` 와 별칭)
    static let clearCommands: Set<String> = ["clear", "reset", "new"]

    /// isMeta 가 아닌 사용자 텍스트 줄의 종류. Claude Code 는 대화가 아닌 줄도 `type: "user"` 로 적는다
    enum UserLine: Equatable {
        /// 사용자가 보낸 대화
        case prompt
        /// "[Request interrupted by user…]"
        case interrupted
        /// 슬래시 명령 (`<command-name>/model</command-name>` …). 이름은 `/` 없이 소문자.
        /// 로컬 명령이면 출력 줄이, 프롬프트 명령(스킬 등)이면 펼친 프롬프트와 모델 응답이 뒤따른다
        case command(name: String)
        /// 백그라운드 작업 알림 (`<task-notification>`): 모델이 이어서 응답할 수도, 안 할 수도 있다
        case notification
        /// 로컬 명령 출력 (`<local-command-stdout>` · `<local-command-stderr>`)
        case commandOutput
        /// `!` 셸 모드 입력 · 출력, `/compact` 요약 등 턴과 무관한 줄
        case ignored

        /// 슬래시 명령 줄의 앞 태그
        static let commandTags = ["<command-name>", "<command-message>", "<command-args>"]
        static let outputTags = ["<local-command-stdout>", "<local-command-stderr>"]
        static let ignoredTags = ["<local-command-caveat>", "<bash-input>", "<bash-stdout>", "<bash-stderr>"]

        init(text: String, object: [String: JSONValue]) {
            if object["isCompactSummary"]?.boolValue == true || object["isVisibleInTranscriptOnly"]?.boolValue == true {
                self = .ignored
                return
            }
            let head = text.drop(while: \.isWhitespace)
            func starts(with tags: [String]) -> Bool { tags.contains { head.hasPrefix($0) } }
            if head.hasPrefix(TranscriptTail.interruptedPrefix) {
                self = .interrupted
            } else if starts(with: Self.commandTags) {
                self = .command(name: Self.commandName(in: text))
            } else if head.hasPrefix("<task-notification>") {
                self = .notification
            } else if starts(with: Self.outputTags) {
                self = .commandOutput
            } else if starts(with: Self.ignoredTags) {
                self = .ignored
            } else {
                self = .prompt
            }
        }

        /// `<command-name>/exit</command-name>` → "exit" (없으면 "")
        static func commandName(in text: String) -> String {
            guard let open = text.range(of: "<command-name>"),
                  let close = text.range(of: "</command-name>", range: open.upperBound..<text.endIndex)
            else { return "" }
            let name = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return String(name.drop(while: { $0 == "/" })).lowercased()
        }
    }

    /// 대화 기록 끝부분에 적힌 마지막 브랜치 (`gitBranch`). 기록이 없거나 브랜치가 없으면 nil.
    /// 보호 폴더(`ProtectedLocations`)에 있는 프로젝트의 `.git` 을 직접 읽지 않으려고 쓴다 (기록은 `~/.claude` 아래)
    public static func lastGitBranch(atPath path: String, tailBytes: Int = 64 * 1024) -> String? {
        guard let lines = readTail(atPath: path, maxBytes: tailBytes) else { return nil }
        for line in lines.reversed() where line.contains("\"gitBranch\"") {
            guard let value = try? JSONValue.parse(Data(line.utf8)),
                  let branch = TextUtils.nonEmpty(value["gitBranch"]?.stringValue)
            else { continue }
            return branch
        }
        return nil
    }

    /// 파일 끝 `maxBytes` 바이트까지를 줄 단위로 (오래된 것 → 최근 것). 중간부터 읽었으면 잘린 첫 줄은 버린다.
    /// 훅이 넘긴 경로(`transcript_path`)를 메인 스레드에서 읽으므로 일반 파일만 읽는다: 심볼릭 링크 · FIFO · 장치 파일은 nil
    /// (FIFO 는 읽다가 영원히 멈추고, `/dev/zero` 는 끝없이 메모리를 먹는다). lstat 으로 먼저 거르고,
    /// 확인과 열기 사이에 바뀌는 경우를 위해 링크를 따라가지 않고(`O_NOFOLLOW`) 논블로킹으로 열어 fstat 으로 한 번 더 확인한다.
    /// 깨진 UTF-8 은 대체 문자로 읽는다
    public static func readTail(atPath path: String, maxBytes: Int) -> [Substring]? {
        guard maxBytes > 0, !path.isEmpty else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | O_NOCTTY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }

        let size = Int64(info.st_size)
        let offset = max(0, size - Int64(maxBytes))
        var data = [UInt8](repeating: 0, count: Int(size - offset))
        var filled = 0
        while filled < data.count {
            let count = data.withUnsafeMutableBytes { buffer in
                pread(fd, buffer.baseAddress! + filled, buffer.count - filled, off_t(offset) + off_t(filled))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            filled += count
        }
        var bytes = data[0..<filled]

        // 중간부터 읽었으면 첫 줄은 잘렸을 수 있다: 바로 앞 바이트가 줄바꿈이 아니면 첫 줄바꿈까지 버린다
        if offset > 0 {
            var previous: UInt8 = 0
            let startsLine = pread(fd, &previous, 1, off_t(offset - 1)) == 1 && previous == UInt8(ascii: "\n")
            if !startsLine {
                guard let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) else { return [] }
                bytes = bytes[(newline + 1)...]
            }
        }
        return String(decoding: bytes, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
    }

    /// 사용자 입력 글자 (문자열, 또는 text 블록). 툴 결과만 있는 줄이면 nil
    private static func userText(_ content: JSONValue?) -> String? {
        if let text = content?.stringValue { return text }
        let texts = (content?.arrayValue ?? []).compactMap { block -> String? in
            block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// 기록 시각 (ISO 8601, 소수 초 있음/없음)
    static func parseTimestamp(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
