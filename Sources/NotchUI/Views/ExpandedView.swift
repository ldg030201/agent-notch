import SwiftUI
import NotchCore

/// 전체 펼침 (620×300): 왼쪽 세션 목록(우선순위순) / 오른쪽 포커스 세션 상세
struct ExpandedView: View {
    let layout: IslandLayout
    let presentation: PresentationController
    let reduceMotion: Bool

    var body: some View {
        let store = presentation.store
        let sessions = store.rankedSessions
        let detail = store.focusedSession ?? sessions.first

        CardScaffold(layout: layout) {
            // 세션 수 + 모든 세션 상태 요약. 자리가 모자라면 요약을 남기고 "세션 N" 을 뺀다 (칩은 자르지 않음)
            let title = Text("세션 \(sessions.count)").foregroundStyle(Palette.secondary)
            let summary = presentation.allSessionsSummary
            if summary.isEmpty {
                title
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        title
                        SessionSummaryChips(summary: summary)
                    }
                    .fixedSize()
                    SessionSummaryChips(summary: summary, spokenPrefix: "세션 \(sessions.count)개, ")
                    title
                }
            }
        } trailing: {
            HStack(spacing: 6) {
                if let provider = presentation.updateProvider, provider.hasUpdate {
                    UpdateBadge(version: provider.latestVersion) {
                        presentation.openSettings(section: .version)
                    }
                }
                Button {
                    presentation.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                }
                .buttonStyle(IslandIconButtonStyle())
                .accessibilityLabel("설정")
                .help("설정")
            }
        } content: {
            Group {
                if sessions.isEmpty {
                    emptyState
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        SessionListView(
                            sessions: sessions,
                            selectedID: detail?.id,
                            pinnedID: store.pinnedSessionID,
                            actions: presentation.actions,
                            reduceMotion: reduceMotion
                        )
                        .frame(width: 180)

                        if let detail {
                            SessionDetailView(
                                session: detail,
                                textLine: presentation.streamingLine(for: detail.id),
                                actions: presentation.actions,
                                reduceMotion: reduceMotion
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                }
            }
            .font(IslandFont.body)
            .foregroundStyle(Palette.text)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 18))
                .foregroundStyle(Palette.muted)
            Text("세션 없음")
                .foregroundStyle(Palette.secondary)
            Text("Claude Code 세션이 시작되면 여기에 표시돼")
                .font(IslandFont.caption)
                .foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 펼친 아일랜드 상단의 작은 파란 "새 버전" 배지 (누르면 설정의 버전 탭)
struct UpdateBadge: View {
    let version: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("새 버전")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.badgeText)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Palette.badgeBackground, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(version.map { "새 버전 \($0)" } ?? "새 버전")
        .help(version.map { "새 버전 \($0) — 눌러서 업데이트" } ?? "새 버전 — 눌러서 업데이트")
    }
}

// MARK: - 세션 목록

struct SessionListView: View {
    let sessions: [AgentSession]
    let selectedID: String?
    let pinnedID: String?
    let actions: IslandActions
    let reduceMotion: Bool

    var body: some View {
        IslandScrollable {
            VStack(spacing: 2) {
                ForEach(sessions) { session in
                    SessionRow(
                        session: session,
                        isSelected: session.id == selectedID,
                        isPinned: session.id == pinnedID,
                        actions: actions,
                        reduceMotion: reduceMotion
                    )
                }
            }
        }
    }
}

struct SessionRow: View {
    let session: AgentSession
    let isSelected: Bool
    let isPinned: Bool
    let actions: IslandActions
    let reduceMotion: Bool

    var body: some View {
        IslandClock { now in
            let subtitle = IslandFormat.subtitle(session, now: now)
            Button {
                // 세션 선택 = 확인 처리 (App 의 IslandActions 구현이 markSeen 도 한다)
                actions.focus(sessionID: session.id)
            } label: {
                HStack(spacing: 8) {
                    SessionDot(session: session, size: 7, reduceMotion: reduceMotion)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.projectName)
                            .foregroundStyle(Palette.text)
                        Text(subtitle)
                            .font(IslandFont.caption)
                            .foregroundStyle(Palette.muted)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    if isPinned {
                        Image(systemName: "pin")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondary)
                            .accessibilityLabel("고정됨")
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    isSelected ? Palette.row : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(session.projectName), \(subtitle)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .contextMenu {
                Button(isPinned ? "고정 해제" : "고정") {
                    actions.togglePin(sessionID: session.id)
                }
                Button("터미널로") {
                    actions.jumpToTerminal(sessionID: session.id)
                }
                Divider()
                Button("목록에서 제거", role: .destructive) {
                    actions.dismiss(sessionID: session.id)
                }
            }
        }
    }
}

// MARK: - 포커스 세션 상세

struct SessionDetailView: View {
    let session: AgentSession
    let textLine: String?
    let actions: IslandActions
    let reduceMotion: Bool

    /// 상세에 보여줄 최근 활동 수
    private static let activityCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                titleText
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                ElapsedText(session: session)
            }
            .frame(height: IslandMetrics.lineHeight)
            .padding(.bottom, 6)

            let activities = recentActivities
            if activities.isEmpty {
                Text(session.lastPrompt.map(IslandFormat.singleLine) ?? "아직 활동 없음")
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .frame(height: IslandMetrics.lineHeight)
                    .padding(.bottom, 8)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(activities) { activity in
                        ActivityRow(activity: activity, reduceMotion: reduceMotion)
                    }
                }
                .padding(.bottom, 8)
            }

            if let diff = session.lastDiff {
                DiffRowsView(lines: DiffPresentation.visibleLines(diff))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        actions.openFile(path: diff.filePath, line: diff.startLine)
                    }
                    .help(DiffPresentation.displayPath(diff, cwd: session.cwd))
            }

            if let textLine {
                Text(textLine)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
    }

    private var titleText: Text {
        var text = Text(session.projectName).foregroundStyle(Palette.text)
        if let branch = session.gitBranch, !branch.isEmpty {
            text = text + Text(" · \(branch)").foregroundStyle(Palette.muted)
        }
        return text
    }

    private var recentActivities: [ActivityItem] {
        let relevant = session.activities.filter { $0.kind != .message && $0.kind != .prompt }
        return Array(relevant.suffix(Self.activityCount))
    }
}

struct ActivityRow: View {
    let activity: ActivityItem
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 6) {
            icon
                .frame(width: 14, height: 14)
            Text(activity.title)
                .lineLimit(1)
                .truncationMode(.tail)
            if let diff = activity.diff {
                DiffStatText(added: diff.added, removed: diff.removed)
                    .layoutPriority(1)
            }
        }
        .foregroundStyle(activity.status == .failed ? Palette.red : Palette.secondary)
        .frame(height: IslandMetrics.lineHeight)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch activity.status {
        case .running:
            SpinnerView(animated: !reduceMotion)
                .frame(width: 12, height: 12)
                .accessibilityLabel("실행 중")
        case .failed:
            Image(systemName: "xmark.circle")
                .font(.system(size: 11))
                .accessibilityLabel("실패")
        case .succeeded:
            Image(systemName: activity.symbolName)
                .font(.system(size: 11))
        }
    }
}

/// 경과 시간: 작업 중이면 턴 시작부터 1초마다, 아니면 완료 소요 시간/유휴 시간
struct ElapsedText: View {
    let session: AgentSession

    var body: some View {
        Group {
            if session.phase.isWorking || session.phase.needsAttention,
               let start = session.turnStartedAt ?? session.turn.startedAt {
                IslandClock(everySecond: true) { now in
                    Text(IslandFormat.duration(now.timeIntervalSince(start)))
                }
            } else if session.phase == .completed, let duration = IslandFormat.turnDuration(session) {
                Text("완료 · \(IslandFormat.duration(duration))")
            } else {
                IslandClock { now in
                    Text("유휴 · \(IslandFormat.idleText(since: session.lastEventAt, now: now))")
                }
            }
        }
        .font(IslandFont.body)
        .foregroundStyle(Palette.muted)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
}
