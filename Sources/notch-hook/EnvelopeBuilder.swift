import Foundation
import NotchShared

/// stdin payload 를 `HookEnvelope` 한 줄로 만든다.
/// 크기가 `NotchWire.maxEnvelopeBytes` 를 넘으면 payload 를 단계적으로 줄여서라도 반드시 보낸다.
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
                payload: payload
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

/// 큰 payload 를 단계적으로 줄인다. 단계가 높을수록 더 많이 버린다.
///
/// 1. `tool_input` 의 긴 문자열(content/old_string/new_string/command) 을 64KB 로 자르고,
///    `tool_response` 는 작은 스칼라 필드와 `structuredPatch`·`bashEditDiff` 만 남긴다.
/// 2. `tool_response` 에서 `structuredPatch`·`bashEditDiff` 도 버린다.
/// 3. payload 전체의 모든 문자열을 64KB 로 자른다.
/// 4. 최상위 스칼라 필드만 남긴다 (문자열 4KB).
/// 5. 세션/툴 식별 필드만 남긴다.
enum PayloadShrinker {
    static let maxLevel = 5
    static let longStringLimit = 64 * 1024
    static let smallScalarLimit = 4 * 1024
    /// 줄였다는 표시 (앱이 diff 가 불완전함을 알 수 있게)
    static let truncatedMarkerKey = "_agent_notch_truncated"

    static let toolInputLongKeys: Set<String> = ["content", "old_string", "new_string", "command"]
    static let keptResponseStructures: Set<String> = ["structuredPatch", "bashEditDiff"]
    static let identityKeys: [String] = [
        "hook_event_name", "session_id", "cwd", "transcript_path", "prompt_id",
        "permission_mode", "agent_id", "agent_type",
        "tool_name", "tool_use_id", "notification_type", "source", "reason",
    ]

    /// 1·2단계는 tool_input/tool_response 가 있을 때만 의미가 있다
    static func levelApplies(_ level: Int, to payload: JSONValue) -> Bool {
        switch level {
        case 1:
            return payload["tool_input"] != nil || payload["tool_response"] != nil
        case 2:
            guard let response = payload["tool_response"]?.objectValue else { return false }
            return keptResponseStructures.contains { response[$0] != nil }
        default:
            return true
        }
    }

    static func shrink(_ payload: JSONValue, level: Int) -> JSONValue {
        guard var object = payload.objectValue else { return .object([:]) }

        if level >= 4 {
            var reduced: [String: JSONValue] = [:]
            let keys: [String] = level >= 5 ? identityKeys : Array(object.keys)
            for key in keys {
                guard let value = object[key] else { continue }
                if let scalar = smallScalar(value, limit: smallScalarLimit, truncating: true) {
                    reduced[key] = scalar
                }
            }
            // 줄여 둔 백그라운드 작업 목록(종류 · 상태)은 작아서 남긴다 (없으면 앱이 개수를 맞추지 못한다)
            if let tasks = object["background_tasks"] { reduced["background_tasks"] = tasks }
            reduced[truncatedMarkerKey] = .bool(true)
            return .object(reduced)
        }

        if let toolInput = object["tool_input"] {
            object["tool_input"] = truncateKeys(toolInput, keys: toolInputLongKeys, limit: longStringLimit)
        }
        if let toolResponse = object["tool_response"] {
            object["tool_response"] = reduceToolResponse(toolResponse, keepStructures: level == 1)
        }
        var result = JSONValue.object(object)
        if level >= 3 {
            result = truncateAllStrings(result, limit: longStringLimit)
        }
        if case .object(var final) = result {
            final[truncatedMarkerKey] = .bool(true)
            result = .object(final)
        }
        return result
    }

    // MARK: - 단계별 도우미

    /// `tool_response` 를 작은 스칼라 필드 (+ 선택적으로 patch 구조) 만 남긴다.
    static func reduceToolResponse(_ value: JSONValue, keepStructures: Bool) -> JSONValue {
        guard let object = value.objectValue else {
            // 문자열 응답 등은 작은 경우에만 유지
            return smallScalar(value, limit: smallScalarLimit, truncating: false) ?? .null
        }
        var reduced: [String: JSONValue] = [:]
        for (key, field) in object {
            if keepStructures, keptResponseStructures.contains(key) {
                reduced[key] = field
            } else if let scalar = smallScalar(field, limit: smallScalarLimit, truncating: false) {
                reduced[key] = scalar
            }
        }
        return .object(reduced)
    }

    /// 스칼라 값이면 반환. 문자열이 limit 를 넘으면 잘라내거나(truncating) 버린다.
    static func smallScalar(_ value: JSONValue, limit: Int, truncating: Bool) -> JSONValue? {
        switch value {
        case .number, .bool, .null:
            return value
        case .string(let text):
            if text.utf8.count <= limit { return value }
            return truncating ? .string(truncate(text, maxBytes: limit)) : nil
        case .array, .object:
            return nil
        }
    }

    /// 지정한 키의 문자열만 (중첩 포함, 예: MultiEdit `edits[]`) 잘라낸다.
    static func truncateKeys(_ value: JSONValue, keys: Set<String>, limit: Int) -> JSONValue {
        switch value {
        case .object(let object):
            var result: [String: JSONValue] = [:]
            for (key, field) in object {
                if keys.contains(key), case .string(let text) = field {
                    result[key] = .string(truncate(text, maxBytes: limit))
                } else {
                    result[key] = truncateKeys(field, keys: keys, limit: limit)
                }
            }
            return .object(result)
        case .array(let array):
            return .array(array.map { truncateKeys($0, keys: keys, limit: limit) })
        default:
            return value
        }
    }

    static func truncateAllStrings(_ value: JSONValue, limit: Int) -> JSONValue {
        switch value {
        case .string(let text):
            return .string(truncate(text, maxBytes: limit))
        case .object(let object):
            return .object(object.mapValues { truncateAllStrings($0, limit: limit) })
        case .array(let array):
            return .array(array.map { truncateAllStrings($0, limit: limit) })
        default:
            return value
        }
    }

    /// UTF-8 기준 maxBytes 이하로 자른다 (멀티바이트 문자 중간에서 끊지 않음).
    static func truncate(_ text: String, maxBytes: Int) -> String {
        let utf8 = text.utf8
        guard utf8.count > maxBytes else { return text }
        var end = utf8.index(utf8.startIndex, offsetBy: max(0, maxBytes))
        // UTF-8 연속 바이트(10xxxxxx)면 문자 시작까지 물러난다
        while end > utf8.startIndex, utf8[end] & 0xC0 == 0x80 {
            end = utf8.index(before: end)
        }
        return String(decoding: utf8[utf8.startIndex..<end], as: UTF8.self)
    }
}
