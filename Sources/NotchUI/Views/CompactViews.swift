import SwiftUI
import NotchCore

/// idle: 오른쪽 날개에 세션 수만큼 점 (작업 중 = 초록, 나머지 = 회색)
struct IdleWingsView: View {
    let geometry: NotchGeometry
    let layout: IslandLayout
    let store: SessionStore
    let reduceMotion: Bool

    var body: some View {
        let sessions = Array(store.rankedSessions.prefix(IslandMetrics.maxIdleDots))
        Group {
            if geometry.hasNotch {
                WingRow(geometry: geometry, height: layout.headerHeight) {
                    Circle()
                        .fill(Palette.muted)
                        .frame(width: 3, height: 3)
                } trailing: {
                    dots(sessions)
                }
            } else {
                dots(sessions)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func dots(_ sessions: [AgentSession]) -> some View {
        HStack(spacing: IslandMetrics.idleDotSpacing) {
            ForEach(sessions) { session in
                SessionDot(session: session, size: IslandMetrics.idleDotSize, reduceMotion: reduceMotion)
            }
        }
    }

    private var accessibilityText: String {
        let total = store.rankedSessions.count
        let working = store.rankedSessions.filter { $0.phase.isWorking }.count
        return "세션 \(total)개, 작업 중 \(working)개"
    }
}

/// working: 왼쪽 날개 = 상태 + 프로젝트명, 오른쪽 날개 = 현재 툴 + `+N −M`.
/// 노치 없는 화면에선 한 줄 알약 (툴 제목 전체 표시).
struct CompactWingsView: View {
    let session: AgentSession?
    let geometry: NotchGeometry
    let height: CGFloat
    let reduceMotion: Bool

    var body: some View {
        if let session {
            WingRow(geometry: geometry, height: height) {
                HStack(spacing: 6) {
                    StatusIndicator(session: session, reduceMotion: reduceMotion)
                    Text(session.projectName)
                        .truncationMode(.tail)
                }
            } trailing: {
                trailing(session)
            }
            .accessibilityElement(children: .combine)
        } else {
            Color.clear.frame(height: height)
        }
    }

    @ViewBuilder
    private func trailing(_ session: AgentSession) -> some View {
        switch session.phase {
        case .waitingPermission:
            Text("승인 필요").foregroundStyle(Palette.amber)
        case .waitingInput:
            Text("입력 필요").foregroundStyle(Palette.amber)
        case .failed:
            Text("실패").foregroundStyle(Palette.red)
        case .completed:
            Text("완료").foregroundStyle(Palette.muted)
        default:
            let title = geometry.hasNotch ? IslandFormat.shortToolTitle(session) : IslandFormat.fullToolTitle(session)
            HStack(spacing: 6) {
                if !title.isEmpty {
                    Text(title)
                        .truncationMode(.middle)
                }
                if session.turn.added > 0 || session.turn.removed > 0 {
                    DiffStatText(added: session.turn.added, removed: session.turn.removed)
                        .layoutPriority(1)
                }
            }
        }
    }
}

/// peek 와 같은 펼친 카드의 상단 행: 상태 + 프로젝트명 / 오른쪽 문구
struct CardHeader<Trailing: View>: View {
    let session: AgentSession?
    let geometry: NotchGeometry
    let height: CGFloat
    let reduceMotion: Bool
    var indicator: AnyView?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        WingRow(geometry: geometry, height: height) {
            HStack(spacing: 6) {
                if let indicator {
                    indicator
                } else if let session {
                    StatusIndicator(session: session, reduceMotion: reduceMotion)
                }
                Text(session?.projectName ?? "Claude Code")
                    .truncationMode(.tail)
            }
        } trailing: {
            trailing
        }
    }
}
