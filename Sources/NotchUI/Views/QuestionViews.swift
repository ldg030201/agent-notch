import AppKit
import SwiftUI
import NotchCore

// MARK: - 질문 (AskUserQuestion)

/// 노치에서 답하는 질문 카드: 머리말 칩 + 질문, 선택지 행(이름 + 한 줄 설명), "기타" 직접 입력, 여러 질문이면 쪽 넘김.
/// - 한 개만 고르는 질문은 행을 누르면 답이 되어 다음 쪽으로 (마지막 쪽이면 바로 보낸다)
/// - 여러 개 고르는 질문은 행을 켜고 끈 뒤 "다음" · "보내기"
/// - 키: 1–4 선택지, ↩ 다음 · 보내기 (입력란이 아닐 때), ⎋ 접기
struct QuestionView: View {
    let request: PermissionRequestInfo
    let questions: [QuestionItem]
    let queueCount: Int
    let session: AgentSession?
    let layout: IslandLayout
    let presentation: PresentationController
    let reduceMotion: Bool

    var body: some View {
        let card = QuestionCardModel(questions: questions, cardWidth: layout.cardWidth)
        let host = SessionHost(session?.terminal)

        CardScaffold(layout: layout) {
            CardHeaderLeading(
                session: session,
                reduceMotion: reduceMotion,
                indicator: AnyView(PulsingDot(animated: !reduceMotion).frame(width: 8, height: 8))
            )
        } trailing: {
            Text(queueCount > 1 ? "답변 필요 · \(queueCount)" : "답변 필요")
                .foregroundStyle(Palette.amber)
        } content: {
            if let draft = presentation.questionDraft(for: request) {
                QuestionBody(
                    request: request,
                    draft: draft,
                    card: card,
                    host: host,
                    presentation: presentation
                )
            }
        }
    }
}

/// 질문 카드 본문 (답 상태를 관찰한다)
private struct QuestionBody: View {
    let request: PermissionRequestInfo
    let draft: QuestionDraft
    let card: QuestionCardModel
    let host: SessionHost
    let presentation: PresentationController

    var body: some View {
        let index = draft.page
        let question = draft.current

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: QuestionCardModel.chipGap) {
                Text(QuestionCardModel.chipText(question))
                    .font(IslandFont.caption)
                    .foregroundStyle(Palette.amber)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, QuestionCardModel.chipPadding)
                    .frame(height: IslandMetrics.lineHeight)
                    .background(Palette.row, in: Capsule())

                Text(QuestionCardModel.displayText(question.question))
                    .foregroundStyle(Palette.text)
                    .lineLimit(QuestionCardModel.maxQuestionLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: IslandMetrics.lineHeight, alignment: .topLeading)

                if draft.questions.count > 1 {
                    Text(verbatim: "\(index + 1)/\(draft.questions.count)")
                        .font(IslandFont.caption.monospacedDigit())
                        .foregroundStyle(Palette.muted)
                        .frame(width: QuestionCardModel.pageLabelWidth, height: IslandMetrics.lineHeight, alignment: .trailing)
                        .accessibilityLabel("질문 \(index + 1) / \(draft.questions.count)")
                }
            }
            .frame(height: CGFloat(card.questionLines) * IslandMetrics.lineHeight, alignment: .top)
            .padding(.bottom, QuestionCardModel.questionGap)

            VStack(alignment: .leading, spacing: QuestionCardModel.rowSpacing) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { option, item in
                    QuestionOptionRow(
                        number: option + 1,
                        option: item,
                        multiSelect: question.multiSelect,
                        selected: draft.isSelected(option, question: index),
                        height: QuestionCardModel.optionRowHeight(question)
                    ) {
                        presentation.requestAlertKey()
                        presentation.pickOption(option, in: request)
                    }
                }
                QuestionOtherRow(draft: draft, question: index) {
                    presentation.requestAlertKey()
                } onSubmit: {
                    presentation.advanceOrSubmit(request)
                }
            }
            .frame(height: card.choicesHeight, alignment: .top)

            HStack(spacing: 6) {
                if draft.questions.count > 1 {
                    Button {
                        presentation.requestAlertKey()
                        draft.go(to: index - 1)
                    } label: {
                        Text("이전")
                    }
                    .buttonStyle(IslandButtonStyle())
                    .disabled(index == 0)
                    .accessibilityLabel("이전 질문")
                }

                Spacer(minLength: 0)

                Button {
                    presentation.minimize(request)
                } label: {
                    Text("접기")
                }
                .buttonStyle(IslandButtonStyle())
                .accessibilityLabel("접기")
                .help("질문은 그대로 두고 접기 (⎋). 아일랜드를 누르면 다시 펼쳐짐")

                Button {
                    presentation.sendToTerminal(request)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: host.symbolName)
                        Text(host.jumpLabel)
                    }
                }
                .buttonStyle(IslandButtonStyle())
                .accessibilityLabel(host.jumpLabel)
                .help("\(host.placeName)에서 직접 답하기")

                Button {
                    presentation.advanceOrSubmit(request)
                } label: {
                    Text(draft.isLastPage ? "보내기 ↩" : "다음 ↩")
                }
                .buttonStyle(IslandButtonStyle(prominent: primaryEnabled))
                .disabled(!primaryEnabled)
                .accessibilityLabel(draft.isLastPage ? "보내기" : "다음 질문")
                .help(primaryHelp)
            }
            .padding(.top, 12)
        }
        .font(IslandFont.body)
        .padding(.horizontal, IslandMetrics.bodyPadding)
        .padding(.top, IslandMetrics.bodyTop)
        .padding(.bottom, 14)
    }

    private var primaryEnabled: Bool {
        draft.isLastPage ? draft.allAnswered : draft.isAnswered(draft.page)
    }

    private var primaryHelp: String {
        if draft.isLastPage {
            return draft.allAnswered ? "답 보내기 (↩)" : "모든 질문에 답하면 보낼 수 있음"
        }
        return "다음 질문 (↩)"
    }
}

/// 선택지 행: 번호(여러 개 고르면 확인란) + 이름 + 한 줄 설명
private struct QuestionOptionRow: View {
    let number: Int
    let option: QuestionOption
    let multiSelect: Bool
    let selected: Bool
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                QuestionMark(number: number, multiSelect: multiSelect, selected: selected)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(QuestionCardModel.displayText(option.displayLabel))
                            .font(IslandFont.bodyMedium)
                            .foregroundStyle(Palette.text)
                        // Claude 앱 질문 창의 "(Recommended)" 를 같은 뜻의 배지로 (이름이 길면 이름부터 줄인다)
                        if option.isRecommended {
                            RecommendedBadge()
                        }
                    }
                    if let description = option.description {
                        Text(QuestionCardModel.displayText(description))
                            .font(IslandFont.caption)
                            .foregroundStyle(Palette.secondary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(QuestionRowBackground(selected: selected))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(number <= 4 ? "\(number) 키로도 고를 수 있음" : "")
    }
}

extension QuestionOptionRow {
    private var spokenLabel: String {
        var parts = [option.displayLabel]
        if option.isRecommended { parts.append("권장") }
        if let description = option.description { parts.append(description) }
        return parts.joined(separator: ", ")
    }
}

/// 권장 선택지 배지
private struct RecommendedBadge: View {
    var body: some View {
        Text("권장")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.green)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Palette.green.opacity(0.16), in: Capsule())
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// "기타" 행: 직접 쓴 답 (한 개만 고르는 질문이면 쓰는 순간 선택지 대신 이 답).
/// "기타" 를 누르면 패널을 키 윈도우로 만들고 입력란에 커서를 둔다
private struct QuestionOtherRow: View {
    let draft: QuestionDraft
    let question: Int
    /// 패널을 키 윈도우로 (글자 입력)
    let requestKey: () -> Void
    let onSubmit: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        let selected = draft.otherSelected[question]
        let multiSelect = draft.questions[question].multiSelect
        HStack(spacing: 8) {
            Button {
                requestKey()
                draft.toggleOther(question: question)
                // 키 윈도우가 된 다음 틱에 커서를 둔다
                if draft.otherSelected[question] {
                    DispatchQueue.main.async { fieldFocused = true }
                }
            } label: {
                HStack(spacing: 8) {
                    QuestionMark(number: nil, multiSelect: multiSelect, selected: selected)
                    Text("기타")
                        .font(IslandFont.bodyMedium)
                        .foregroundStyle(Palette.text)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("기타")
            .accessibilityAddTraits(selected ? .isSelected : [])

            QuestionOtherField(draft: draft, question: question, onSubmit: onSubmit)
                .focused($fieldFocused)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: QuestionCardModel.otherRowHeight, maxHeight: QuestionCardModel.otherRowHeight, alignment: .leading)
        .background(QuestionRowBackground(selected: selected))
    }
}

/// "기타" 입력란. 실제 패널은 글자 입력(AppKit), 스냅숏은 같은 자리의 그림 (오프스크린 렌더링은 입력란을 그리지 못한다)
private struct QuestionOtherField: View {
    let draft: QuestionDraft
    let question: Int
    let onSubmit: () -> Void

    @Environment(\.islandRenderContext) private var renderContext

    var body: some View {
        let text = draft.otherTexts[question]
        if renderContext.isSnapshot {
            Text(text.isEmpty ? Self.placeholder : text)
                .font(IslandFont.body)
                .foregroundStyle(text.isEmpty ? Palette.muted : Palette.text)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(
                "",
                text: Binding(
                    get: { draft.otherTexts[question] },
                    set: { draft.setOtherText($0, question: question) }
                ),
                prompt: Text(Self.placeholder).foregroundStyle(Palette.muted)
            )
            .textFieldStyle(.plain)
            .font(IslandFont.body)
            .foregroundStyle(Palette.text)
            // 아일랜드는 늘 검은 배경: 글자 · 커서를 밝게
            .environment(\.colorScheme, .dark)
            .onSubmit(onSubmit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("기타 답 입력")
        }
    }

    static let placeholder = "직접 입력"
}

/// 선택 표시: 한 개만 고르면 번호 원, 여러 개면 확인란. 고르면 초록
private struct QuestionMark: View {
    /// nil 이면 "기타" (연필)
    let number: Int?
    let multiSelect: Bool
    let selected: Bool

    var body: some View {
        ZStack {
            if multiSelect {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(selected ? Palette.green : Color.clear)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(selected ? Palette.green : Palette.muted, lineWidth: 1)
            } else {
                Circle().fill(selected ? Palette.green : Color.clear)
                Circle().strokeBorder(selected ? Palette.green : Palette.muted, lineWidth: 1)
            }
            if selected, multiSelect {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.allowText)
            } else if let number {
                Text(verbatim: "\(number)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(selected ? Palette.allowText : Palette.secondary)
            } else {
                Image(systemName: "pencil")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(selected ? Palette.allowText : Palette.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// 선택지 행 배경 (고르면 테두리)
private struct QuestionRowBackground: View {
    let selected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        shape
            .fill(Palette.row.opacity(selected ? 1 : 0.55))
            .overlay {
                if selected { shape.strokeBorder(Palette.green.opacity(0.75), lineWidth: 1) }
            }
    }
}

// MARK: - 계획 승인 (ExitPlanMode)

/// 노치에서 승인하는 계획 카드: 계획 제목 + 앞쪽 몇 줄, 계획 파일 열기, [접기] [터미널로] [승인]
struct PlanApprovalView: View {
    let request: PermissionRequestInfo
    let plan: PlanInfo
    let queueCount: Int
    let session: AgentSession?
    let layout: IslandLayout
    let presentation: PresentationController
    let reduceMotion: Bool

    var body: some View {
        let card = PlanCardModel(plan: plan)
        let host = SessionHost(session?.terminal)

        CardScaffold(layout: layout) {
            CardHeaderLeading(
                session: session,
                reduceMotion: reduceMotion,
                indicator: AnyView(PulsingDot(animated: !reduceMotion).frame(width: 8, height: 8))
            )
        } trailing: {
            Text(queueCount > 1 ? "승인 필요 · \(queueCount)" : "승인 필요")
                .foregroundStyle(Palette.amber)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: QuestionCardModel.chipGap) {
                    Text("계획")
                        .font(IslandFont.caption)
                        .foregroundStyle(Palette.amber)
                        .fixedSize()
                        .padding(.horizontal, QuestionCardModel.chipPadding)
                        .frame(height: IslandMetrics.lineHeight)
                        .background(Palette.row, in: Capsule())
                    Text(card.title)
                        .font(IslandFont.bodyMedium)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(height: IslandMetrics.lineHeight)

                if !card.previewLines.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(card.previewLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(height: IslandMetrics.scopeLineHeight)
                        }
                    }
                    .font(IslandFont.caption)
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, IslandMetrics.detailHorizontalPadding)
                    .padding(.vertical, IslandMetrics.detailVerticalPadding)
                    .background(Palette.row, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 6)
                }

                HStack(spacing: 5) {
                    Image(systemName: "doc.text")
                    Text(card.note)
                        .truncationMode(.middle)
                    if let path = card.filePath {
                        Button {
                            presentation.actions.openFile(path: path, line: nil)
                        } label: {
                            Text("파일 열기")
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.secondary)
                        .accessibilityLabel("계획 파일 열기")
                        .help("전체 계획을 편집기로 열기")
                    }
                }
                .font(IslandFont.caption)
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .frame(height: IslandMetrics.permissionNoteHeight)
                .padding(.top, IslandMetrics.permissionNoteGap)

                HStack(spacing: 6) {
                    Spacer(minLength: 0)

                    Button {
                        presentation.minimize(request)
                    } label: {
                        Text("접기")
                    }
                    .buttonStyle(IslandButtonStyle())
                    .accessibilityLabel("접기")
                    .help("승인 요청은 그대로 두고 접기 (⎋). 아일랜드를 누르면 다시 펼쳐짐")

                    Button {
                        presentation.sendToTerminal(request)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: host.symbolName)
                            Text(host.jumpLabel)
                        }
                    }
                    .buttonStyle(IslandButtonStyle())
                    .accessibilityLabel(host.jumpLabel)
                    .help("\(host.placeName)에서 직접 결정 (다른 승인 방식 · 계획 고치기)")

                    Button {
                        presentation.approvePlan(request)
                    } label: {
                        Text("승인 ⌘↩")
                    }
                    .buttonStyle(IslandButtonStyle(prominent: true))
                    .accessibilityLabel("계획 승인")
                    .help("계획 승인 (↩ · ⌘↩)")
                }
                .padding(.top, 12)
            }
            .font(IslandFont.body)
            .padding(.horizontal, IslandMetrics.bodyPadding)
            .padding(.top, IslandMetrics.bodyTop)
            .padding(.bottom, 14)
        }
    }
}
