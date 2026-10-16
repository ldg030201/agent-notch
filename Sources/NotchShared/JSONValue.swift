import Foundation

/// 임의의 JSON 값을 타입 안전하게 다루기 위한 래퍼.
/// 훅 payload를 손실 없이 헬퍼 → 앱으로 전달하고, 앱에서 필요한 필드만 꺼내 쓸 때 사용한다.
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "지원하지 않는 JSON 값")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    // MARK: - 파싱 / 직렬화

    /// JSON 바이트 → 값.
    /// - repairingLoneSurrogates: 해석에 실패하면 짝 없는 UTF-16 서로게이트 이스케이프(`\uD83D` 만 있고 뒤가 없는 것 등)를
    ///   `�`(�)로 바꿔 한 번 더 해석한다. Node 의 `JSON.stringify` 는 이모지 중간에서 잘린 문자열을 그대로 이스케이프해서 내보내는데,
    ///   JSONDecoder 는 이런 글자 하나 때문에 payload 전체를 거부한다 (→ 세션 ID 까지 잃는다). 깨진 UTF-8 바이트도 대체 문자로 읽는다
    public static func parse(_ data: Data, repairingLoneSurrogates: Bool = true) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            guard repairingLoneSurrogates, let repaired = repairedForDecoding(data) else { throw error }
            return try JSONDecoder().decode(JSONValue.self, from: repaired)
        }
    }

    /// 문자열 안의 짝 없는 서로게이트 이스케이프 → `�`, 깨진 UTF-8 → U+FFFD. 고칠 게 없으면 nil.
    /// 문자열 밖 · `\\u` (역슬래시 글자 + u) 는 건드리지 않는다
    static func repairedForDecoding(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var changed = false
        var inString = false
        var index = 0
        let replacement = Array(#"�"#.utf8)

        /// `index` 에서 시작하는 `\uXXXX` 의 코드 유닛 (아니면 nil)
        func escapedUnit(at index: Int) -> UInt16? {
            guard index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else { return nil }
            var value: UInt16 = 0
            for byte in bytes[(index + 2)..<(index + 6)] {
                guard let digit = hexValue(byte) else { return nil }
                value = value << 4 | UInt16(digit)
            }
            return value
        }

        while index < bytes.count {
            let byte = bytes[index]
            guard inString else {
                if byte == UInt8(ascii: "\"") { inString = true }
                output.append(byte)
                index += 1
                continue
            }
            if byte == UInt8(ascii: "\"") {
                inString = false
                output.append(byte)
                index += 1
            } else if byte == UInt8(ascii: "\\"), index + 1 < bytes.count {
                if let unit = escapedUnit(at: index) {
                    if (0xD800...0xDBFF).contains(unit),
                       let low = escapedUnit(at: index + 6), (0xDC00...0xDFFF).contains(low) {
                        // 올바른 짝: 그대로
                        output.append(contentsOf: bytes[index..<(index + 12)])
                        index += 12
                    } else if (0xD800...0xDFFF).contains(unit) {
                        output.append(contentsOf: replacement)
                        changed = true
                        index += 6
                    } else {
                        output.append(contentsOf: bytes[index..<(index + 6)])
                        index += 6
                    }
                } else {
                    // 다른 이스케이프 (\" \\ \n …): 두 글자를 그대로 넘긴다
                    output.append(contentsOf: bytes[index...(index + 1)])
                    index += 2
                }
            } else {
                output.append(byte)
                index += 1
            }
        }

        // 깨진 UTF-8 은 대체 문자로 (디코딩해 보고 바이트가 달라졌으면 고친 것)
        let text = String(decoding: output, as: UTF8.self)
        if !text.utf8.elementsEqual(output) {
            return Data(text.utf8)
        }
        return changed ? Data(output) : nil
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// Swift 값 → JSON 값 (`JSONValue` · `String` · `Bool` · `Int` · `Double` · 배열 · `[String: Any]`, 그 밖의 값은 `null`).
    /// 데모 · 스냅숏처럼 payload 를 사전 리터럴로 적을 때 쓴다
    public init(any value: Any) {
        switch value {
        case let value as JSONValue: self = value
        case let value as String: self = .string(value)
        case let value as Bool: self = .bool(value)
        case let value as Int: self = .number(Double(value))
        case let value as Double: self = .number(value)
        case let value as [Any]: self = .array(value.map { JSONValue(any: $0) })
        case let value as [String: Any]: self = .object(value.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    public func serialized(sortedKeys: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = sortedKeys ? [.sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    // MARK: - 접근 헬퍼

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// 소수점 아래는 버린다. NaN · 무한대 · Int 범위 밖이면 nil (Int(Double) 트랩 방지)
    public var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(exactly: value.rounded(.towardZero))
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}
