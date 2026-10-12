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
            if let suggestions = request.suggestions, let items = suggestions.arrayValue, !items.isEmpty {
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
}
