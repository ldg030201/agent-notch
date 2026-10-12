import Foundation
import NotchShared

/// 사용자 결정을 PermissionRequest 훅 출력 JSON 으로 변환한다.
/// 반환값이 nil 이면 훅은 아무것도 출력하지 않는다 (= Claude Code 기본 권한 프롬프트로 넘김).
///
/// NOTE: 공개 시그니처는 NotchServices/App 이 의존하는 계약이므로 변경하지 않는다.
public enum PermissionReplyBuilder {
    public static func output(for request: PermissionRequestInfo, decision: PermissionDecision) -> JSONValue? {
        // TODO: NotchCore 구현 단계에서 채움
        nil
    }
}
