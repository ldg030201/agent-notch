import Foundation
import NotchShared

/// 명령줄 인자 해석 결과.
///
/// 사용법: `notch-hook [--agent NAME] [EventName] [--reply-timeout SECONDS]`, `notch-hook --version`, `notch-hook --ping`
struct HookOptions {
    /// 위치 인자로 받은 이벤트 이름 (stdin 에 `hook_event_name` 이 없을 때만 사용)
    var eventName: String?
    /// `--reply-timeout` 값 (초)
    var replyTimeout: Double?
    /// `--agent` 값 (예: "codex"). 없으면 Claude Code 훅
    var agent: String?
    var showVersion = false
    var showHelp = false
    var ping = false

    static func parse(_ arguments: [String]) -> HookOptions {
        var options = HookOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--version", "-v":
                options.showVersion = true
            case "--help", "-h":
                options.showHelp = true
            case "--ping":
                options.ping = true
            case NotchWire.replyTimeoutFlag:
                if index + 1 < arguments.count {
                    options.replyTimeout = parseSeconds(arguments[index + 1])
                    index += 1
                }
            case AgentKind.commandLineFlag:
                if index + 1 < arguments.count {
                    options.agent = parseAgent(arguments[index + 1])
                    index += 1
                }
            default:
                if argument.hasPrefix(NotchWire.replyTimeoutFlag + "=") {
                    options.replyTimeout = parseSeconds(String(argument.dropFirst(NotchWire.replyTimeoutFlag.count + 1)))
                } else if argument.hasPrefix(AgentKind.commandLineFlag + "=") {
                    options.agent = parseAgent(String(argument.dropFirst(AgentKind.commandLineFlag.count + 1)))
                } else if !argument.hasPrefix("-"), options.eventName == nil, !argument.isEmpty {
                    options.eventName = argument
                }
                // 모르는 옵션은 무시한다 (훅 설정이 바뀌어도 Claude Code 동작을 막지 않게)
            }
            index += 1
        }
        return options
    }

    /// 양수·유한한 초 값만 허용한다. 너무 큰 값은 하루로 자른다.
    static func parseSeconds(_ text: String?) -> Double? {
        guard let text, let value = Double(text.trimmingCharacters(in: .whitespaces)),
              value.isFinite, value > 0 else { return nil }
        return min(value, 86_400)
    }

    /// 아는 에이전트 이름만 받는다 (`AgentKind`). 모르는 이름은 무시한다 (Claude Code 훅으로 본다)
    static func parseAgent(_ text: String) -> String? {
        AgentKind(name: text)?.rawValue
    }

    static let usage = """
    사용법: notch-hook [--agent claude|codex] [EventName] [--reply-timeout SECONDS]
           notch-hook --version
           notch-hook --ping
    """
}
