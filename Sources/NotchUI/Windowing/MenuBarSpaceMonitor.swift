import AppKit

/// 화면 하나의 메뉴바 측정값. x 는 화면 왼쪽 끝 기준 상대값(pt).
struct MenuBarSpace: Equatable, Sendable {
    /// 메뉴바가 보이는지 (자동 숨김 · 풀스크린이면 false)
    var menuBarVisible: Bool
    /// 실제 메뉴바 높이 (모르면 nil → 화면 정보 사용)
    var menuBarHeight: CGFloat?
    /// 상태 아이템 왼쪽 끝 (`statusMeasured` 가 false 면 의미 없음)
    var statusStart: CGFloat
    var statusMeasured: Bool

    init(
        menuBarVisible: Bool = true,
        menuBarHeight: CGFloat? = nil,
        statusStart: CGFloat = 0,
        statusMeasured: Bool = false
    ) {
        self.menuBarVisible = menuBarVisible
        self.menuBarHeight = menuBarHeight
        self.statusStart = statusStart
        self.statusMeasured = statusMeasured
    }
}

// MARK: - 창 목록으로 메뉴바 · 상태 아이템 찾기

enum MenuBarScanner {
    struct Screen: Sendable {
        var id: ScreenID
        var frame: CGRect
        /// 메뉴바 창을 못 찾았을 때 쓰는 높이
        var fallbackMenuBarHeight: CGFloat
    }

    struct Result: Sendable, Equatable {
        /// 메뉴바 창 높이 (못 찾으면 nil)
        var menuBarHeight: CGFloat?
        /// 상태 아이템 창의 가장 왼쪽 x (Cocoa 전역, 못 찾으면 nil)
        var statusMinX: CGFloat?
    }

    /// - 메뉴바: 메인 메뉴 레벨, 화면 맨 위에 붙은 화면 폭 거의 전체 창
    /// - 상태 아이템: 상태바 레벨(또는 메뉴바 레벨이지만 폭이 좁은 창), 다른 앱 소유, 메뉴바 높이 띠 안
    ///   (macOS 버전에 따라 상태 아이템이 창 목록에 없을 수 있다 → 그때는 추정값 사용)
    static func scan(_ snapshot: WindowSnapshot, screens: [Screen], ownPID: Int) -> [ScreenID: Result] {
        var results: [ScreenID: Result] = [:]
        for screen in screens { results[screen.id] = Result() }

        for window in snapshot.windows where window.alpha > 0.01 {
            let rect = window.frame
            guard rect.width >= 2, rect.height >= 2 else { continue }
            for screen in screens {
                let frame = screen.frame
                let touchesTop = abs(rect.maxY - frame.maxY) < 1.5
                // 위 가장자리 높이가 같은 옆 화면(나란히 둔 외부 모니터)의 메뉴바 창을 이 화면 것으로 보지 않게 가로로 겹쳐야 한다
                let overlapsX = rect.maxX > frame.minX + 1 && rect.minX < frame.maxX - 1
                guard overlapsX, rect.intersects(frame) || touchesTop else { continue }
                if window.layer == WindowLevels.mainMenu, touchesTop,
                   rect.width >= frame.width * 0.9, rect.height >= 16, rect.height <= 60 {
                    results[screen.id]?.menuBarHeight = rect.height
                    continue
                }
                guard window.pid != ownPID,
                      window.layer == WindowLevels.status
                        || (window.layer == WindowLevels.mainMenu && rect.width < frame.width * 0.5)
                else { continue }
                let band = results[screen.id]?.menuBarHeight ?? screen.fallbackMenuBarHeight
                guard rect.minY >= frame.maxY - band - 2, rect.maxY <= frame.maxY + 1,
                      rect.minX >= frame.minX - 1, rect.maxX <= frame.maxX + 1,
                      rect.width < frame.width * 0.5
                else { continue }
                let current = results[screen.id]?.statusMinX ?? .greatestFiniteMagnitude
                results[screen.id]?.statusMinX = min(current, rect.minX)
            }
        }
        return results
    }
}

// MARK: - 측정값 만들기

enum MenuBarSpaceBuilder {
    /// 창 목록 결과를 화면별 상대값으로 바꾼다
    static func build(
        screens: [MenuBarScanner.Screen],
        scan: [ScreenID: MenuBarScanner.Result],
        reportsMenuBar: [ScreenID: Bool]
    ) -> [ScreenID: MenuBarSpace] {
        let anyMenuBarFound = scan.values.contains { $0.menuBarHeight != nil }
        var spaces: [ScreenID: MenuBarSpace] = [:]
        for screen in screens {
            let result = scan[screen.id]
            var space = MenuBarSpace()
            if anyMenuBarFound {
                space.menuBarVisible = result?.menuBarHeight != nil
            } else {
                // 창 목록에서 메뉴바를 못 찾는 환경이면 화면 정보(visibleFrame)로 판단
                space.menuBarVisible = reportsMenuBar[screen.id] ?? true
            }
            space.menuBarHeight = result?.menuBarHeight
            if let statusMinX = result?.statusMinX {
                space.statusStart = statusMinX - screen.frame.minX
                space.statusMeasured = true
            }
            spaces[screen.id] = space
        }
        return spaces
    }

    /// 상태 아이템 시작이 이보다 적게 움직이면 이전 값을 유지한다
    static let jitterTolerance: CGFloat = 2

    /// 측정 흔들림 거르기.
    /// CPU% 처럼 폭이 1초마다 바뀌는 메뉴바 아이템이 상태 아이템 시작을 1~2pt 밀 때마다
    /// 메뉴바 안 알약 자리가 다시 계산돼 출렁이지 않게, 작은 변화는 이전 값을 그대로 둔다.
    static func stabilized(
        _ built: [ScreenID: MenuBarSpace],
        previous: [ScreenID: MenuBarSpace]
    ) -> [ScreenID: MenuBarSpace] {
        var result = built
        for (id, space) in built {
            guard let old = previous[id], var next = result[id] else { continue }
            if old.statusMeasured, space.statusMeasured, abs(old.statusStart - space.statusStart) < jitterTolerance {
                next.statusStart = old.statusStart
            }
            result[id] = next
        }
        return result
    }
}

// MARK: - 모니터

/// 화면별 메뉴바 높이 · 보임 여부 · 상태 아이템 시작을 창 목록으로 잰다 (권한 필요 없음).
///
/// 창 목록 조회(1ms 미만)는 메인 스레드 밖에서, 앞 앱 변경 · 앱 실행/종료 · 화면 구성 변경 때와 접힌 상태일 때 1초 주기로 한다.
@MainActor
final class MenuBarSpaceMonitor {
    /// 측정값이 바뀌면 호출
    var onUpdate: (([ScreenID: MenuBarSpace]) -> Void)?
    /// 지금 측정할 화면들
    var screensProvider: () -> [NotchGeometry] = { [] }
    /// 1초 주기 측정을 할지 (접힌 상태가 보일 때만)
    var shouldPoll: () -> Bool = { false }

    private(set) var spaces: [ScreenID: MenuBarSpace] = [:]

    private var pollTask: Task<Void, Never>?
    private var refreshInFlight = false
    private var refreshQueued = false
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var running = false

    private static let pollInterval: Double = 1

    func start() {
        guard !running else { return }
        running = true
        // 앞 앱이 바뀌거나 앱이 실행 · 종료되면 상태 아이템이 바뀔 수 있다
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            tokens.append((workspace, token))
        }
        startPolling()
        refresh()
    }

    func stop() {
        running = false
        pollTask?.cancel()
        pollTask = nil
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    /// 화면 구성이 바뀌었을 때
    func screensChanged() {
        refresh()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard let self, self.running else { return }
                if self.shouldPoll() { self.refresh() }
            }
        }
    }

    /// 창 목록을 다시 읽는다
    func refresh() {
        guard running else { return }
        if refreshInFlight {
            refreshQueued = true
            return
        }
        let geometries = screensProvider()
        guard !geometries.isEmpty else { return }
        refreshInFlight = true

        let screens = geometries.map {
            MenuBarScanner.Screen(id: $0.screenID, frame: $0.frame, fallbackMenuBarHeight: $0.menuBarHeight)
        }
        let reports = Dictionary(uniqueKeysWithValues: geometries.map { ($0.screenID, $0.reportsMenuBar) })
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)

        Task { @MainActor [weak self] in
            let scan = await Task.detached(priority: .utility) {
                MenuBarScanner.scan(WindowSnapshot.capture(primaryHeight: primaryHeight), screens: screens, ownPID: ownPID)
            }.value
            guard let self else { return }
            self.refreshInFlight = false
            self.apply(scan: scan, screens: screens, reports: reports)
            if self.refreshQueued {
                self.refreshQueued = false
                self.refresh()
            }
        }
    }

    private func apply(scan: [ScreenID: MenuBarScanner.Result], screens: [MenuBarScanner.Screen], reports: [ScreenID: Bool]) {
        guard running else { return }
        let built = MenuBarSpaceBuilder.stabilized(
            MenuBarSpaceBuilder.build(screens: screens, scan: scan, reportsMenuBar: reports),
            previous: spaces
        )
        if built != spaces {
            spaces = built
            onUpdate?(built)
        }
    }
}
