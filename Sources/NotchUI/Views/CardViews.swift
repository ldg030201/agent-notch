import SwiftUI
import NotchCore

// MARK: - peek (파일 수정 미니 diff)

struct PeekView: View {
    let session: AgentSession?
    let diff: DiffSnippet
    let textLine: String?
    let layout: IslandLayout
    let actions: IslandActions
    let reduceMotion: Bool

    var body: some View {
        CardScaffold(layout: layout) {
            CardHeaderLeading(session: session, reduceMotion: reduceMotion)
        } trailing: {
            HStack(spacing: 6) {
                Text(toolName)
                DiffStatText(added: diff.added, removed: diff.removed)
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Button {
                        actions.openFile(path: diff.filePath)
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
    let layout: IslandLayout
    let presentation: PresentationController
    let reduceMotion: Bool

    var body: some View {
        let card = presentation.permissionCard(for: request, width: layout.cardWidth)
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
                Text(request.title)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                    .frame(height: IslandMetrics.lineHeight)
                    .padding(.bottom, 6)

                Text(request.detail)
                    .font(IslandFont.mono)
                    .foregroundStyle(Palette.text)
                    .lineLimit(card.detailLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: CGFloat(card.detailLines) * IslandMetrics.monoLineHeight, alignment: .topLeading)
                    .padding(.horizontal, IslandMetrics.detailHorizontalPadding)
                    .padding(.vertical, IslandMetrics.detailVerticalPadding)
                    .background(Palette.row, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if card.isClipped {
                    // 다 보이지 않는 요청은 노치에서 허용하지 않는다 (승인하면 안 보이는 부분까지 실행된다)
                    HStack(spacing: 5) {
                        Image(systemName: "eye.slash")
                        Text(PermissionCardModel.clippedNote(host))
                    }
                    .font(IslandFont.caption)
                    .foregroundStyle(Palette.amber)
                    .lineLimit(1)
                    .frame(height: IslandMetrics.permissionNoteHeight)
                    .padding(.top, IslandMetrics.permissionNoteGap)
                }

                if !card.scopeLines.isEmpty {
                    // 항상 허용하면 저장될 규칙과 범위
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(card.scopeLines.enumerated()), id: \.offset) { index, line in
                            HStack(spacing: 0) {
                                Text("항상 허용 → ")
                                    .foregroundStyle(Palette.muted)
                                    .opacity(index == 0 ? 1 : 0)
                                Text(line)
                                    .foregroundStyle(Palette.secondary)
                                    .truncationMode(.middle)
                            }
                            .frame(height: IslandMetrics.scopeLineHeight)
                        }
                    }
                    .font(IslandFont.caption)
                    .lineLimit(1)
                    .padding(.top, IslandMetrics.permissionNoteGap)
                    .help("항상 허용하면 저장되는 규칙:\n" + card.fullScope.joined(separator: "\n"))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("항상 허용 범위: " + card.fullScope.joined(separator: ", "))
                }

                HStack(spacing: 6) {
                    Button {
                        presentation.resolve(request, decision: .allow)
                    } label: {
                        Text("허용" + presentation.keyLabel("⌘↩", .permission))
                    }
                    .buttonStyle(IslandButtonStyle(prominent: card.canAllow))
                    .disabled(!card.canAllow)
                    .accessibilityLabel("허용")
                    .help(card.canAllow ? "허용" + presentation.keyNote("⌘↩", .permission) : Self.clippedHelp(host))

                    Button {
                        presentation.resolve(request, decision: .allowAlways)
                    } label: {
                        Text("항상 허용")
                    }
                    .buttonStyle(IslandButtonStyle())
                    .disabled(!card.canAllowAlways)
                    .accessibilityLabel("항상 허용")
                    .help(allowAlwaysHelp(card, host: host))

                    Button {
                        presentation.resolve(request, decision: .deny(message: nil))
                    } label: {
                        Text("거부" + presentation.keyLabel("⌘⌫", .permission))
                    }
                    .buttonStyle(IslandButtonStyle())
                    .accessibilityLabel("거부")
                    .help("거부" + presentation.keyNote("⌘⌫", .permission))

                    Spacer(minLength: 0)

                    Button {
                        presentation.minimize(request)
                    } label: {
                        Text("접기")
                    }
                    .buttonStyle(IslandButtonStyle())
                    .accessibilityLabel("접기")
                    .help("요청은 그대로 두고 접기" + presentation.keyNote("⎋", .collapse) + ". 아일랜드를 누르면 다시 펼쳐져")

                    Button {
                        presentation.sendToTerminal(request)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: host.symbolName)
                            Text(host.jumpLabel)
                        }
                    }
                    .buttonStyle(IslandButtonStyle(prominent: card.isClipped))
                    .accessibilityLabel(host.jumpLabel)
                    .help("\(host.placeName)에서 직접 결정")
                }
                .padding(.top, 12)
            }
            .font(IslandFont.body)
            .padding(.horizontal, IslandMetrics.bodyPadding)
            .padding(.top, IslandMetrics.bodyTop)
            .padding(.bottom, 14)
        }
    }

    private static func clippedHelp(_ host: SessionHost) -> String {
        "다 보이지 않는 요청은 여기서 허용할 수 없어 · \(host.jumpLabel)"
    }

    private func allowAlwaysHelp(_ card: PermissionCardModel, host: SessionHost) -> String {
        if card.isClipped { return Self.clippedHelp(host) }
        if !card.canAllowAlways { return "이 요청은 항상 허용 규칙이 없어" }
        return "다음부터 묻지 않음" + presentation.keyNote("⌥⌘↩", .permission)
    }
}

// MARK: - needsInput (질문/입력 대기)

struct NeedsInputView: View {
    let session: AgentSession?
    let sessionID: String
    let message: String
    let isPermissionPrompt: Bool
    let layout: IslandLayout
    let presentation: PresentationController
    let reduceMotion: Bool

    var body: some View {
        let host = SessionHost(session?.terminal)

        CardScaffold(layout: layout) {
            CardHeaderLeading(
                session: session,
                reduceMotion: reduceMotion,
                indicator: AnyView(PulsingDot(animated: !reduceMotion).frame(width: 8, height: 8))
            )
        } trailing: {
            Text(isPermissionPrompt ? "승인 필요" : "입력 필요")
                .foregroundStyle(Palette.amber)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                Text(message)
                    .foregroundStyle(Palette.text)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: CGFloat(messageLines) * IslandMetrics.lineHeight, alignment: .topLeading)

                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button {
                        presentation.minimizeInput(sessionID: sessionID, message: message)
                    } label: {
                        Text("접기")
                    }
                    .buttonStyle(IslandButtonStyle())
                    .accessibilityLabel("접기")
                    .help("접기" + presentation.keyNote("⎋", .collapse))

                    Button {
                        presentation.actions.jumpToTerminal(sessionID: sessionID)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: host.symbolName)
                            Text(host.jumpLabel)
                        }
                    }
                    .buttonStyle(IslandButtonStyle(prominent: isPermissionPrompt))
                    .accessibilityLabel(host.jumpLabel)
                }
                .padding(.top, 10)
            }
            .font(IslandFont.body)
            .padding(.horizontal, IslandMetrics.bodyPadding)
            .padding(.top, IslandMetrics.bodyTop)
            .padding(.bottom, 14)
        }
    }

    private var messageLines: Int {
        TextMeasure.lineCount(
            message, font: IslandFont.bodyNS, lineHeight: IslandMetrics.bodyLineHeight,
            width: layout.cardWidth - IslandMetrics.bodyPadding * 2, maxLines: 2
        )
    }
}

// MARK: - done / failed (턴 완료 요약)

struct CompletionView: View {
    let session: AgentSession?
    let failed: Bool
    let textLine: String?
    let layout: IslandLayout

    var body: some View {
        CardScaffold(layout: layout) {
            CardHeaderLeading(
                session: session,
                reduceMotion: true,
                indicator: AnyView(
                    Image(systemName: failed ? "xmark.circle" : "checkmark.circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(failed ? Palette.red : Palette.green)
                        .accessibilityLabel(failed ? "실패" : "완료")
                )
            )
        } trailing: {
            Text(statusText)
                .foregroundStyle(failed ? Palette.red : Palette.muted)
        } content: {
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
    }

    private var statusText: String {
        if failed { return "실패" }
        guard let session, let duration = session.turnDuration else { return "완료" }
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
