import Foundation
import NotchCore
import NotchServices
import NotchUI
import Observation

/// 설정 "버전" 탭 · 펼친 아일랜드 헤더가 쓰는 업데이트 상태 (NotchUI.UpdateProvider 구현).
///
/// `UpdateChecker`(새 버전 확인) · `Upgrader`(brew upgrade · 교체) · `AppPreferences.checksForUpdates` 를 잇는다.
/// 값은 모두 관찰 가능한 원본에서 그대로 읽으므로 SwiftUI 가 원본 변화를 따라간다.
@MainActor
@Observable
final class AppUpdateProvider: UpdateProvider {
    private let preferences: AppPreferences
    let checker: UpdateChecker
    let upgrader: Upgrader
    @ObservationIgnored private var started = false

    init(preferences: AppPreferences, checker: UpdateChecker, upgrader: Upgrader) {
        self.preferences = preferences
        self.checker = checker
        self.upgrader = upgrader
    }

    /// 앱이 가진 내역 · 버전으로 만든다
    convenience init(preferences: AppPreferences) {
        let checker = UpdateChecker(
            currentVersion: AppInfo.version,
            embeddedEntries: Changelog.entries,
            feedURL: Changelog.feedURL,
            isTestBuild: AppInfo.isTestBuild
        )
        let upgrader = Upgrader(isTestBuild: AppInfo.isTestBuild, currentVersion: AppInfo.version)
        self.init(preferences: preferences, checker: checker, upgrader: upgrader)
    }

    // MARK: - 시작 · 멈춤

    /// 설정이 켜져 있으면 확인을 시작하고, 설정이 바뀔 때마다 켜고 끈다
    func start() {
        guard !started else { return }
        started = true
        followPreference()
    }

    func stop() {
        started = false
        checker.stop()
    }

    /// `checksForUpdates` 를 지켜보다 바뀌면 다시 건다 (withObservationTracking 은 한 번만 알린다)
    private func followPreference() {
        guard started else { return }
        let enabled = withObservationTracking {
            preferences.checksForUpdates
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.followPreference() }
            }
        }
        if enabled {
            checker.start()
        } else {
            checker.stop()
        }
    }

    // MARK: - UpdateProvider

    var currentVersion: String { checker.currentVersion }

    var latestVersion: String? { checker.latestVersion }

    var hasUpdate: Bool { checker.hasUpdate }

    var isChecking: Bool { checker.isChecking }

    var lastCheckedAt: Date? { checker.lastCheckedAt }

    var errorText: String? { checker.errorText }

    var checksForUpdates: Bool {
        get { preferences.checksForUpdates }
        set { preferences.checksForUpdates = newValue }
    }

    var changelog: [ChangelogDisplayEntry] {
        checker.entries.map(Self.displayEntry)
    }

    func checkNow() {
        checker.check()
    }

    var upgradePhase: UpgradePhase {
        switch upgrader.phase {
        case .idle: return .idle
        case .running: return .running
        case .ready: return .ready
        case .swapping: return .swapping
        case .failed(let reason): return .failed(reason)
        }
    }

    var upgradeLog: String { upgrader.log }

    /// 받은 번들이 새 버전인지 확인할 때 안내에 쓰도록, 새 버전 확인에서 본 최신 버전을 넘긴다
    func startUpgrade() {
        upgrader.start(latestVersion: checker.latestVersion)
    }

    func cancelUpgrade() {
        upgrader.cancel()
    }

    func dismissUpgrade() {
        upgrader.dismiss()
    }

    func relaunchAfterUpgrade() {
        upgrader.relaunch()
    }

    func forceQuit() {
        upgrader.forceQuit()
    }

    // MARK: - 변환

    /// 묶음이 없는 옛 형식은 평평한 목록을 한 묶음으로 보여준다
    static func displayEntry(_ entry: ChangelogEntry) -> ChangelogDisplayEntry {
        let groups: [ChangelogDisplayEntry.Group]
        if let source = entry.groups {
            groups = source.map { group in
                ChangelogDisplayEntry.Group(
                    title: group.title,
                    icon: group.icon,
                    isNew: group.isNew,
                    notes: group.notes.map { ChangelogDisplayEntry.Note(kind: $0.kind.rawValue, text: $0.text) }
                )
            }
        } else {
            groups = [ChangelogDisplayEntry.Group(
                title: "변경",
                notes: entry.notes.map { ChangelogDisplayEntry.Note(kind: ChangeKind.change.rawValue, text: $0) }
            )]
        }
        return ChangelogDisplayEntry(version: entry.version, date: entry.date, groups: groups)
    }
}
