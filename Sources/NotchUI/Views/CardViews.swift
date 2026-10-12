import SwiftUI
import NotchCore

// MARK: - peek (파일 수정 미니 diff)

struct PeekView: View {
    let session: AgentSession?
    let diff: DiffSnippet
    let textLine: String?
    let geometry: NotchGeometry
    let headerHeight: CGFloat
    let actions: IslandActions
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 0) {
            CardHeader(session: session, geometry: geometry, height: headerHeight, reduceMotion: reduceMotion) {
                HStack(spacing: 6) {
                    Text(toolName)
                    DiffStatText(added: diff.added, removed: diff.removed)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Button {
                        actions.openFile(path: diff.filePath, line: diff.startLine)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(Palette.secondary)
                            Text(DiffPresentation.displayPath(diff, cwd: session?.cwd))
                                .truncationMode(.middle)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(diff.fileName) 열기")

                    Spacer(minLength: 8)
                    if let line = diff.startLine {
                        Text(verbatim: "L\(line)")
                            .foregroundStyle(Palette.muted)
                    }
                }
                .frame(height: IslandMetrics.lineHeight)
                .padding(.bottom, 6)

                DiffRowsView(lines: DiffPresentation.visibleLines(diff))

                if let textLine {
                    Text(textLine)
                        .foregroundStyle(Palette.secondary)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: IslandMetrics.lineHeight)
                        .padding(.top, 8)
                }
            }
            .font(IslandFont.body)
            .foregroundStyle(Palette.text)
            .lineLimit(1)
            .padding(.horizontal, IslandMetrics.bodyPadding)
            .padding(.top, IslandMetrics.bodyTop)
            .padding(.bottom, IslandMetrics.bodyBottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 이 diff 를 만든 툴 이름 (모르면 Edit)
    private var toolName: String {
        let activity = session?.activities.last { $0.diff == diff }
        if let name = activity?.toolName, !name.isEmpty, !name.hasPrefix("mcp__") { return name }
        return "Edit"
    }
}

// MARK: - permission (권한 요청)

struct PermissionView: View {
    let request: PermissionRequestInfo
    let queueCount: Int
    let session: AgentSession?
    let geometry: NotchGeometry
    let headerHeight: CGFloat
    let presentation: PresentationController
    let reduceMotion: Bool

    var body: some View {
        let canAllowAlways = PresentationController.canAllowAlways(request)

        VStack(spacing: 0) {
            CardHeader(
                session: session,
                geometry: geometry,
                height: headerHeight,
                reduceMotion: reduceMotion,
                indicator: AnyView(PulsingDot(animated: !reduceMotion).frame(width: 8, height: 8))
            ) {
                Text(queueCount > 1 ? "승인 필요 · \(queueCount)" : "승인 필요")
                    .foregroundStyle(Palette.amber)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(request.title)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                    .frame(height: IslandMetrics.lineHeight)
                    .padding(.bottom, 6)

                Text(request.detail)
                    .font(IslandFont.mono)
                    .foregroundStyle(Palette.text)
                    .lineLimit(detailLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: CGFloat(detailLines) * IslandMetrics.monoLineHeight, alignment: .topLeading)
                    .padding(.horizontal, IslandMetrics.detailHorizontalPadding)
                    .padding(.vertical, IslandMetrics.detailVerticalPadding)
                    .background(Palette.row, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.bottom, 12)

                HStack(spacing: 6) {
                    Button {
                        presentation.resolve(request, decision: .allow)
                    } label: {
                        Text("허용 ⌘↩")
                    }
                    .buttonStyle(IslandButtonStyle(prominent: true))
                    .accessibilityLabel("허용")
                    .help("허용 (⌘↩)")

                    Button {
                        presentation.resolve(request, decision: .allowAlways)
                    } label: {
                        Text("항상 허용")
                    }
                    .buttonStyle(IslandButtonStyle())
                    .disabled(!canAllowAlways)
                    .accessibilityLabel("항상 허용")
                    .help(canAllowAlways ? "다음부터 묻지 않음 (⌥⌘↩)" : "이 요청은 항상 허용 규칙이 없어")

                    Button {
                        presentation.resolve(request, decision: .deny(message: nil))
                    } label: {
                        Text("거부 ⌘⌫")
                    }
                    .buttonStyle(IslandButtonStyle())
                    .accessibilityLabel("거부")
                    .help("거부 (⌘⌫)")

                    Spacer(minLength: 0)

                    Button {
                        presentation.sendToTerminal(request)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "terminal")
                            Text("터미널로")
                        }
                    }
                    .buttonStyle(IslandButtonStyle())
                    .accessibilityLabel("터미널로")
                    .help("터미널에서 직접 결정")
                }
            }
            .font(IslandFont.body)
            .padding(.horizontal, IslandMetrics.bodyPadding)
            .padding(.top, IslandMetrics.bodyTop)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 레이아웃 계산과 같은 방식으로 센 상세 줄 수
    private var detailLines: Int {
        let width = IslandMetrics.permissionWidth - IslandMetrics.bodyPadding * 2 - IslandMetrics.detailHorizontalPadding * 2
        return TextMeasure.lineCount(
            request.detail, font: IslandFont.monoNS, lineHeight: IslandMetrics.monoLineHeight,
            width: width, maxLines: IslandMetrics.maxDetailLines
        )
    }
}

// MARK: - needsInput (질문/입력 대기)

struct NeedsInputView: View {
    let session: AgentSession?
    let sessionID: String
    let message: String
    let isPermissionPrompt: Bool
    let geometry: NotchGeometry
    let headerHeight: CGFloat
    let actions: IslandActions
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 0) {
            CardHeader(
                session: session,
                geometry: geometry,
                height: headerHeight,
                reduceMotion: reduceMotion,
                indicator: AnyView(PulsingDot(animated: !reduceMotion).frame(width: 8, height: 8))
            ) {
                Text(isPermissionPrompt ? "승인 필요" : "입력 필요")
                    .foregroundStyle(Palette.amber)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(message)
                    .foregroundStyle(Palette.text)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: CGFloat(messageLines) * IslandMetrics.lineHeight, alignment: .topLeading)

                HStack {
                    Spacer(minLength: 0)
                    Button {
                        actions.jumpToTerminal(sessionID: sessionID)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "terminal")
                            Text("터미널로")
                        }
                    }
                    .buttonStyle(IslandButtonStyle(prominent: isPermissionPrompt))
                    .accessibilityLabel("터미널로")
                }
                .padding(.top, 10)
            }
            .font(IslandFont.body)
            .padding(.horizontal, IslandMetrics.bodyPadding)
            .padding(.top, IslandMetrics.bodyTop)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var messageLines: Int {
        TextMeasure.lineCount(
            message, font: IslandFont.bodyNS, lineHeight: IslandMetrics.bodyLineHeight,
            width: IslandMetrics.needsInputWidth - IslandMetrics.bodyPadding * 2, maxLines: 2
        )
    }
}

// MARK: - done / failed (턴 완료 요약)

struct CompletionView: View {
    let session: AgentSession?
    let failed: Bool
    let textLine: String?
    let geometry: NotchGeometry
    let headerHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            CardHeader(
                session: session,
                geometry: geometry,
                height: headerHeight,
                reduceMotion: true,
                indicator: AnyView(
                    Image(systemName: failed ? "xmark.circle" : "checkmark.circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(failed ? Palette.red : Palette.green)
                        .accessibilityLabel(failed ? "실패" : "완료")
                )
            ) {
                Text(statusText)
                    .foregroundStyle(failed ? Palette.red : Palette.muted)
            }

            VStack(alignment: .leading, spacing: 4) {
                if failed {
                    Text(errorText)
                        .foregroundStyle(Palette.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: IslandMetrics.lineHeight)
                    if let session, !session.turn.changedFiles.isEmpty {
                        filesRow(session.turn)
                    }
                } else {
                    if let session {
                        filesRow(session.turn)
                    }
                    if let textLine {
                        Text(textLine)
                            .foregroundStyle(Palette.secondary)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: IslandMetrics.lineHeight)
                    }
                }
            }
            .font(IslandFont.body)
            .foregroundStyle(Palette.text)
            .lineLimit(1)
            .padding(.horizontal, IslandMetrics.bodyPadding)
            .padding(.top, 2)
            .padding(.bottom, IslandMetrics.bodyBottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var statusText: String {
        if failed { return "실패" }
        guard let session, let duration = IslandFormat.turnDuration(session) else { return "완료" }
        return "완료 · \(IslandFormat.duration(duration))"
    }

    private var errorText: String {
        guard let message = session?.errorMessage, !message.isEmpty else { return "턴이 실패했어" }
        return IslandFormat.singleLine(message)
    }

    @ViewBuilder
    private func filesRow(_ turn: TurnSummary) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.on.doc")
                .foregroundStyle(Palette.secondary)
            if turn.changedFiles.isEmpty {
                Text("변경한 파일 없음")
                    .foregroundStyle(Palette.muted)
            } else {
                Text("파일 \(turn.changedFiles.count)개")
                DiffStatText(added: turn.added, removed: turn.removed)
            }
        }
        .frame(height: IslandMetrics.lineHeight)
    }
}
