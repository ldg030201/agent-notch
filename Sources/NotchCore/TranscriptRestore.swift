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
    /// - 새 사용자 입력은 새 턴 (응답을 만드는 중).
    public static func restore<S: Sequence>(lines: S) -> RestoredSession? where S.Element: StringProtocol {
        var sessionID: String?
        var cwd: String?
        var gitBranch: String?
        var entrypoint: String?
        var lastStamp: String?
        var pending: [(id: String?, name: String, input: JSONValue?)] = []
        var sawTurn = false
        var turnEnded = false

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
                for block in message?["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_use" {
                    guard let name = TextUtils.nonEmpty(block["name"]?.stringValue) else { continue }
                    pending.append((TextUtils.nonEmpty(block["id"]?.stringValue), name, block["input"]))
                    sawTurn = true
                    turnEnded = false
                }
                if message?["stop_reason"]?.stringValue == "end_turn", pending.isEmpty {
                    turnEnded = true
                }
            case "user":
                let content = object["message"]?["content"]
                if let blocks = content?.arrayValue, blocks.contains(where: { $0["type"]?.stringValue == "tool_result" }) {
                    let finished = Set(blocks.compactMap { $0["tool_use_id"]?.stringValue })
                    pending.removeAll { $0.id.map(finished.contains) ?? false }
                } else if object["isMeta"]?.boolValue != true, let text = userText(content) {
                    sawTurn = true
                    pending.removeAll()
                    // "[Request interrupted by user]" 등: 사용자가 멈춘 턴
                    turnEnded = text.hasPrefix(interruptedPrefix)
                }
            case "system":
                if object["subtype"]?.stringValue == "stop_hook_summary" {
                    sawTurn = true
                    turnEnded = true
                    pending.removeAll()
                }
            default:
                break
            }
        }

        // 시각은 마지막 줄 것만 읽는다 (줄마다 날짜 변환기를 만들지 않게)
        guard let sessionID, let cwd, sawTurn, let lastEventAt = lastStamp.flatMap(parseTimestamp) else { return nil }
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
