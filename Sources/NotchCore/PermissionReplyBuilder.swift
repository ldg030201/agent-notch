import Foundation
import NotchShared

/// 사용자 결정을 PermissionRequest 훅 출력 JSON 으로 변환한다.
/// 반환값이 nil 이면 훅은 아무것도 출력하지 않는다 (= Claude Code 기본 권한 프롬프트로 넘김).
///
/// NOTE: 공개 시그니처는 NotchServices/App 이 의존하는 계약이므로 변경하지 않는다.
public enum PermissionReplyBuilder {
    /// 거부 메시지가 없을 때 Claude 에게 전달할 기본 문구
    static let defaultDenyMessage = "AgentNotch 에서 거부됨"

    public static func output(for request: PermissionRequestInfo, decision: PermissionDecision) -> JSONValue? {
        var body: [String: JSONValue]
        switch decision {
        case .allow:
            body = ["behavior": .string("allow")]
        case .allowAlways:
            body = ["behavior": .string("allow")]
            // 제안된 권한 규칙이 있을 때만 적용 (없으면 일반 허용)
            if canAllowAlways(request), let suggestions = request.suggestions {
                body["updatedPermissions"] = suggestions
            }
        case .deny(let message):
            let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            body = [
                "behavior": .string("deny"),
                "message": .string(TextUtils.nonEmpty(trimmed) ?? defaultDenyMessage),
            ]
        case .passthrough:
            return nil
        }
        return .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("PermissionRequest"),
                "decision": .object(body),
            ]),
        ])
    }

    /// "항상 허용" 이 실제로 규칙을 적용하는지 (`permission_suggestions` 가 비어 있지 않은 배열일 때만)
    public static func canAllowAlways(_ request: PermissionRequestInfo) -> Bool {
        request.suggestions?.arrayValue.map { !$0.isEmpty } ?? false
    }

    /// 카드의 상세가 승인 대상 전체를 보여주지 못하는지 (글자 수 제한으로 잘림 · 카드 줄 수 초과).
    /// 이때는 노치에서 허용하지 않고 터미널에서 확인하게 한다.
    public static func isDetailClipped(_ request: PermissionRequestInfo, measuredLines: Int, visibleLines: Int) -> Bool {
        request.isDetailTruncated || measuredLines > visibleLines
    }

    // MARK: - 항상 허용 범위

    /// "항상 허용" 이 적용할 규칙을 한 줄씩 읽을 수 있게 (카드 표시용). 적용할 규칙이 없으면 빈 배열.
    /// - addRules → "Bash(npm run test:*) · 이 프로젝트 (로컬 설정)"
    /// - setMode → "모드 → acceptEdits (이번 세션만)"
    /// - addDirectories → "디렉터리 추가: /Users/dev/shared · 이번 세션만"
    /// - 그 밖 → 한 줄 JSON
    public static func scopeSummary(_ suggestions: JSONValue?) -> [String] {
        guard let items = suggestions?.arrayValue, !items.isEmpty else { return [] }
        return items.map { item in
            TextUtils.revealInvisibles(TextUtils.truncate(describe(item), max: maxScopeLineCharacters), keepLineBreaks: false)
        }
    }

    /// 범위 한 줄 최대 길이
    static let maxScopeLineCharacters = 300

    private static func describe(_ item: JSONValue) -> String {
        let destination = item["destination"]?.stringValue.map(destinationLabel)
        func withDestination(_ text: String) -> String {
            guard let destination else { return text }
            return "\(text) · \(destination)"
        }

        switch item["type"]?.stringValue {
        case "addRules", "replaceRules", "removeRules":
            guard let rules = item["rules"]?.arrayValue, !rules.isEmpty else { break }
            var text = rules.map(ruleText).joined(separator: ", ")
            if let behavior = item["behavior"]?.stringValue, behavior != "allow" {
                text += " (\(behaviorLabel(behavior)))"
            }
            switch item["type"]?.stringValue {
            case "replaceRules": text = "규칙 교체: " + text
            case "removeRules": text = "규칙 제거: " + text
            default: break
            }
            return withDestination(text)
        case "setMode":
            guard let mode = item["mode"]?.stringValue else { break }
            return destination.map { "모드 → \(mode) (\($0))" } ?? "모드 → \(mode)"
        case "addDirectories", "removeDirectories":
            let paths = (item["directories"]?.arrayValue ?? []).compactMap(\.stringValue)
            guard !paths.isEmpty else { break }
            let verb = item["type"]?.stringValue == "addDirectories" ? "디렉터리 추가" : "디렉터리 제거"
            return withDestination("\(verb): " + paths.joined(separator: ", "))
        default:
            break
        }
        return TextUtils.compactJSON(item)
    }

    /// {"toolName":"Bash","ruleContent":"npm test:*"} → "Bash(npm test:*)"
    private static func ruleText(_ rule: JSONValue) -> String {
        let tool = rule["toolName"]?.stringValue ?? "?"
        guard let content = rule["ruleContent"]?.stringValue, !content.isEmpty else { return tool }
        return "\(tool)(\(content))"
    }

    private static func destinationLabel(_ destination: String) -> String {
        switch destination {
        case "session": return "이번 세션만"
        case "localSettings": return "이 프로젝트 (로컬 설정)"
        case "projectSettings": return "이 프로젝트 (공유 설정)"
        case "userSettings": return "모든 프로젝트 (사용자 설정)"
        default: return destination
        }
    }

    private static func behaviorLabel(_ behavior: String) -> String {
        switch behavior {
        case "deny": return "거부 규칙"
        case "ask": return "확인 규칙"
        default: return behavior
        }
    }
}
