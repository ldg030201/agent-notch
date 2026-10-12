import AppKit
import os

/// 아일랜드와 겹치는 다른 앱 창 찾기 (열린 메뉴 · 팝오버, 다른 노치 앱)
enum OverlapScanner {
    struct Target: Sendable {
        var id: ScreenID
        /// 화면 전체 (Cocoa 전역)
        var screenFrame: CGRect
        /// 아일랜드 + 펼쳐질 카드 자리 (Cocoa 전역)
        var zone: CGRect
        /// 하드웨어 노치 사각형 (Cocoa 전역, 노치 없는 화면이면 nil)
        var notchRect: CGRect?
    }

    struct Candidate: Sendable, Hashable {
        var windowNumber: Int
        var ownerName: String
        var screenID: ScreenID
        /// 팝업 메뉴 레벨 이상이고 아일랜드 영역과 겹침
        var overlapsZone: Bool
        /// 노치 사각형과 겹침 (다른 노치 앱 후보)
        var overlapsNotch: Bool
    }

    /// - 후보: 우리 패널 레벨 이상인 다른 앱 창 (`includeOwnPopups` 면 우리 메뉴 창도), 보이고, 화면 대부분을 덮는 오버레이가 아닌 것
    static func scan(
        _ snapshot: WindowSnapshot,
        targets: [Target],
        ownPID: Int,
        ourLevel: Int,
        includeOwnPopups: Bool
    ) -> [Candidate] {
        var result: [Candidate] = []
        for window in snapshot.windows {
            guard window.alpha > 0.01,
                  window.layer >= ourLevel, window.layer < WindowLevels.systemTop,
                  window.frame.width >= 4, window.frame.height >= 4
            else { continue }
            let isOwn = window.pid == ownPID
            if isOwn, !(includeOwnPopups && window.layer >= WindowLevels.popUpMenu) { continue }

            for target in targets {
                let rect = window.frame
                guard rect.intersects(target.screenFrame) else { continue }
                // 화면 테두리 강조 같은 전체 화면 오버레이는 메뉴로 보지 않는다
                let covered = rect.intersection(target.screenFrame)
                if covered.width * covered.height >= target.screenFrame.width * target.screenFrame.height * 0.8 { continue }

                let isPopup = window.layer >= WindowLevels.popUpMenu
                let overlapsZone = isPopup && area(rect.intersection(target.zone)) > 4
                let overlapsNotch = !isOwn && (target.notchRect.map { area(rect.intersection($0)) > 16 } ?? false)
                guard overlapsZone || overlapsNotch else { continue }
                result.append(Candidate(
                    windowNumber: window.number,
                    ownerName: window.ownerName ?? "알 수 없는 앱",
                    screenID: target.id,
                    overlapsZone: overlapsZone,
                    overlapsNotch: overlapsNotch
                ))
            }
        }
        return result
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
    }
}

/// 아일랜드가 보이는 동안 0.25초마다 창 목록을 보고
/// - 열린 메뉴 · 팝오버가 아일랜드 자리와 겹치는 화면 (`occluded`)
/// - 노치에 1초 넘게 떠 있는 다른 앱 창 (`notchConflicts`, 앱 이름)
/// 을 알린다.
@MainActor
final class OverlapMonitor {
    struct State: Equatable {
        var occluded: Set<ScreenID> = []
        var notchConflicts: [ScreenID: String] = [:]
    }

    var onChange: ((State) -> Void)?
    /// 감시할 화면과 영역 (아일랜드가 보이는 화면만)
    var targetsProvider: () -> [OverlapScanner.Target] = { [] }
    var ourLevel = NSWindow.Level.statusBar.rawValue + 8

    private(set) var state = State()
    /// 우리 앱 메뉴(상태 아이템 메뉴)가 열려 있는지
    private var ownMenuOpen = false
    /// 창 번호 → 노치에서 처음 본 시각
    private var notchSeen: [Int: Date] = [:]
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
    private let logger = Logger(subsystem: "AgentNotch", category: "Overlap")

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
        notchSeen.removeAll()
        ownMenuOpen = false
        update(State())
    }

    func scanNow() {
        guard running, !scanInFlight else { return }
        let targets = targetsProvider()
        watchingNothing = targets.isEmpty && !ownMenuOpen
        guard !targets.isEmpty else {
            notchSeen.removeAll()
            update(State(occluded: [], notchConflicts: state.notchConflicts))
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
            self.classify(candidates, screens: Set(targets.map(\.id)))
        }
    }

    private func classify(_ candidates: [OverlapScanner.Candidate], screens: Set<ScreenID>) {
        let now = Date()
        var next = State()
        // 감시하지 않은 화면의 노치 앱 정보는 유지 (아일랜드가 숨은 동안 깜빡이지 않게)
        next.notchConflicts = state.notchConflicts.filter { !screens.contains($0.key) }

        let notchNumbers = Set(candidates.filter(\.overlapsNotch).map(\.windowNumber))
        notchSeen = notchSeen.filter { notchNumbers.contains($0.key) }
        for number in notchNumbers where notchSeen[number] == nil { notchSeen[number] = now }

        for candidate in candidates {
            if candidate.overlapsNotch, let first = notchSeen[candidate.windowNumber],
               now.timeIntervalSince(first) >= Self.notchPersistence {
                // 오래 떠 있는 노치 창 = 다른 노치 앱. 메뉴로 보지 않는다.
                next.notchConflicts[candidate.screenID] = candidate.ownerName
                continue
            }
            if candidate.overlapsZone {
                next.occluded.insert(candidate.screenID)
            }
        }
        update(next)
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
