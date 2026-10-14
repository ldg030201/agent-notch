import AppKit
import NotchShared
import os

/// 아일랜드와 겹치는 다른 앱 창 찾기 (열린 메뉴 · 팝오버, 다른 노치 앱)
enum OverlapScanner {
    struct Target: Sendable {
        var id: ScreenID
        /// 화면 전체 (Cocoa 전역)
        var screenFrame: CGRect
        /// 아일랜드 + 펼쳐질 카드 자리 (Cocoa 전역). 여기와 겹치면 알림 펼침을 미루고 일시 펼침을 접는다
        var zone: CGRect
        /// 지금 아일랜드 + 바로 아래 메뉴바에서 내려오는 메뉴가 닿는 띠 (Cocoa 전역). 여기와 겹쳐야 접힌 상태를 숨긴다
        var island: CGRect
        /// 하드웨어 노치 사각형 (Cocoa 전역, 노치 없는 화면이면 nil)
        var notchRect: CGRect?
        /// 접힌 상태를 새로 숨겨도 되는지 (모양이 바뀌는 중이거나 마우스가 아일랜드 위면 false — 이미 숨긴 건 유지)
        var allowsNewConcealment = true
    }

    struct Candidate: Sendable, Hashable {
        var windowNumber: Int
        var ownerName: String
        var screenID: ScreenID
        /// 우리 앱 창 (우리 메뉴를 여는 동안만 후보가 된다)
        var isOwn: Bool
        /// 팝업 메뉴 레벨 이상이고 아일랜드 + 카드 자리와 겹침
        var overlapsZone: Bool
        /// 그중 지금 아일랜드 (+ 바로 아래 띠) 와도 겹침
        var overlapsIsland: Bool
        /// 노치 사각형과 겹침 (다른 노치 앱 후보)
        var overlapsNotch: Bool
    }

    /// 거의 투명한 창은 보지 않는다
    static let minAlpha = 0.05
    /// 한 변이라도 이보다 짧은 창(화면 테두리 띠 · 커서 장식 등)은 보지 않는다
    static let minSide: CGFloat = 8

    /// 후보: 우리 패널 레벨 이상인 다른 앱 창 (`includeOwnPopups` 면 우리 메뉴 창도).
    /// 투명한 창 · 아주 작은 창 · 화면 전체를 덮거나 화면 끝에서 끝까지 걸친 오버레이(테두리 · 가림막)는 메뉴로 보지 않는다.
    static func scan(
        _ snapshot: WindowSnapshot,
        targets: [Target],
        ownPID: Int,
        ourLevel: Int,
        includeOwnPopups: Bool
    ) -> [Candidate] {
        var result: [Candidate] = []
        for window in snapshot.windows {
            guard window.alpha >= minAlpha,
                  window.layer >= ourLevel, window.layer < WindowLevels.systemTop,
                  window.frame.width >= minSide, window.frame.height >= minSide
            else { continue }
            let isOwn = window.pid == ownPID
            if isOwn, !(includeOwnPopups && window.layer >= WindowLevels.popUpMenu) { continue }

            for target in targets {
                let rect = window.frame
                guard rect.intersects(target.screenFrame), !isScreenOverlay(rect, screen: target.screenFrame) else { continue }

                let isPopup = window.layer >= WindowLevels.popUpMenu
                let overlapsZone = isPopup && area(rect.intersection(target.zone)) > 4
                let overlapsIsland = overlapsZone && area(rect.intersection(target.island)) > 4
                let overlapsNotch = !isOwn && (target.notchRect.map { area(rect.intersection($0)) > 16 } ?? false)
                guard overlapsZone || overlapsNotch else { continue }
                result.append(Candidate(
                    windowNumber: window.number,
                    ownerName: window.ownerName ?? "알 수 없는 앱",
                    screenID: target.id,
                    isOwn: isOwn,
                    overlapsZone: overlapsZone,
                    overlapsIsland: overlapsIsland,
                    overlapsNotch: overlapsNotch
                ))
            }
        }
        return result
    }

    /// 화면 전체 오버레이 · 화면 테두리 · 가림막: 화면 넓이 대부분을 덮거나, 화면 폭 거의 끝까지 걸치거나,
    /// 화면 맨 위부터 높이 거의 끝까지 걸친 창 (메뉴 · 팝오버는 이렇게 넓거나 메뉴바부터 길지 않다)
    static func isScreenOverlay(_ rect: CGRect, screen: CGRect) -> Bool {
        let covered = rect.intersection(screen)
        guard !covered.isNull else { return false }
        if covered.width * covered.height >= screen.width * screen.height * 0.8 { return true }
        if covered.width >= screen.width * 0.9 { return true }
        return covered.height >= screen.height * 0.9 && covered.maxY >= screen.maxY - 2
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
    }
}

/// 아일랜드가 보이는 동안 0.25초마다 창 목록을 보고
/// - 열린 메뉴 · 팝오버가 아일랜드 + 카드 자리와 겹치는 화면 (`occluded`) · 그중 접힌 아일랜드에 닿아 숨길 화면 (`concealed`)
/// - 노치에 1초 넘게 떠 있는 다른 앱 창 (`notchConflicts`, 앱 이름)
/// 을 알린다.
///
/// 잠깐 떴다 사라지는 창(다른 앱의 전체 화면 효과 · 클릭 가림막 등)에 아일랜드가 깜빡이지 않게:
/// 다른 앱 창은 같은 창이 연달아 두 번(약 0.25초 이상) 보여야 새로 겹침으로 보고, 겹친 창이 하나도 없으면 바로 푼다.
/// 이미 겹친 화면은 창이 바뀌어도(메뉴바에서 옆 메뉴로 옮겨 열기) 겹친 창이 있는 동안 그대로 둔다.
/// 우리 메뉴(상태 아이템 메뉴)는 바로 반영한다. 접힌 상태를 새로 숨기는 건 모양이 바뀌는 중 · 마우스가 아일랜드 위일 때 미룬다.
@MainActor
final class OverlapMonitor {
    struct State: Equatable {
        var occluded: Set<ScreenID> = []
        /// `occluded` 중 접힌 아일랜드를 투명하게 숨길 화면
        var concealed: Set<ScreenID> = []
        var notchConflicts: [ScreenID: String] = [:]
    }

    /// 겹친 창 하나 (창 번호 · 화면)
    struct Sighting: Hashable {
        var window: Int
        var screen: ScreenID
    }

    /// 조회 사이에 기억하는 것: 노치에서 처음 본 시각 · 아일랜드 자리와 겹친 창을 처음 본 시각과 연달아 본 횟수
    struct Tracking {
        var notchSeen: [Int: Date] = [:]
        var zoneSeen: [Sighting: (first: Date, scans: Int)] = [:]
    }

    var onChange: ((State) -> Void)?
    /// 감시할 화면과 영역 (아일랜드가 보이는 화면만)
    var targetsProvider: () -> [OverlapScanner.Target] = { [] }
    var ourLevel = NSWindow.Level.statusBar.rawValue + 8

    private(set) var state = State()
    /// 우리 앱 메뉴(상태 아이템 메뉴)가 열려 있는지
    private var ownMenuOpen = false
    /// 노치 · 아일랜드 자리에서 본 창 (조회 사이에 기억)
    private var tracking = Tracking()
    private var pollTask: Task<Void, Never>?
    private var scanInFlight = false
    /// 마지막 확인 때 감시할 화면이 없었는지
    private var watchingNothing = true
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var running = false

    private static let pollInterval: Duration = .milliseconds(250)
    private static let idleInterval: Duration = .seconds(1)
    /// 이 시간 넘게 노치에 있으면 다른 노치 앱으로 본다
    private static let notchPersistence: TimeInterval = 1
    /// 다른 앱 창이 겹침으로 인정되려면 연달아 보여야 하는 조회 횟수 · 최소 시간 (메뉴 · 팝오버는 이보다 오래 열려 있다)
    static let zoneScans = 2
    static let zonePersistence: TimeInterval = 0.2
    private let logger = Logger(subsystem: NotchWire.logSubsystem, category: "Overlap")

    /// `isIslandHit` 은 마우스 위치가 아일랜드 위인지 (아일랜드 안 컨텍스트 메뉴는 겹침으로 보지 않기 위함)
    func start(isIslandHit: @escaping @MainActor (CGPoint) -> Bool) {
        guard !running else { return }
        running = true
        let center = NotificationCenter.default
        let begin = center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 아일랜드 안에서 연 메뉴(세션 목록 컨텍스트 메뉴)는 제외
                self.ownMenuOpen = !isIslandHit(NSEvent.mouseLocation)
                self.scanNow()
            }
        }
        let end = center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ownMenuOpen = false
                self?.scanNow()
            }
        }
        tokens = [(center, begin), (center, end)]
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // 아일랜드가 안 보이면(감시할 화면 없음) 드물게 깨어난다
                let idle = self?.watchingNothing ?? true
                try? await Task.sleep(for: idle ? Self.idleInterval : Self.pollInterval)
                guard let self, self.running else { return }
                self.scanNow()
            }
        }
    }

    func stop() {
        running = false
        pollTask?.cancel()
        pollTask = nil
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        tracking = Tracking()
        ownMenuOpen = false
        update(State())
    }

    func scanNow() {
        guard running, !scanInFlight else { return }
        let targets = targetsProvider()
        watchingNothing = targets.isEmpty && !ownMenuOpen
        guard !targets.isEmpty else {
            tracking = Tracking()
            update(State(notchConflicts: state.notchConflicts))
            return
        }
        scanInFlight = true
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        let level = ourLevel
        let includeOwn = ownMenuOpen

        Task { @MainActor [weak self] in
            let candidates = await Task.detached(priority: .userInitiated) {
                OverlapScanner.scan(
                    WindowSnapshot.capture(primaryHeight: primaryHeight),
                    targets: targets,
                    ownPID: ownPID,
                    ourLevel: level,
                    includeOwnPopups: includeOwn
                )
            }.value
            guard let self else { return }
            self.scanInFlight = false
            guard self.running else { return }
            self.classify(candidates, targets: targets)
        }
    }

    private func classify(_ candidates: [OverlapScanner.Candidate], targets: [OverlapScanner.Target]) {
        update(Self.classify(candidates, targets: targets, previous: state, tracking: &tracking, now: Date()))
    }

    /// 조회 한 번의 결과 → 다음 상태 (순수 계산, 스냅숏 검사 `SnapshotOverlapCheck` 가 같은 함수를 돌린다)
    static func classify(
        _ candidates: [OverlapScanner.Candidate],
        targets: [OverlapScanner.Target],
        previous: State,
        tracking: inout Tracking,
        now: Date
    ) -> State {
        let screens = Set(targets.map(\.id))
        let allowsConcealment = Dictionary(targets.map { ($0.id, $0.allowsNewConcealment) }, uniquingKeysWith: { $0 && $1 })
        var next = State()
        // 감시하지 않은 화면의 노치 앱 정보는 유지 (아일랜드가 숨은 동안 깜빡이지 않게)
        next.notchConflicts = previous.notchConflicts.filter { !screens.contains($0.key) }

        let notchNumbers = Set(candidates.filter(\.overlapsNotch).map(\.windowNumber))
        tracking.notchSeen = tracking.notchSeen.filter { notchNumbers.contains($0.key) }
        for number in notchNumbers where tracking.notchSeen[number] == nil { tracking.notchSeen[number] = now }

        // 겹친 창을 연달아 본 횟수 (이번에 안 보인 창은 바로 잊는다 → 사라지면 바로 다시 보인다)
        var seen: [Sighting: (first: Date, scans: Int)] = [:]
        for candidate in candidates where candidate.overlapsZone {
            let key = Sighting(window: candidate.windowNumber, screen: candidate.screenID)
            let earlier = tracking.zoneSeen[key] ?? (now, 0)
            seen[key] = (earlier.first, earlier.scans + 1)
        }
        tracking.zoneSeen = seen

        for candidate in candidates {
            if candidate.overlapsNotch, let first = tracking.notchSeen[candidate.windowNumber],
               now.timeIntervalSince(first) >= notchPersistence {
                // 오래 떠 있는 노치 창 = 다른 노치 앱. 메뉴로 보지 않는다.
                next.notchConflicts[candidate.screenID] = candidate.ownerName
                continue
            }
            guard candidate.overlapsZone,
                  let sighting = seen[Sighting(window: candidate.windowNumber, screen: candidate.screenID)]
            else { continue }
            let screen = candidate.screenID
            let persistent = isPersistent(isOwn: candidate.isOwn, scans: sighting.scans, age: now.timeIntervalSince(sighting.first))
            // 지속 조건은 새로 겹칠 때만. 이미 겹친 화면은 창이 바뀌어도(메뉴를 옮겨 열면 창 번호가 바뀜) 후보가 있는 동안 유지
            guard persistent || previous.occluded.contains(screen) else { continue }
            next.occluded.insert(screen)
            // 이미 숨긴 화면은 아일랜드에 닿는 후보가 있는 동안 그대로,
            // 새로 숨기는 건 지속된 창이고 모양이 자리 잡고 마우스가 아일랜드 밖일 때만
            if candidate.overlapsIsland,
               previous.concealed.contains(screen) || (persistent && allowsConcealment[screen] ?? true) {
                next.concealed.insert(screen)
            }
        }
        return next
    }

    /// 겹침으로 인정할지: 우리 메뉴는 바로, 다른 앱 창은 연달아 `zoneScans` 번 · `zonePersistence` 이상 보였을 때
    static func isPersistent(isOwn: Bool, scans: Int, age: TimeInterval) -> Bool {
        isOwn || (scans >= zoneScans && age >= zonePersistence)
    }

    private func update(_ next: State) {
        guard next != state else { return }
        if next.notchConflicts != state.notchConflicts {
            logger.info("다른 노치 앱 감지: \(next.notchConflicts.count, privacy: .public)개 화면")
        }
        state = next
        onChange?(next)
    }
}
