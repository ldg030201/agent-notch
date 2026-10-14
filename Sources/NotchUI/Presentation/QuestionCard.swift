import AppKit
import Observation
import NotchCore

// MARK: - 질문 카드 (AskUserQuestion)

/// 질문 카드에서 고르는 중인 답. 요청마다 하나 (`PresentationController.questionDraft(for:)`),
/// 카드를 접거나 다른 화면에서 다시 그려도 그대로 남는다. 답 글자는 메모리에만 둔다.
@MainActor
@Observable
final class QuestionDraft {
    let questions: [QuestionItem]
    /// 지금 보이는 질문 (여러 개면 쪽 넘김)
    private(set) var page = 0
    /// 질문별 고른 선택지 위치
    private(set) var selections: [Set<Int>]
    /// 질문별 "기타" 를 골랐는지
    private(set) var otherSelected: [Bool]
    /// 질문별 "기타" 에 쓴 글자
    private(set) var otherTexts: [String]

    init(questions: [QuestionItem]) {
        self.questions = questions
        selections = Array(repeating: [], count: questions.count)
        otherSelected = Array(repeating: false, count: questions.count)
        otherTexts = Array(repeating: "", count: questions.count)
    }

    var current: QuestionItem { questions[page] }
    var isLastPage: Bool { page >= questions.count - 1 }

    func isSelected(_ option: Int, question: Int) -> Bool {
        selections.indices.contains(question) && selections[question].contains(option)
    }

    /// 선택지를 고른다. 한 개만 고르는 질문이면 그것만 남기고 "기타" 는 끈다. 여러 개면 켜고 끈다
    func pick(_ option: Int, question: Int) {
        guard questions.indices.contains(question), questions[question].options.indices.contains(option) else { return }
        if questions[question].multiSelect {
            if selections[question].contains(option) {
                selections[question].remove(option)
            } else {
                selections[question].insert(option)
            }
        } else {
            selections[question] = [option]
            otherSelected[question] = false
        }
    }

    /// "기타" 를 고른다 (한 개만 고르는 질문이면 선택지를 비운다). 여러 개 고르는 질문이면 켜고 끈다
    func toggleOther(question: Int) {
        guard questions.indices.contains(question) else { return }
        if questions[question].multiSelect {
            otherSelected[question].toggle()
        } else {
            otherSelected[question] = true
            selections[question] = []
        }
    }

    /// "기타" 글자 입력: 글자가 생기면 "기타" 를 고른 것으로 (한 개만 고르는 질문이면 선택지를 비운다), 다 지우면 끈다
    func setOtherText(_ text: String, question: Int) {
        guard questions.indices.contains(question) else { return }
        otherTexts[question] = text
        let filled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if filled {
            otherSelected[question] = true
            if !questions[question].multiSelect { selections[question] = [] }
        } else if otherSelected[question] {
            otherSelected[question] = false
        }
    }

    func go(to page: Int) {
        guard questions.indices.contains(page), page != self.page else { return }
        self.page = page
    }

    func answer(_ question: Int) -> QuestionAnswer {
        let item = questions[question]
        let labels = item.options.indices.filter { selections[question].contains($0) }.map { item.options[$0].label }
        return QuestionAnswer(labels: labels, otherText: otherSelected[question] ? otherTexts[question] : nil)
    }

    func isAnswered(_ question: Int) -> Bool {
        guard questions.indices.contains(question) else { return false }
        return answer(question).value != nil
    }

    var allAnswered: Bool { questions.indices.allSatisfy(isAnswered) }

    /// 모든 질문에 답했을 때만 답 목록 (질문 순서대로)
    var answers: [QuestionAnswer]? {
        allAnswered ? questions.indices.map(answer) : nil
    }

    /// 지금 쪽 다음의 아직 답하지 않은 질문 (없으면 앞쪽에서)
    var nextUnanswered: Int? {
        let order = Array(questions.indices.dropFirst(page + 1)) + Array(questions.indices.prefix(page))
        return order.first { !isAnswered($0) }
    }
}

/// 질문 카드에 무엇을 얼마나 보여줄지. 레이아웃(높이)과 뷰가 같은 값을 쓴다.
/// 카드 높이는 모든 질문 중 가장 큰 쪽에 맞춰 쪽을 넘겨도 카드 크기가 바뀌지 않는다.
struct QuestionCardModel {
    /// 이름만 있는 선택지 행 · 설명이 있는 선택지 행 높이, 행 사이
    static let rowHeight: CGFloat = 26
    static let detailRowHeight: CGFloat = 38
    static let rowSpacing: CGFloat = 4
    /// "기타" 행 높이
    static let otherRowHeight: CGFloat = 28
    /// 질문 글 → 선택지 사이
    static let questionGap: CGFloat = 8
    /// 질문 글 최대 줄 수
    static let maxQuestionLines = 2
    /// 머리말 칩 좌우 여백 · 칩과 질문 글 사이
    static let chipPadding: CGFloat = 6
    static let chipGap: CGFloat = 8
    /// 쪽 표시("1/2") 폭
    static let pageLabelWidth: CGFloat = 28

    /// 질문 글 줄 수 (모든 질문 중 최대)
    let questionLines: Int
    /// 선택지 + 기타 행 높이 (모든 질문 중 최대)
    let choicesHeight: CGFloat

    @MainActor
    init(questions: [QuestionItem], cardWidth: CGFloat) {
        typealias M = IslandMetrics
        let content = cardWidth - M.bodyPadding * 2
        var lines = 1
        var choices: CGFloat = 0
        for question in questions {
            var width = content - Self.chipWidth(question) - Self.chipGap
            if questions.count > 1 { width -= Self.pageLabelWidth + Self.chipGap }
            let measured = TextMeasure.lineCount(
                Self.displayText(question.question), font: IslandFont.bodyNS, lineHeight: M.bodyLineHeight,
                width: max(40, width - IslandFont.monoCharWidth), maxLines: Self.maxQuestionLines
            )
            lines = max(lines, measured)
            choices = max(choices, Self.choicesHeight(question))
        }
        questionLines = lines
        choicesHeight = choices
    }

    /// 카드 본문 높이 (상단 행 제외)
    var bodyHeight: CGFloat {
        typealias M = IslandMetrics
        return M.bodyTop + CGFloat(questionLines) * M.lineHeight + Self.questionGap + choicesHeight + 12 + M.buttonHeight + 14
    }

    /// 선택지 행 높이 (설명이 하나라도 있으면 모든 행이 두 줄)
    static func optionRowHeight(_ question: QuestionItem) -> CGFloat {
        question.options.contains { $0.description != nil } ? detailRowHeight : rowHeight
    }

    static func choicesHeight(_ question: QuestionItem) -> CGFloat {
        let rows = CGFloat(question.options.count)
        return rows * optionRowHeight(question) + rows * rowSpacing + otherRowHeight
    }

    /// 머리말 칩 폭 (머리말이 없으면 "질문")
    @MainActor
    static func chipWidth(_ question: QuestionItem) -> CGFloat {
        CompactText.width(chipText(question), font: IslandFont.captionNS) + chipPadding * 2
    }

    static func chipText(_ question: QuestionItem) -> String {
        displayText(question.header ?? "질문")
    }

    /// 카드에 보일 글 (줄바꿈 · 연속 공백을 한 칸으로)
    static func displayText(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

// MARK: - 계획 승인 카드 (ExitPlanMode)

/// 계획 승인 카드 내용: 첫 줄(제목) + 다음 몇 줄 미리보기. 전체는 계획 파일에서 본다
struct PlanCardModel {
    /// 제목 아래 미리보기 최대 줄 수
    static let maxPreviewLines = 5

    let title: String
    let previewLines: [String]
    /// 비어 있지 않은 전체 줄 수
    let totalLines: Int
    let fileName: String?
    let filePath: String?

    init(plan: PlanInfo) {
        let lines = plan.previewLines(max: Self.maxPreviewLines + 1)
        title = lines.first ?? "계획"
        previewLines = Array(lines.dropFirst())
        totalLines = plan.lineCount
        filePath = plan.filePath
        fileName = plan.filePath.map { ($0 as NSString).lastPathComponent }
    }

    /// 카드 본문 높이 (상단 행 제외)
    var bodyHeight: CGFloat {
        typealias M = IslandMetrics
        let box = previewLines.isEmpty ? 0 : 6 + CGFloat(previewLines.count) * M.scopeLineHeight + M.detailVerticalPadding * 2
        let note = M.permissionNoteGap + M.permissionNoteHeight
        return M.bodyTop + M.lineHeight + box + note + 12 + M.buttonHeight + 14
    }

    /// 카드 아래 안내: "plan.md · 42줄" (파일이 없으면 줄 수만)
    var note: String {
        let lines = "\(totalLines)줄"
        guard let fileName else { return "계획 \(lines)" }
        return "\(fileName) · \(lines)"
    }
}
