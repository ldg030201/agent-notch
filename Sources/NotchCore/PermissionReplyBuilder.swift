import Foundation
import NotchShared

/// 사용자 결정을 훅 출력 JSON 으로 변환한다.
/// - 권한 요청: PermissionRequest 의 `decision`
/// - 질문 · 계획 승인: PreToolUse 의 `permissionDecision: "allow"` + `updatedInput` (원래 입력 + 답)
/// 반환값이 nil 이면 훅은 아무것도 출력하지 않는다 (= Claude Code 기본 프롬프트 · 다이얼로그로 넘김).
///
/// NOTE: 공개 시그니처는 NotchServices/App 이 의존하는 계약이므로 변경하지 않는다.
public enum PermissionReplyBuilder {
    /// 거부 메시지가 없을 때 Claude 에게 전달할 기본 문구
    static let defaultDenyMessage = "AgentNotch 에서 거부됨"

    public static func output(for request: PermissionRequestInfo, decision: PermissionDecision) -> JSONValue? {
        switch request.kind {
        case .permission: return permissionOutput(decision: decision, request: request)
        case .question(let questions): return questionOutput(request, questions: questions, decision: decision)
        case .plan: return planOutput(request, decision: decision)
        }
    }

    /// 실제로 훅에 전달되는 결정. 출력을 만들 수 없는 결정(질문에 답 없이 허용, 답 개수가 다름 등)은 결정 없음으로 본다
    public static func effectiveDecision(for request: PermissionRequestInfo, decision: PermissionDecision) -> PermissionDecision {
        output(for: request, decision: decision) == nil ? .passthrough : decision
    }

    private static func permissionOutput(decision: PermissionDecision, request: PermissionRequestInfo) -> JSONValue? {
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
        case .passthrough, .answer:
            return nil
        }
        return .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("PermissionRequest"),
                "decision": .object(body),
            ]),
        ])
    }

    // MARK: - 질문 · 계획 승인 (PreToolUse)

    /// AskUserQuestion: 원래 입력(`questions` 등)을 그대로 두고 `answers` 에 질문 원문 → 답을 넣는다.
    /// 답이 빠졌거나, 한 개만 고르는 질문에 답이 둘 이상이면 nil (다이얼로그로 넘긴다)
    private static func questionOutput(
        _ request: PermissionRequestInfo,
        questions: [QuestionItem],
        decision: PermissionDecision
    ) -> JSONValue? {
        guard case .answer(let answers) = decision, answers.count == questions.count,
              var input = request.toolInput.objectValue else { return nil }
        var map: [String: JSONValue] = [:]
        for (question, answer) in zip(questions, answers) {
            guard let value = answer.value else { return nil }
            if !question.multiSelect {
                let hasOther = answer.otherText.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
                guard answer.labels.count + (hasOther ? 1 : 0) == 1 else { return nil }
            }
            map[question.question] = .string(value)
        }
        input["answers"] = .object(map)
        return preToolUseAllow(updatedInput: .object(input))
    }

    /// ExitPlanMode: 승인(`.allow`)이면 Claude Code 가 넣어 준 입력(계획 · 경로)을 그대로 돌려준다
    private static func planOutput(_ request: PermissionRequestInfo, decision: PermissionDecision) -> JSONValue? {
        guard decision == .allow, request.toolInput.objectValue != nil else { return nil }
        return preToolUseAllow(updatedInput: request.toolInput)
    }

    /// 사용자 상호작용 툴은 `allow` 만으로는 실행되지 않고 답을 담은 `updatedInput` 이 함께 있어야 한다
    private static func preToolUseAllow(updatedInput: JSONValue) -> JSONValue {
        .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("PreToolUse"),
                "permissionDecision": .string("allow"),
                "updatedInput": updatedInput,
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
