import AppKit
import ApplicationServices
import Observation
import SwiftUI
import NotchCore

/// 설정 화면 탭
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case display
    case version

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "일반"
        case .display: return "표시"
        case .version: return "버전"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .display: return "menubar.rectangle"
        case .version: return "arrow.down.circle"
        }
    }
}

/// SettingsProvider(관찰 불가 프로토콜) 값을 캐시해 SwiftUI 에 노출하는 모델
@MainActor
@Observable
final class SettingsModel {
    @ObservationIgnored private let provider: SettingsProvider
    @ObservationIgnored private let accessibilityCheck: () -> Bool
    /// 마지막 확인 시각 표시용 (스냅숏은 고정 시각)
    @ObservationIgnored let now: () -> Date
    /// 손쉬운 사용 권한이 바뀌면 호출 (메뉴바 측정 다시 하기)
    @ObservationIgnored var onAccessibilityChange: ((Bool) -> Void)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activeToken: NSObjectProtocol?

    private(set) var appVersion = ""
    private(set) var hookStatusText = ""
    private(set) var hooksInstalled = false
    private(set) var launchAtLoginEnabled = false
    private(set) var launchAtLoginManagedByHomebrew = false
    private(set) var hookError: String?
    private(set) var loginError: String?
    /// 손쉬운 사용 권한 (메뉴 위치 정확히 감지)
    private(set) var accessibilityTrusted = false

    var selectedSection: SettingsSection = .general
    /// 업데이트 상태 (없으면 버전 탭 숨김)
    var updateProvider: UpdateProvider?
    /// "나중에" · "닫기" 로 내린 업그레이드 단계 (단계가 바뀌면 다시 보인다)
    var dismissedUpgradePhase: UpgradePhase?
    /// 교체 중 강제 종료 확인 단계
    var confirmingForceQuit = false

    /// 값은 설정 창을 열 때 `refresh()` 로 읽는다
    init(
        provider: SettingsProvider,
        accessibilityCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.accessibilityCheck = accessibilityCheck
        self.now = now
    }

    func refresh() {
        appVersion = provider.appVersion
        hookStatusText = provider.hookStatusText
        hooksInstalled = provider.hooksInstalled
        launchAtLoginEnabled = provider.launchAtLoginEnabled
        launchAtLoginManagedByHomebrew = provider.launchAtLoginManagedByHomebrew
        refreshAccessibility()
    }

    func refreshAccessibility() {
        let trusted = accessibilityCheck()
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
            onAccessibilityChange?(trusted)
        }
    }

    /// 시스템 손쉬운 사용 권한 요청 창을 띄운다 (사용자가 시스템 설정에서 직접 허용)
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshAccessibility()
    }

    /// 시스템 설정 > 메뉴 막대를 연다. 그 화면으로 바로 못 가면 시스템 설정만 연다.
    func openMenuBarSettings() {
        let workspace = NSWorkspace.shared
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"), workspace.open(url) {
            return
        }
        if let app = workspace.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            workspace.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// 창이 열려 있는 동안 권한 변화를 본다 (시스템 설정에서 허용하고 돌아왔을 때 바로 반영):
    /// 몇 초마다 + 앱이 다시 앞으로 올 때
    func startWatching() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1500))
                self?.refreshAccessibility()
            }
        }
        if activeToken == nil {
            activeToken = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAccessibility() }
            }
        }
    }

    func stopWatching() {
        pollTask?.cancel()
        pollTask = nil
        if let activeToken {
            NotificationCenter.default.removeObserver(activeToken)
            self.activeToken = nil
        }
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
        updateProvider == nil ? [.general, .display] : SettingsSection.allCases
    }

    var effectiveSection: SettingsSection {
        visibleSections.contains(selectedSection) ? selectedSection : .general
    }
}

/// 설정 화면: 왼쪽 탭 목록 + 오른쪽 내용 (한국어 라벨, AppPreferences 에 바로 바인딩)
struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    let model: SettingsModel
    /// 다른 노치 앱 감지 정보 (없으면 표시 안 함)
    let presentation: PresentationController?

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
            }
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

            SettingsGroup(title: "메뉴바와 겹침") {
                SettingsRow(title: "노치 화면 표시", note: Self.notchStyleNote(preferences.notchStyle)) {
                    SettingsMenuPicker(title: "노치 화면 표시", selection: $preferences.notchStyle, options: [
                        (.belowNotch, "노치 아래 (노치 폭에 맞춤)"),
                        (.wings, "넓은 노치 (양옆을 검게)"),
                    ])
                }
                SettingsDivider()
                if preferences.notchStyle == .wings {
                    // 넓은 노치: 손쉬운 사용 권한이 있으면 아이콘 구멍, 없으면 마우스를 올릴 때 비켜주기
                    SettingsRow(
                        title: "날개 위 메뉴바 아이콘",
                        note: (model.accessibilityTrusted
                            ? "켜짐 · 아이콘이 날개 위에 보여요. 앞 앱 메뉴도 재서 왼쪽 날개가 메뉴를 덮지 않게 해요."
                            : "손쉬운 사용 권한이 있으면 아이콘이 날개 위에 보여요. 없으면 마우스를 올릴 때 날개가 비켜줘요.")
                            + " " + Self.adHocNote
                    ) {
                        accessibilityControl
                    }
                } else {
                    SettingsRow(title: "노치 옆이 막혔을 때", note: "노치 옆 메뉴바에 자리가 없으면 노치 아래에 이렇게 보여줘요") {
                        SettingsMenuPicker(title: "노치 옆이 막혔을 때", selection: $preferences.compactOverlapStyle, options: [
                            (.belowNotch, "노치 아래 띠"),
                            (.minimal, "선만"),
                        ])
                    }
                }
                SettingsDivider()
                SettingsRow(title: "외부 모니터 표시", note: "노치 없는 화면에서 접힌 아일랜드를 둘 곳") {
                    SettingsMenuPicker(title: "외부 모니터 표시", selection: $preferences.externalDisplayStyle, options: [
                        (.inMenuBar, "메뉴바 안"),
                        (.belowMenuBar, "메뉴바 아래"),
                        (.hidden, "표시 안 함"),
                    ])
                }
                if preferences.notchStyle == .belowNotch {
                    SettingsDivider()
                    SettingsRow(
                        title: "메뉴 위치 정확히 감지",
                        note: "손쉬운 사용 권한이 있으면 앞 앱 메뉴와 메뉴바 아이콘 위치를 재서 노치 옆이 비어 있으면 그 자리에 보여줘요. " + Self.adHocNote
                    ) {
                        accessibilityControl
                    }
                }
                ForEach(presentation?.notchConflictNames ?? [], id: \.self) { name in
                    SettingsDivider()
                    SettingsNote(
                        text: "다른 노치 앱 감지됨: \(name) — 겹치지 않게 노치 아래로 내려서 보여줘요",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: SettingsPalette.orange,
                        emphasized: true
                    )
                }
            }

            SettingsGroup(title: "메뉴바 아이콘") {
                SettingsNote(
                    text: "macOS 27 은 아이콘이 넘치면 « 버튼 뒤로 자동으로 접어요. 노치 옆 아이콘이 먼저 접히고, ⌘-드래그로 순서를 바꿀 수 있어요. 시스템 설정 > 메뉴 막대에서 아이콘을 숨길 수도 있어요.",
                    systemImage: "info.circle"
                )
                SettingsDivider()
                HStack(spacing: 8) {
                    Button("메뉴 막대 설정 열기") {
                        model.openMenuBarSettings()
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(SettingsButtonStyle())
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
    }

    /// 손쉬운 사용 권한은 서명 신원에 묶여서 ad-hoc 서명 앱은 업데이트마다 다시 물을 수 있다
    private static let adHocNote = "직접 빌드한 앱(ad-hoc 서명)은 업데이트한 뒤 다시 허용해야 할 수 있어요."

    /// 손쉬운 사용 권한 상태 (허용됨 표시 또는 요청 버튼)
    @ViewBuilder
    private var accessibilityControl: some View {
        if model.accessibilityTrusted {
            Label("허용됨", systemImage: "checkmark.circle.fill")
                .foregroundStyle(SettingsPalette.green)
                .fixedSize()
        } else {
            Button("손쉬운 사용 권한 요청") {
                model.requestAccessibility()
            }
            .buttonStyle(SettingsButtonStyle())
            .fixedSize()
        }
    }

    /// 노치 화면 표시 방식 설명
    private static func notchStyleNote(_ style: NotchStyle) -> String {
        switch style {
        case .wings: return "노치 양옆 메뉴바 자리를 검게 칠해 노치가 넓어 보여요. 메뉴바 아이콘은 날개 위에 보여요."
        case .belowNotch: return "메뉴바를 가리지 않고 노치 바로 아래에 노치 폭만큼 내려 보여줘요."
        }
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
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let preferences: AppPreferences
    private let model: SettingsModel
    private let presentation: PresentationController
    private var window: NSWindow?

    init(preferences: AppPreferences, provider: SettingsProvider, presentation: PresentationController) {
        self.preferences = preferences
        self.model = SettingsModel(provider: provider)
        self.presentation = presentation
        super.init()
    }

    var onAccessibilityChange: ((Bool) -> Void)? {
        get { model.onAccessibilityChange }
        set { model.onAccessibilityChange = newValue }
    }

    func setUpdateProvider(_ provider: UpdateProvider?) {
        model.updateProvider = provider
    }

    func show(section: SettingsSection?) {
        model.refresh()
        if let section { model.selectedSection = section }
        model.dismissedUpgradePhase = nil
        model.confirmingForceQuit = false
        let window = self.window ?? makeWindow()
        self.window = window
        model.startWatching()
        // 메뉴바 앱(액세서리)이라 창을 앞으로 가져오려면 앱 활성화가 필요하다
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        model.stopWatching()
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsView(preferences: preferences, model: model, presentation: presentation)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "AgentNotch 설정"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(SettingsView.windowSize)
        window.center()
        return window
    }
}
