import SwiftUI

/// 설정 "버전" 탭: 지금 버전, 새 버전 확인 상태, 업데이트 버튼, 자동 확인, 변경 내역
struct VersionSettingsView: View {
    let provider: UpdateProvider
    let model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "버전") {
                SettingsRow(title: "지금 버전") {
                    Text(provider.currentVersion)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                SettingsDivider()
                statusRow
                SettingsDivider()
                Toggle(isOn: Binding(
                    get: { provider.checksForUpdates },
                    set: { provider.checksForUpdates = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("하루에 한 번 새 버전 확인")
                        Text(lastCheckedText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(SettingsSwitchStyle())
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }

            SettingsGroup(title: "변경 내역") {
                if provider.changelog.isEmpty {
                    SettingsNote(text: "변경 내역을 아직 받지 못했어요. 업데이트 확인을 눌러 봐요.")
                } else {
                    ForEach(Array(provider.changelog.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { SettingsDivider() }
                        ChangelogEntryView(entry: entry, isCurrent: entry.version == provider.currentVersion)
                    }
                }
            }
        }
    }

    /// 진행 중(받는 중 · 교체 중)이 아니면 새로 시작할 수 있다 (실패 후 재시도 포함)
    private var canStartUpgrade: Bool {
        switch provider.upgradePhase {
        case .idle, .failed: return true
        case .running, .ready, .swapping: return false
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            status
                .frame(maxWidth: .infinity, alignment: .leading)
            if provider.upgradePhase == .ready {
                // 진행 화면에서 "나중에" 를 눌렀어도 여기서 마저 끝낼 수 있게 한다
                Button("다시 띄워서 마치기") {
                    provider.relaunchAfterUpgrade()
                }
                .buttonStyle(SettingsButtonStyle(prominent: true))
            } else if provider.hasUpdate {
                Button("업데이트") {
                    model.deferredUpgradeReady = false
                    provider.startUpgrade()
                }
                .buttonStyle(SettingsButtonStyle(prominent: true))
                .disabled(!canStartUpgrade)
            }
            Button("업데이트 확인") {
                provider.checkNow()
            }
            .buttonStyle(SettingsButtonStyle())
            .disabled(provider.isChecking || !canStartUpgrade)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var status: some View {
        if provider.isChecking {
            HStack(spacing: 6) {
                SettingsSpinner()
                Text("확인 중…").foregroundStyle(.secondary)
            }
        } else if provider.hasUpdate {
            Label {
                Text("새 버전 \(provider.latestVersion ?? "")")
            } icon: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(SettingsPalette.accent)
            }
        } else if let error = provider.errorText {
            Label {
                Text("확인 실패: \(error)")
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SettingsPalette.orange)
            }
        } else if provider.lastCheckedAt != nil {
            Label {
                Text("최신 버전")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(SettingsPalette.green)
            }
        } else {
            Text("아직 확인 안 함").foregroundStyle(.secondary)
        }
    }

    private var lastCheckedText: String {
        guard let date = provider.lastCheckedAt else { return "아직 확인한 적 없음" }
        return "마지막 확인 \(Self.ageText(since: date, now: model.now()))"
    }

    /// "방금" · "12분 전" · "3시간 전" · "2일 전" (경과 시간은 아일랜드의 `IslandFormat.idleText` 와 같은 규칙)
    static func ageText(since date: Date, now: Date) -> String {
        let elapsed = IslandFormat.idleText(since: date, now: now)
        return now.timeIntervalSince(date) < 60 ? elapsed : elapsed + " 전"
    }
}

/// 변경 내역 한 버전
struct ChangelogEntryView: View {
    let entry: ChangelogDisplayEntry
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(entry.version)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                if let date = entry.date {
                    Text(date)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    SettingsTag(text: "준비 중", tint: SettingsPalette.orange)
                }
                if isCurrent {
                    SettingsTag(text: "지금 버전", tint: SettingsPalette.accent)
                }
                Spacer(minLength: 0)
            }
            ForEach(Array(entry.groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(group.notes.enumerated()), id: \.offset) { _, note in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            SettingsTag(text: Self.kindLabel(note.kind), tint: Self.kindColor(note.kind))
                            Text(note.text)
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "new": return "새 기능"
        case "improve": return "개선"
        case "change": return "변경"
        case "fix": return "수정"
        case "remove": return "제거"
        default: return kind
        }
    }

    static func kindColor(_ kind: String) -> Color {
        switch kind {
        case "new": return SettingsPalette.green
        case "improve": return SettingsPalette.accent
        case "fix": return SettingsPalette.orange
        case "remove": return SettingsPalette.red
        default: return .secondary
        }
    }
}

// MARK: - 업데이트 진행 창

/// `brew upgrade` 진행 중 · 다 받음 · 교체 중 · 실패 상태를 설정 창 위에 띄운다.
struct UpgradeOverlay: View {
    let provider: UpdateProvider
    let model: SettingsModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let phase = provider.upgradePhase
        if Self.isVisible(phase, deferredReady: model.deferredUpgradeReady) {
            let palette = SettingsPalette.resolve(colorScheme)
            ZStack {
                palette.overlayDim
                card(phase, palette: palette)
                    .padding(18)
                    .frame(width: 460)
                    .background(palette.groupBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(palette.groupBorder, lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 18, y: 6)
            }
            .accessibilityAddTraits(.isModal)
        }
    }

    /// 처음 단계면 숨기고, 다 받은 단계는 "나중에" 를 눌렀으면 숨긴다 (교체 · 실패로 넘어가면 다시 보인다)
    static func isVisible(_ phase: UpgradePhase, deferredReady: Bool) -> Bool {
        switch phase {
        case .idle: return false
        case .ready: return !deferredReady
        case .running, .swapping, .failed: return true
        }
    }

    @ViewBuilder
    private func card(_ phase: UpgradePhase, palette: SettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .running:
                HStack(spacing: 8) {
                    SettingsSpinner(size: 14)
                    Text("새 버전을 받는 중…").font(.system(size: 14, weight: .semibold))
                }
                log(palette)
                HStack {
                    Spacer()
                    Button("취소") { provider.cancelUpgrade() }
                        .buttonStyle(SettingsButtonStyle())
                }

            case .ready:
                Label {
                    Text("다 받았어요 — 다시 띄우면 끝나요").font(.system(size: 14, weight: .semibold))
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(SettingsPalette.green)
                }
                Text("다시 띄우면 앱이 잠깐 꺼졌다가 새 버전으로 켜져요.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("나중에") { model.deferredUpgradeReady = true }
                        .buttonStyle(SettingsButtonStyle())
                    Button("지금 다시 띄우기") { provider.relaunchAfterUpgrade() }
                        .buttonStyle(SettingsButtonStyle(prominent: true))
                }

            case .swapping:
                HStack(spacing: 8) {
                    SettingsSpinner(size: 14)
                    Text("새 버전으로 바꾸는 중…").font(.system(size: 14, weight: .semibold))
                }
                Text("잠시 뒤 새 버전이 다시 떠요. 오래 멈춰 있으면 강제 종료할 수 있어요.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if model.confirmingForceQuit {
                    Text("정말 강제 종료할까요? 바꾸던 중이면 다시 설치해야 할 수 있어요.")
                        .font(.system(size: 12))
                    HStack {
                        Spacer()
                        Button("취소") { model.confirmingForceQuit = false }
                            .buttonStyle(SettingsButtonStyle())
                        Button("강제 종료", role: .destructive) { provider.forceQuit() }
                            .buttonStyle(SettingsButtonStyle(prominent: true, destructive: true))
                    }
                } else {
                    HStack {
                        Spacer()
                        Button("강제 종료…") { model.confirmingForceQuit = true }
                            .buttonStyle(SettingsButtonStyle())
                    }
                }

            case let .failed(reason):
                Label {
                    Text("업데이트 실패").font(.system(size: 14, weight: .semibold))
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(SettingsPalette.red)
                }
                Text(reason)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !provider.upgradeLog.isEmpty { log(palette) }
                HStack {
                    Spacer()
                    Button("닫기") {
                        // 단계를 처음으로 돌려야 다음 실행이 같은 이유로 실패해도 다시 보인다
                        model.deferredUpgradeReady = false
                        provider.dismissUpgrade()
                    }
                    .buttonStyle(SettingsButtonStyle())
                }

            case .idle:
                EmptyView()
            }
        }
        .font(.system(size: 13))
    }

    /// 진행 로그 뒤쪽 몇 줄 (스크롤 없이 마지막 줄이 보이게)
    private func log(_ palette: SettingsPalette) -> some View {
        let lines = provider.upgradeLog
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(9)
            .joined(separator: "\n")
        return Text(lines.isEmpty ? " " : lines)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(9)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, minHeight: 130, maxHeight: 130, alignment: .bottomLeading)
            .padding(8)
            .background(palette.logBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel("진행 로그")
    }
}
