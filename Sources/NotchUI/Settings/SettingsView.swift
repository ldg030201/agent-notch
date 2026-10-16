import AppKit
import Observation
import SwiftUI
import NotchCore

/// 설정 화면 탭
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case display
    case shortcuts
    case version

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "일반"
        case .display: return "표시"
        case .shortcuts: return "단축키"
        case .version: return "버전"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .display: return "menubar.rectangle"
        case .shortcuts: return "keyboard"
        case .version: return "arrow.down.circle"
        }
    }
}

/// SettingsProvider(관찰 불가 프로토콜) 값을 캐시해 SwiftUI 에 노출하는 모델
@MainActor
@Observable
final class SettingsModel {
    @ObservationIgnored private let provider: SettingsProvider
    /// 마지막 확인 시각 표시용 (스냅숏은 고정 시각)
    @ObservationIgnored let now: () -> Date

    private(set) var appVersion = ""
    private(set) var hookStatusText = ""
    private(set) var hooksInstalled = false
    private(set) var launchAtLoginEnabled = false
    private(set) var launchAtLoginManagedByHomebrew = false
    private(set) var hookError: String?
    private(set) var loginError: String?

    var selectedSection: SettingsSection = .general {
        didSet { if selectedSection != oldValue { stopRecordingShortcut() } }
    }
    /// 어디서든 펼치기 키 조합을 녹화하는 중 (다음에 누른 키 조합으로 바꾼다)
    private(set) var isRecordingShortcut = false
    @ObservationIgnored private var recordingMonitor: Any?
    /// 업데이트 상태 (없으면 버전 탭 숨김)
    var updateProvider: UpdateProvider?
    /// 다 받은 뒤 "나중에" 로 진행 창을 내렸는지 (버전 탭의 "다시 띄워서 마치기" 로 마저 끝낸다).
    /// 실패 화면 "닫기" 는 여기 적지 않고 업그레이드 단계를 처음으로 돌린다 (`UpdateProvider.dismissUpgrade`)
    var deferredUpgradeReady = false
    /// 교체 중 강제 종료 확인 단계
    var confirmingForceQuit = false
    /// 설정 초기화 확인 단계 (버튼 자리에 취소 · 초기화가 나온다)
    var confirmingReset = false

    /// 값은 설정 창을 열 때 `refresh()` 로 읽는다
    init(provider: SettingsProvider, now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
    }

    func refresh() {
        appVersion = provider.appVersion
        (hookStatusText, hooksInstalled) = provider.hookState
        launchAtLoginEnabled = provider.launchAtLoginEnabled
        launchAtLoginManagedByHomebrew = provider.launchAtLoginManagedByHomebrew
    }

    func installHooks() {
        do {
            try provider.installHooks()
            hookError = nil
        } catch {
            hookError = "설치 실패: \(error.localizedDescription)"
        }
        refresh()
    }

    func uninstallHooks() {
        do {
            try provider.uninstallHooks()
            hookError = nil
        } catch {
            hookError = "제거 실패: \(error.localizedDescription)"
        }
        refresh()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try provider.setLaunchAtLogin(enabled)
            loginError = nil
        } catch {
            loginError = "변경 실패: \(error.localizedDescription)"
        }
        refresh()
    }

    /// 업데이트 기능이 없으면 버전 탭은 숨긴다
    var visibleSections: [SettingsSection] {
        updateProvider == nil ? SettingsSection.allCases.filter { $0 != .version } : SettingsSection.allCases
    }

    // MARK: 단축키 녹화

    /// 전역 단축키 등록 상태 (App 이 관찰 가능한 객체로 준다. 스냅숏은 없음)
    var globalShortcut: GlobalShortcutState? { provider.globalShortcut }

    /// 녹화를 시작한다: 다음에 누른 키 조합(⌘ · ⌃ · ⌥ 중 하나 포함)을 `onCapture` 로 넘기고 끝낸다.
    /// ⎋ 는 취소, 수식키가 모자란 키는 알림음. 녹화하는 동안 지금 전역 단축키는 잠깐 해제한다
    func startRecordingShortcut(onCapture: @escaping (KeyCombo) -> Void) {
        guard !isRecordingShortcut else { return }
        isRecordingShortcut = true
        globalShortcut?.isPaused = true
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isRecordingShortcut else { return false }
                if let combo = KeyComboRecorder.combo(from: event) {
                    onCapture(combo)
                    self.stopRecordingShortcut()
                } else if event.keyCode == KeyComboRecorder.cancelKeyCode {
                    self.stopRecordingShortcut()
                } else {
                    NSSound.beep()
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    func stopRecordingShortcut() {
        if let monitor = recordingMonitor { NSEvent.removeMonitor(monitor) }
        recordingMonitor = nil
        guard isRecordingShortcut else { return }
        isRecordingShortcut = false
        globalShortcut?.isPaused = false
    }

    var effectiveSection: SettingsSection {
        visibleSections.contains(selectedSection) ? selectedSection : .general
    }
}

/// 설정 화면: 왼쪽 탭 목록 + 오른쪽 내용 (한국어 라벨, AppPreferences 에 바로 바인딩)
struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    let model: SettingsModel

    static let windowSize = CGSize(width: 720, height: 620)

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = SettingsPalette.resolve(colorScheme)
        let section = model.effectiveSection

        HStack(spacing: 0) {
            sidebar(palette: palette, selected: section)
                .frame(width: 184)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(palette.sidebarBackground)

            Rectangle()
                .fill(palette.separator)
                .frame(width: 0.5)

            IslandScrollable(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(section.title)
                        .font(.system(size: 20, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    switch section {
                    case .general:
                        generalSection
                    case .display:
                        displaySection
                    case .shortcuts:
                        shortcutsSection
                    case .version:
                        if let provider = model.updateProvider {
                            VersionSettingsView(provider: provider, model: model)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(palette.windowBackground)
        .overlay {
            if let provider = model.updateProvider {
                UpgradeOverlay(provider: provider, model: model)
            }
        }
        .tint(SettingsPalette.accent)
        .font(.system(size: 13))
    }

    // MARK: - 탭 목록

    private func sidebar(palette: SettingsPalette, selected: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AgentNotch")
                    .font(.system(size: 15, weight: .semibold))
                if !model.appVersion.isEmpty {
                    Text(model.appVersion)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)

            ForEach(model.visibleSections) { section in
                Button {
                    model.selectedSection = section
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: section.symbolName)
                            .frame(width: 18)
                            .foregroundStyle(section == selected ? SettingsPalette.accent : Color.secondary)
                        Text(section.title)
                        Spacer(minLength: 0)
                        if section == .version, model.updateProvider?.hasUpdate == true {
                            Circle()
                                .fill(SettingsPalette.accent)
                                .frame(width: 7, height: 7)
                                .accessibilityLabel("새 버전")
                        }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(
                        section == selected ? palette.selection : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 22)
    }

    // MARK: - 일반

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "권한 요청") {
                switchRow("터미널이 앞에 있으면 권한 요청을 터미널로 넘기기", isOn: $preferences.passthroughWhenTerminalFrontmost)
                SettingsDivider()
                SettingsRow(title: "권한 대기 시간", note: "지나면 Claude Code 기본 프롬프트로 넘겨요") {
                    SettingsStepper(value: $preferences.permissionTimeout, range: 15...540, step: 15) { "\(Int($0))초" }
                }
            }

            SettingsGroup(title: "세션") {
                switchRow(
                    "앱을 켤 때 돌고 있던 세션 바로 보여주기",
                    note: "최근 30분 안의 Claude Code 대화 기록 끝부분을 읽어요 (읽기만 하고 저장하지 않아요)",
                    isOn: $preferences.restoresRecentSessions
                )
            }

            SettingsGroup(title: "Claude Code 훅") {
                SettingsRow(title: "상태") {
                    Text(model.hookStatusText)
                        .foregroundStyle(model.hooksInstalled ? .primary : .secondary)
                        .multilineTextAlignment(.trailing)
                }
                SettingsDivider()
                HStack(spacing: 8) {
                    Button(model.hooksInstalled ? "다시 설치" : "설치") {
                        model.installHooks()
                    }
                    Button("제거") {
                        model.uninstallHooks()
                    }
                    .disabled(!model.hooksInstalled)
                    Spacer(minLength: 0)
                }
                .buttonStyle(SettingsButtonStyle())
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                if let error = model.hookError {
                    SettingsNote(text: error, systemImage: "exclamationmark.triangle.fill", tint: SettingsPalette.red, emphasized: true)
                        .textSelection(.enabled)
                }
            }

            SettingsGroup(title: "일반") {
                switchRow(
                    "로그인 시 실행",
                    note: model.launchAtLoginManagedByHomebrew ? "brew services 로 관리 중" : nil,
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                .disabled(model.launchAtLoginManagedByHomebrew)
                if let error = model.loginError {
                    SettingsNote(text: error, systemImage: "exclamationmark.triangle.fill", tint: SettingsPalette.red, emphasized: true)
                }
                SettingsDivider()
                SettingsRow(title: "버전") {
                    Text(model.appVersion)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                SettingsDivider()
                SettingsRow(title: "설정 초기화", note: "이 창의 설정을 처음 값으로 되돌려요. 훅 설치와 로그인 시 실행은 그대로예요") {
                    resetControl
                }
            }
        }
    }

    /// 초기화 버튼. 한 번 누르면 취소 · 초기화로 바뀌어 한 번 더 확인한다
    @ViewBuilder
    private var resetControl: some View {
        if model.confirmingReset {
            HStack(spacing: 6) {
                Button("취소") { model.confirmingReset = false }
                    .buttonStyle(SettingsButtonStyle())
                Button("초기화") {
                    preferences.resetToDefaults()
                    model.confirmingReset = false
                }
                .buttonStyle(SettingsButtonStyle(prominent: true, destructive: true))
            }
            .fixedSize()
        } else {
            Button("초기화…") { model.confirmingReset = true }
                .buttonStyle(SettingsButtonStyle())
                .fixedSize()
        }
    }

    // MARK: - 표시

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "표시") {
                SettingsRow(title: "표시 화면") {
                    SettingsMenuPicker(title: "표시 화면", selection: $preferences.displayPolicy, options: [
                        (.allScreens, "모든 화면"),
                        (.activeScreen, "마우스가 있는 화면"),
                        (.builtInOnly, "내장 화면만"),
                    ])
                }
                SettingsDivider()
                SettingsRow(title: "풀스크린에서") {
                    SettingsMenuPicker(title: "풀스크린에서", selection: $preferences.fullscreenBehavior, options: [
                        (.showAll, "전부 표시"),
                        (.alertsOnly, "알림만"),
                        (.hide, "숨김"),
                    ])
                }
                SettingsDivider()
                switchRow("파일 수정 시 미리보기", isOn: $preferences.peekOnEdit)
                SettingsDivider()
                secondsSlider("미리보기 표시 시간", value: $preferences.peekDuration, range: 1...8, step: 0.5)
                    .disabled(!preferences.peekOnEdit)
                SettingsDivider()
                secondsSlider("완료 표시 시간", value: $preferences.completionDisplayDuration, range: 2...15, step: 1)
                SettingsDivider()
                switchRow("응답 스트리밍 표시", isOn: $preferences.showStreamingText)
            }

            SettingsGroup(title: "여러 세션") {
                switchRow(
                    "세션 자동으로 넘기기",
                    note: "활동 중인 세션이 여럿이면 접힌 아일랜드가 번갈아 보여줘요. 펼친 목록에서 세션을 우클릭해 고정하면 그 세션만 보여줘요.",
                    isOn: $preferences.rotatesSessions
                )
                SettingsDivider()
                secondsSlider("넘기는 간격", value: $preferences.sessionRotationInterval, range: 3...15, step: 1)
                    .disabled(!preferences.rotatesSessions)
            }

            SettingsGroup(title: "외부 모니터") {
                SettingsRow(title: "외부 모니터 표시", note: "노치 없는 화면에서 접힌 아일랜드를 둘 곳") {
                    SettingsMenuPicker(title: "외부 모니터 표시", selection: $preferences.externalDisplayStyle, options: [
                        (.inMenuBar, "메뉴바 안"),
                        (.belowMenuBar, "메뉴바 아래"),
                        (.hidden, "표시 안 함"),
                    ])
                }
            }
        }
    }

    // MARK: - 단축키

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsNote(
                text: "단축키는 처음엔 모두 꺼져 있어요. 쓰려는 것만 켜 주세요.",
                systemImage: "info.circle"
            )

            SettingsGroup(title: "어디서든") {
                switchRow(
                    "노치 펼치기 · 접기",
                    note: "다른 앱을 쓰는 중에도 이 키로 아일랜드를 펼치고 접어요",
                    isOn: $preferences.globalShortcutEnabled
                )
                SettingsDivider()
                SettingsRow(
                    title: "키",
                    note: model.isRecordingShortcut ? "새 키 조합을 눌러 주세요 (⌘ · ⌃ · ⌥ 중 하나 포함, esc 취소)" : nil
                ) {
                    shortcutRecorder
                }
                .disabled(!preferences.globalShortcutEnabled)
                if preferences.globalShortcutEnabled, model.globalShortcut?.registrationFailed == true, !model.isRecordingShortcut {
                    SettingsNote(
                        text: "다른 앱이 이미 \(preferences.globalShortcut.displayString) 을 써서 등록하지 못했어요. 다른 키로 바꿔 주세요.",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: SettingsPalette.orange,
                        emphasized: true
                    )
                }
            }

            SettingsGroup(title: "알림 카드 (아일랜드를 눌러 선택한 동안만)") {
                switchRow("권한 결정", note: "⌘↩ 허용 · ⌥⌘↩ 항상 허용 · ⌘⌫ 거부", isOn: $preferences.permissionShortcutsEnabled)
                SettingsDivider()
                switchRow(
                    "질문 · 계획 승인",
                    note: "1–4 선택지 · ↩ 다음 · 보내기 · 승인 (\"기타\" 입력란의 ↩ 포함)",
                    isOn: $preferences.interactionShortcutsEnabled
                )
                SettingsDivider()
                switchRow("접기", note: "esc 로 카드 접기 (요청은 그대로 기다려요)", isOn: $preferences.collapseShortcutEnabled)
            }
        }
    }

    /// 어디서든 펼치기 키: 누르면 녹화, 기본값과 다르면 되돌리기
    private var shortcutRecorder: some View {
        HStack(spacing: 6) {
            if preferences.globalShortcut != .defaultToggle, !model.isRecordingShortcut {
                Button("기본값") {
                    preferences.globalShortcut = .defaultToggle
                }
                .buttonStyle(SettingsButtonStyle())
            }
            Button {
                if model.isRecordingShortcut {
                    model.stopRecordingShortcut()
                } else {
                    let preferences = preferences
                    model.startRecordingShortcut { preferences.globalShortcut = $0 }
                }
            } label: {
                Text(model.isRecordingShortcut ? "키를 눌러 주세요…" : preferences.globalShortcut.displayString)
                    .monospacedDigit()
                    .frame(minWidth: 72)
            }
            .buttonStyle(SettingsButtonStyle(prominent: model.isRecordingShortcut))
            .accessibilityLabel(model.isRecordingShortcut ? "키 녹화 중, 누르면 취소" : "단축키 \(preferences.globalShortcut.displayString), 누르면 바꾸기")
        }
        .fixedSize()
    }

    // MARK: - 부품

    private func switchRow(_ title: String, note: String? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(SettingsSwitchStyle())
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func secondsSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        SettingsRow(title: title) {
            HStack(spacing: 8) {
                SettingsSlider(title: title, value: value, range: range, step: step)
                Text(Self.secondsText(value.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    private static func secondsText(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))초" : String(format: "%.1f초", value)
    }
}

/// 설정 창 (한 개만 유지)
@MainActor
final class SettingsWindowController {
    private let preferences: AppPreferences
    private let model: SettingsModel
    private var window: NSWindow?

    init(preferences: AppPreferences, provider: SettingsProvider) {
        self.preferences = preferences
        self.model = SettingsModel(provider: provider)
    }

    func setUpdateProvider(_ provider: UpdateProvider?) {
        model.updateProvider = provider
    }

    func show(section: SettingsSection?) {
        model.refresh()
        if let section { model.selectedSection = section }
        model.deferredUpgradeReady = false
        model.confirmingForceQuit = false
        model.confirmingReset = false
        model.stopRecordingShortcut()
        let window = self.window ?? makeWindow()
        self.window = window
        // 메뉴바 앱(액세서리)이라 창을 앞으로 가져오려면 앱 활성화가 필요하다
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsView(preferences: preferences, model: model)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "AgentNotch 설정"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(SettingsView.windowSize)
        window.center()
        // 녹화하던 중 창을 닫으면 녹화를 끝낸다 (전역 단축키를 다시 등록)
        let model = model
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { model.stopRecordingShortcut() }
        }
        return window
    }
}
