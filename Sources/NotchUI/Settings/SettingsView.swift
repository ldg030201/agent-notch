import AppKit
import Observation
import SwiftUI
import NotchCore

/// SettingsProvider(관찰 불가 프로토콜) 값을 캐시해 SwiftUI 에 노출하는 모델
@MainActor
@Observable
final class SettingsModel {
    @ObservationIgnored private let provider: SettingsProvider

    private(set) var appVersion = ""
    private(set) var hookStatusText = ""
    private(set) var hooksInstalled = false
    private(set) var launchAtLoginEnabled = false
    private(set) var launchAtLoginManagedByHomebrew = false
    private(set) var hookError: String?
    private(set) var loginError: String?

    /// 값은 설정 창을 열 때 `refresh()` 로 읽는다
    init(provider: SettingsProvider) {
        self.provider = provider
    }

    func refresh() {
        appVersion = provider.appVersion
        hookStatusText = provider.hookStatusText
        hooksInstalled = provider.hooksInstalled
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
}

/// 설정 화면 (한국어 라벨, AppPreferences 에 바로 바인딩)
struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    let model: SettingsModel

    var body: some View {
        Form {
            Section("표시") {
                Picker("표시 화면", selection: $preferences.displayPolicy) {
                    Text("모든 화면").tag(DisplayPolicy.allScreens)
                    Text("마우스가 있는 화면").tag(DisplayPolicy.activeScreen)
                    Text("내장 화면만").tag(DisplayPolicy.builtInOnly)
                }
                Picker("풀스크린에서", selection: $preferences.fullscreenBehavior) {
                    Text("전부 표시").tag(FullscreenBehavior.showAll)
                    Text("알림만").tag(FullscreenBehavior.alertsOnly)
                    Text("숨김").tag(FullscreenBehavior.hide)
                }
                Toggle("파일 수정 시 미리보기", isOn: $preferences.peekOnEdit)
                secondsSlider(
                    "미리보기 표시 시간",
                    value: $preferences.peekDuration,
                    range: 1...8,
                    step: 0.5
                )
                .disabled(!preferences.peekOnEdit)
                secondsSlider(
                    "완료 표시 시간",
                    value: $preferences.completionDisplayDuration,
                    range: 2...15,
                    step: 1
                )
                Toggle("응답 스트리밍 표시", isOn: $preferences.showStreamingText)
            }

            Section("권한 요청") {
                Toggle("터미널이 앞에 있으면 권한 요청을 터미널로 넘기기", isOn: $preferences.passthroughWhenTerminalFrontmost)
                Stepper(value: $preferences.permissionTimeout, in: 15...540, step: 15) {
                    LabeledContent("권한 대기 시간(초)") {
                        Text("\(Int(preferences.permissionTimeout))초")
                            .monospacedDigit()
                    }
                }
            }

            Section("Claude Code 훅") {
                LabeledContent("상태") {
                    Text(model.hookStatusText)
                        .foregroundStyle(model.hooksInstalled ? .primary : .secondary)
                }
                HStack {
                    Button(model.hooksInstalled ? "다시 설치" : "설치") {
                        model.installHooks()
                    }
                    Button("제거") {
                        model.uninstallHooks()
                    }
                    .disabled(!model.hooksInstalled)
                }
                if let error = model.hookError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section("일반") {
                Toggle("로그인 시 실행", isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .disabled(model.launchAtLoginManagedByHomebrew)
                if model.launchAtLoginManagedByHomebrew {
                    Text("brew services 로 관리 중")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = model.loginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                LabeledContent("버전", value: model.appVersion)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 520, idealHeight: 640)
    }

    private func secondsSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: step)
                    .frame(width: 160)
                    .accessibilityLabel(title)
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

    func show() {
        model.refresh()
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
        let hosting = NSHostingController(rootView: SettingsView(preferences: preferences, model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "AgentNotch 설정"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 460, height: 640))
        window.center()
        return window
    }
}
