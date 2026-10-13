import Foundation
import NotchShared

// MARK: - 노치에서 답하는 툴 (질문 · 계획 승인)

/// 훅이 노치의 결정을 기다리는 요청 종류
public enum HookRequestKind: Hashable, Sendable {
    /// PermissionRequest: 툴 실행 허용 · 거부
    case permission
    /// AskUserQuestion 의 PreToolUse: 노치에서 답을 고른다 (질문 순서대로)
    case question([QuestionItem])
    /// ExitPlanMode 의 PreToolUse: 노치에서 계획을 승인한다
    case plan(PlanInfo)
}

/// AskUserQuestion 질문 하나
public struct QuestionItem: Hashable, Sendable {
    /// 질문 원문. 답(`answers`)의 키라서 고치지 않는다
    public var question: String
    /// 짧은 머리말 (12자 이내, 카드의 칩)
    public var header: String?
    public var options: [QuestionOption]
    /// 여러 개 고를 수 있는지 (답은 선택지 이름을 쉼표로 잇는다)
    public var multiSelect: Bool

    public init(question: String, header: String? = nil, options: [QuestionOption], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

/// 질문의 선택지
public struct QuestionOption: Hashable, Sendable {
    /// 선택지 이름. 고르면 이 문자열이 그대로 답이 된다
    public var label: String
    /// 한 줄 설명
    public var description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }

    /// Claude 가 권장하는 선택지인지 (이름 끝의 "(Recommended)" · "(권장)" · "(추천)").
    /// Claude 앱 질문 창처럼 노치 카드에도 표시한다
    public var isRecommended: Bool { Self.recommendedSuffixRange(in: label) != nil }

    /// 카드에 보여줄 이름: 권장 표시를 뗀 이름 (권장 여부는 배지로 따로 보여준다). 답은 늘 원래 `label` 그대로 보낸다
    public var displayLabel: String {
        guard let range = Self.recommendedSuffixRange(in: label) else { return label }
        let trimmed = label[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? label : trimmed
    }

    /// 이름 끝의 권장 표시 범위 (대소문자 무시, 앞 공백 허용)
    static func recommendedSuffixRange(in label: String) -> Range<String.Index>? {
        // 끝 공백만 떼고 찾는다 (Substring 이라 찾은 범위가 원래 문자열 인덱스 그대로다)
        var end = label.endIndex
        while end > label.startIndex, label[label.index(before: end)].isWhitespace {
            end = label.index(before: end)
        }
        let text = label[..<end]
        for marker in recommendedMarkers {
            if let range = text.range(of: marker, options: [.caseInsensitive, .backwards, .anchored]) {
                return range.lowerBound..<label.endIndex
            }
        }
        return nil
    }

    static let recommendedMarkers = ["(Recommended)", "(권장)", "(추천)"]
}

/// ExitPlanMode 계획 (Claude Code 가 계획 파일 내용과 경로를 훅 입력에 넣어 준다)
public struct PlanInfo: Hashable, Sendable {
    /// 계획 전문 (마크다운, 메모리에만 둔다)
    public var plan: String
    public var filePath: String?

    public init(plan: String, filePath: String? = nil) {
        self.plan = plan
        self.filePath = filePath
    }

    /// 카드에 보여줄 앞쪽 줄 (빈 줄 · 마크다운 제목 기호 제거, 한 줄로 정리)
    public func previewLines(max count: Int) -> [String] {
        var lines: [String] = []
        for raw in plan.split(whereSeparator: \.isNewline) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                .trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            lines.append(TextUtils.collapseWhitespace(trimmed))
            if lines.count == count { break }
        }
        return lines
    }

    /// 비어 있지 않은 줄 수
    public var lineCount: Int {
        plan.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }
}

/// 질문 하나의 답
public struct QuestionAnswer: Hashable, Sendable {
    /// 고른 선택지 이름 (선택지 순서대로)
    public var labels: [String]
    /// "기타" 에 직접 쓴 답 (없으면 nil)
    public var otherText: String?

    public init(labels: [String] = [], otherText: String? = nil) {
        self.labels = labels
        self.otherText = otherText
    }

    /// Claude Code 에 넘길 답: 선택지 이름(여럿이면 쉼표로 잇는다) 뒤에 직접 쓴 답. 비었으면 nil
    public var value: String? {
        var parts = labels.filter { !$0.isEmpty }
        if let other = otherText?.trimmingCharacters(in: .whitespacesAndNewlines), !other.isEmpty {
            parts.append(other)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// 질문 · 계획 승인 툴 입력 해석. 노치에서 답할 수 없는 모양이면 nil → 훅은 결정 없이 끝나 Claude Code 다이얼로그로 답한다
public enum InteractionParser {
    /// 한 번에 묻는 질문 · 질문당 선택지 최대 개수 (AskUserQuestion 규격: 질문 1–4, 선택지 2–4)
    public static let maxQuestions = 4
    public static let maxOptions = 4

    /// 툴 이름 · 입력 → 요청 종류 (질문 · 계획 승인이 아니거나 해석할 수 없으면 nil)
    public static func kind(toolName: String, toolInput: JSONValue?) -> HookRequestKind? {
        switch toolName {
        case "AskUserQuestion": return questions(from: toolInput).map(HookRequestKind.question)
        case "ExitPlanMode": return plan(from: toolInput).map(HookRequestKind.plan)
        default: return nil
        }
    }

    /// AskUserQuestion `tool_input.questions`. 질문 · 선택지 개수가 규격 밖이거나, 질문 원문이 비었거나 겹치면 nil
    /// (답은 질문 원문을 키로 쓰므로 겹치면 어느 질문의 답인지 알 수 없다)
    public static func questions(from toolInput: JSONValue?) -> [QuestionItem]? {
        guard let items = toolInput?["questions"]?.arrayValue, (1...maxQuestions).contains(items.count) else { return nil }
        var result: [QuestionItem] = []
        for item in items {
            guard let question = item["question"]?.stringValue,
                  TextUtils.nonEmpty(question.trimmingCharacters(in: .whitespacesAndNewlines)) != nil,
                  !result.contains(where: { $0.question == question }),
                  let rawOptions = item["options"]?.arrayValue,
                  (1...maxOptions).contains(rawOptions.count)
            else { return nil }
            var options: [QuestionOption] = []
            for raw in rawOptions {
                guard let label = raw["label"]?.stringValue,
                      TextUtils.nonEmpty(label.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
                else { return nil }
                options.append(QuestionOption(label: label, description: TextUtils.nonEmpty(raw["description"]?.stringValue)))
            }
            result.append(QuestionItem(
                question: question,
                header: TextUtils.nonEmpty(item["header"]?.stringValue),
                options: options,
                multiSelect: item["multiSelect"]?.boolValue ?? false
            ))
        }
        return result
    }

    /// ExitPlanMode 의 계획 (Claude Code 가 넣어 준 `plan` · `planFilePath`). 계획 내용이 없으면 nil (보지 못한 계획은 승인하지 않는다)
    public static func plan(from toolInput: JSONValue?) -> PlanInfo? {
        guard let plan = toolInput?["plan"]?.stringValue,
              !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return PlanInfo(plan: plan, filePath: TextUtils.nonEmpty(toolInput?["planFilePath"]?.stringValue))
    }
}
