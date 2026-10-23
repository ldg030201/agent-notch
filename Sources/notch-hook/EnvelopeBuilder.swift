import Foundation
import NotchShared

/// stdin payload 를 `HookEnvelope` 한 줄로 만든다.
/// 크기가 `NotchWire.maxEnvelopeBytes` 를 넘으면 payload 를 단계적으로 줄여서라도(`PayloadShrinker`, NotchShared) 반드시 보낸다.
enum EnvelopeBuilder {
    /// stdin 바이트 → payload. 비었거나 JSON 객체가 아니면 `{}`.
    static func parsePayload(_ data: Data) -> JSONValue {
        guard !data.isEmpty, let value = try? JSONValue.parse(data), value.objectValue != nil else {
            return .object([:])
        }
        return value
    }

    /// Stop · SubagentStop 의 `background_tasks` 는 앱이 개수만 쓰므로 항목마다 작업 ID · 종류 · 상태만 남긴다 (명령 · 설명은 보내지 않는다).
    /// 쓰지 않는 `session_crons`(예약 프롬프트)는 뺀다
    static func reduceTaskLists(_ payload: JSONValue) -> JSONValue {
        guard var object = payload.objectValue else { return payload }
        object["session_crons"] = nil
        if let tasks = object["background_tasks"]?.arrayValue {
            object["background_tasks"] = .array(tasks.prefix(maxBackgroundTasks).map { task in
                var kept: [String: JSONValue] = [:]
                for key in ["id", "type", "status"] {
                    if let text = task[key]?.stringValue { kept[key] = .string(String(text.prefix(64))) }
                }
                return .object(kept)
            })
        }
        return .object(object)
    }

    static let maxBackgroundTasks = 256

    /// 화이트리스트 키 중 값이 있는 것만 담는다. 그 외 환경변수는 절대 전달하지 않는다.
    static func forwardedEnvironment(_ environment: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in NotchWire.forwardedEnvironmentKeys {
            if let value = environment[key], !value.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    /// 이벤트 이름: payload 의 `hook_event_name` → 위치 인자 → "Unknown"
    static func eventName(payload: JSONValue, argument: String?) -> String {
        if let name = payload["hook_event_name"]?.stringValue, !name.isEmpty { return name }
        if let argument, !argument.isEmpty { return argument }
        return "Unknown"
    }

    /// 줄바꿈까지 포함한 전송용 바이트. 크기 제한을 넘으면 payload 를 줄인다.
    /// - Returns: (전송할 바이트, 축소 단계 0 = 원본)
    static func encodeLine(
        event: String,
        env: [String: String],
        expectsReply: Bool,
        payload: JSONValue,
        sentAt: Double,
        agent: String? = nil,
        maxBytes: Int = NotchWire.maxEnvelopeBytes
    ) -> (data: Data, shrinkLevel: Int) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        func encode(_ payload: JSONValue) -> Data? {
            let envelope = HookEnvelope(
                event: event,
                sentAt: sentAt,
                env: env,
                expectsReply: expectsReply,
                payload: payload,
                agent: agent
            )
            return try? encoder.encode(envelope)
        }

        var last: Data?
        for level in 0...PayloadShrinker.maxLevel {
            // 줄일 대상이 없는 단계는 다시 인코딩하지 않는다
            if level > 0, level < 3, !PayloadShrinker.levelApplies(level, to: payload) { continue }
            let candidate = level == 0 ? payload : PayloadShrinker.shrink(payload, level: level)
            guard var data = encode(candidate) else { continue }
            last = data
            if data.count + 1 <= maxBytes {
                data.append(0x0A)
                return (data, level)
            }
        }
        // 이론상 도달하지 않지만, 그래도 최소 envelope 은 보낸다
        var data = last ?? encode(.object([:])) ?? Data("{}".utf8)
        data.append(0x0A)
        return (data, PayloadShrinker.maxLevel)
    }
}
