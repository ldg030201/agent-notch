import Foundation

/// 명령줄 인자 해석 결과.
///
/// 사용법: `notch-hook [EventName] [--reply-timeout SECONDS]`, `notch-hook --version`, `notch-hook --ping`
struct HookOptions {
    /// 위치 인자로 받은 이벤트 이름 (stdin 에 `hook_event_name` 이 없을 때만 사용)
    var eventName: String?
    /// `--reply-timeout` 값 (초)
    var replyTimeout: Double?
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
            case "--reply-timeout":
                if index + 1 < arguments.count {
                    options.replyTimeout = parseSeconds(arguments[index + 1])
                    index += 1
                }
            default:
                if argument.hasPrefix("--reply-timeout=") {
                    options.replyTimeout = parseSeconds(String(argument.dropFirst("--reply-timeout=".count)))
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

    static let usage = """
    사용법: notch-hook [EventName] [--reply-timeout SECONDS]
           notch-hook --version
           notch-hook --ping
    """
}
