import AppKit
import NotchCore
import NotchServices
import NotchShared
import NotchUI
import os

/// Codex 훅을 설치했는데 Codex 가 아직 실행하지 않는 것 같을 때 노치에 안내 카드를 한 번 띄운다.
///
/// Codex 는 새 · 바뀐 훅을 사용자가 검토해 믿어야 돌린다 (Codex 앱 훅 검토, CLI `/hooks`). 허용 전에는 Codex 세션이 노치에 그냥 안 떠서
/// 왜 안 되는지 알 수 없다. 믿음 기록(Codex `config.toml` 의 내부 형식)은 읽지 않고 실제 이벤트로 판단한다:
/// - Codex 훅 이벤트가 오면 그 훅 내용(지문)은 허용된 것 (`AppSettingsProvider.confirmCodexHooks`). 카드를 내린다
/// - 아직 이벤트를 못 받은 훅 내용이면, Codex 기록(`~/.codex/sessions`)이 훅을 설치한 뒤에 바뀌는데(= Codex 가 일하는 중)
///   `quietThreshold` 넘게 훅 이벤트가 없으면 카드를 띄운다. 같은 훅 내용으로는 한 번만 띄운다 (접어도, 버튼을 눌러도)
/// 훅을 통째로 끈 경우(`[features] hooks = false`)도 이벤트가 안 와서 같은 카드가 뜰 수 있어 문구를 단정하지 않는다
@MainActor
final class CodexHookMonitor {
    static let noticeID = IslandNotice.codexHooksID
    /// 허용을 기다리는 동안 Codex 활동을 살피는 주기 (초)
    static let pollInterval: TimeInterval = 10
    /// Codex 가 일하는데 훅 이벤트가 이만큼(초) 안 오면 안내한다 (허용된 훅이면 활동과 거의 함께 이벤트가 온다)
    static let quietThreshold: TimeInterval = 10
    /// 안내를 띄운 훅 지문 (같은 훅 내용으로는 다시 띄우지 않는다)
    static let noticeShownKey = "codexHooksNoticeShownFingerprint"

    private let settings: AppSettingsProvider
    private let ui: NotchUIController
    /// Codex 기록만 본다 (Claude Code 기록 폴더는 없는 경로)
    private let restorer: SessionRestorer
    private var timer: Timer?
    /// `start` 뒤에만 살핀다 (데모 · 시작 전 훅 고치기에서는 살피지 않는다)
    private var active = false
    private var scanning = false
    /// 훅 이벤트 없이 Codex 활동을 처음 본 시각
    private var quietSince: Date?
    private let log = Logger(subsystem: NotchServices.logSubsystem, category: "codex-hooks")

    init(settings: AppSettingsProvider, ui: NotchUIController) {
        self.settings = settings
        self.ui = ui
        var restorer = SessionRestorer(projectsDirectory: URL(fileURLWithPath: "/nonexistent-agentnotch"))
        restorer.activeWindow = 60
        self.restorer = restorer
    }

    func start() {
        active = true
        evaluate()
    }

    func stop() {
        active = false
        stopTimer()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// 훅을 설치 · 제거 · 고쳤다
    func hooksChanged() {
        quietSince = nil
        evaluate()
    }

    /// Codex 훅 이벤트가 왔다 (실제 훅만. 데모는 부르지 않는다)
    func noteCodexEvent() {
        guard settings.confirmCodexHooks() else { return }
        log.info("Codex 훅 이벤트 확인 (허용됨)")
        evaluate()
    }

    /// 안내 카드에서 버튼 · 접기
    func handle(_ response: IslandNotice.Response) {
        guard case let .action(id) = response, id == Self.noticeID else { return }
        openCodexApp()
    }

    // MARK: - 내부

    private func evaluate() {
        guard active, settings.codexHooksAwaitingTrust,
              UserDefaults.standard.string(forKey: Self.noticeShownKey) != settings.codexFingerprint
        else {
            stopTimer()
            quietSince = nil
            // 허용을 확인했거나 훅을 지웠으면 띄운 카드도 내린다
            if !settings.codexHooksAwaitingTrust { ui.setNotice(nil) }
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check() {
        // 다른 도구가 훅 파일을 바꿨을 수 있다
        settings.reloadCodexFingerprint()
        guard settings.codexHooksAwaitingTrust else { evaluate(); return }
        guard !scanning else { return }
        scanning = true
        let restorer = restorer
        let installedAt = settings.codexHooksModifiedAt ?? .distantPast
        Task { @MainActor [weak self] in
            // 기록 폴더 훑기는 메인 밖에서
            let latest = await Task.detached(priority: .utility) { restorer.latestCodexActivity() }.value
            guard let self else { return }
            self.scanning = false
            self.decide(latestActivity: latest, installedAt: installedAt)
        }
    }

    private func decide(latestActivity: Date?, installedAt: Date) {
        guard settings.codexHooksAwaitingTrust else { evaluate(); return }
        guard let latest = latestActivity, latest > installedAt else {
            quietSince = nil
            return
        }
        let now = Date()
        guard let since = quietSince else {
            quietSince = now
            return
        }
        guard now.timeIntervalSince(since) >= Self.quietThreshold else { return }
        showNotice()
    }

    private func showNotice() {
        UserDefaults.standard.set(settings.codexFingerprint, forKey: Self.noticeShownKey)
        stopTimer()
        log.info("Codex 가 일하는데 훅 이벤트가 없어 허용 안내를 띄움")
        ui.setNotice(.codexHooksAwaitingTrust(canOpenApp: codexAppURL != nil))
    }

    private var codexAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalContext.codexDesktopBundleID)
    }

    private func openCodexApp() {
        guard let url = codexAppURL else { return }
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: TerminalContext.codexDesktopBundleID)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }
}
