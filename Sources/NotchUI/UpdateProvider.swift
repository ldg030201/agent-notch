import Foundation

/// 설정 "버전" 탭과 펼친 아일랜드 헤더가 쓰는 업데이트 상태와 동작.
/// App 이 구현해 `NotchUIController.updateProvider` 로 주입한다 (구현 객체는 `@Observable` 이어야 화면이 갱신된다).
///
/// NOTE: 공개 시그니처는 App 과 NotchUI 가 함께 의존하는 계약이다. 바꿀 때는 App 구현(`AppUpdateProvider`)과 스냅숏 대역(`SnapshotUpdateProvider`)을 함께 고친다.
@MainActor
public protocol UpdateProvider: AnyObject {
    /// 지금 실행 중인 버전 (예: "0.1.0")
    var currentVersion: String { get }
    /// 원격 변경 내역에서 찾은 최신 출시 버전 (모르면 nil)
    var latestVersion: String? { get }
    /// 새 버전이 있는지
    var hasUpdate: Bool { get }
    var isChecking: Bool { get }
    var lastCheckedAt: Date? { get }
    /// 마지막 확인 실패 이유 (성공하면 nil)
    var errorText: String? { get }
    /// 하루 한 번 새 버전 확인 (AppPreferences.checksForUpdates 와 연결)
    var checksForUpdates: Bool { get set }
    /// 변경 내역 (최신이 먼저)
    var changelog: [ChangelogDisplayEntry] { get }
    func checkNow()

    /// `brew upgrade` 진행 상태
    var upgradePhase: UpgradePhase { get }
    /// 진행 로그 (뒤쪽 일부만 유지)
    var upgradeLog: String { get }
    func startUpgrade()
    func cancelUpgrade()
    /// 실패 화면 "닫기": 단계를 처음(`.idle`)으로 돌린다. 다음 실행이 같은 이유로 실패해도 다시 보인다
    func dismissUpgrade()
    /// 업그레이드가 끝난 뒤 앱을 교체하고 다시 띄운다
    func relaunchAfterUpgrade()
    /// 교체가 멈췄을 때 강제 종료
    func forceQuit()
}

public enum UpgradePhase: Equatable, Sendable {
    case idle
    case running
    /// 새 버전을 받음 — 다시 띄우기를 기다림
    case ready
    case swapping
    case failed(String)
}

/// 화면 표시용 변경 내역 한 버전
public struct ChangelogDisplayEntry: Identifiable, Hashable, Sendable {
    public var id: String { version }
    public var version: String
    /// nil 이면 아직 출시 전
    public var date: String?
    public var groups: [Group]

    public struct Group: Hashable, Sendable {
        public var title: String
        /// 제목 앞 아이콘 (SF Symbol 이름, 없으면 점)
        public var icon: String?
        /// 묶음 전체가 새 기능이면 제목에 한 번만 표시하고 줄마다 갈래를 붙이지 않는다
        public var isNew: Bool
        public var notes: [Note]
        public init(title: String, icon: String? = nil, isNew: Bool = false, notes: [Note]) {
            self.title = title
            self.icon = icon
            self.isNew = isNew
            self.notes = notes
        }
    }

    public struct Note: Hashable, Sendable {
        /// new / improve / change / fix / remove
        public var kind: String
        public var text: String
        public init(kind: String, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public init(version: String, date: String?, groups: [Group]) {
        self.version = version
        self.date = date
        self.groups = groups
    }
}
