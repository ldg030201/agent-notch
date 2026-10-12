import AppKit
import ApplicationServices
import os

/// 화면 하나의 메뉴바 측정값. x 는 화면 왼쪽 끝 기준 상대값(pt).
struct MenuBarSpace: Equatable, Sendable {
    /// 메뉴바가 보이는지 (자동 숨김 · 풀스크린이면 false)
    var menuBarVisible: Bool
    /// 실제 메뉴바 높이 (모르면 nil → 화면 정보 사용)
    var menuBarHeight: CGFloat?
    /// 앞 앱 메뉴 오른쪽 끝 (`appMenuMeasured` 가 false 면 의미 없음)
    var appMenuEnd: CGFloat
    var appMenuMeasured: Bool
    /// 상태 아이템 왼쪽 끝 (`statusMeasured` 가 false 면 의미 없음)
    var statusStart: CGFloat
    var statusMeasured: Bool

    init(
        menuBarVisible: Bool = true,
        menuBarHeight: CGFloat? = nil,
        appMenuEnd: CGFloat = 0,
        appMenuMeasured: Bool = false,
        statusStart: CGFloat = 0,
        statusMeasured: Bool = false
    ) {
        self.menuBarVisible = menuBarVisible
        self.menuBarHeight = menuBarHeight
        self.appMenuEnd = appMenuEnd
        self.appMenuMeasured = appMenuMeasured
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
    ///   (macOS 버전에 따라 상태 아이템이 창 목록에 없을 수 있다 → 그때는 손쉬운 사용 정보나 추정값 사용)
    static func scan(_ snapshot: WindowSnapshot, screens: [Screen], ownPID: Int) -> [ScreenID: Result] {
        var results: [ScreenID: Result] = [:]
        for screen in screens { results[screen.id] = Result() }

        for window in snapshot.windows where window.alpha > 0.01 {
            let rect = window.frame
            guard rect.width >= 2, rect.height >= 2 else { continue }
            for screen in screens {
                let frame = screen.frame
                guard rect.intersects(frame) || abs(rect.maxY - frame.maxY) < 1.5 else { continue }
                let touchesTop = abs(rect.maxY - frame.maxY) < 1.5
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

// MARK: - 손쉬운 사용(AX)으로 메뉴 위치 읽기

/// 손쉬운 사용 권한이 있을 때만 쓴다. 다른 앱과 IPC 하므로 메인 스레드 밖에서 부른다.
enum AXMenuBarReader {
    /// 응답 없는 앱 때문에 오래 막히지 않게 하는 요청 제한 시간(초)
    private static let messagingTimeout: Float = 0.15

    /// 앞 앱 메뉴바 항목 사각형 (Cocoa 전역 좌표)
    static func appMenuFrames(pid: pid_t, primaryHeight: CGFloat) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return itemFrames(of: app, barAttribute: "AXMenuBar", primaryHeight: primaryHeight)
    }

    /// 메뉴바 오른쪽 상태 아이템(menu extras) 사각형 (Cocoa 전역 좌표)
    static func statusItemFrames(pids: [pid_t], primaryHeight: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, messagingTimeout)
            frames.append(contentsOf: itemFrames(of: app, barAttribute: "AXExtrasMenuBar", primaryHeight: primaryHeight))
        }
        return frames
    }

    private static func itemFrames(of app: AXUIElement, barAttribute: String, primaryHeight: CGFloat) -> [CGRect] {
        guard let bar = element(app, barAttribute) else { return [] }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, "AXChildren" as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement]
        else { return [] }

        var frames: [CGRect] = []
        for child in children {
            var values: CFArray?
            let attributes = ["AXPosition", "AXSize"] as CFArray
            guard AXUIElementCopyMultipleAttributeValues(child, attributes, AXCopyMultipleAttributeOptions(), &values) == .success,
                  let array = values as? [AnyObject], array.count == 2,
                  let point = pointValue(array[0]), let size = sizeValue(array[1]),
                  size.width > 0, size.height > 0
            else { continue }
            frames.append(WindowSnapshot.cocoaRect(fromGlobalTopLeft: CGRect(origin: point, size: size), primaryHeight: primaryHeight))
        }
        return frames
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func pointValue(_ object: AnyObject) -> CGPoint? {
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(object as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeValue(_ object: AnyObject) -> CGSize? {
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(object as! AXValue, .cgSize, &size) ? size : nil
    }
}

// MARK: - 측정값 합치기

enum MenuBarSpaceBuilder {
    /// 창 목록 결과와 AX 결과를 화면별 상대값으로 합친다.
    /// - 앱 메뉴는 왼쪽 정렬이라 화면 왼쪽 기준 폭을, 상태 아이템은 오른쪽 정렬이라 화면 오른쪽 기준 폭을 다른 화면에도 그대로 쓴다.
    static func build(
        screens: [MenuBarScanner.Screen],
        scan: [ScreenID: MenuBarScanner.Result],
        appMenuFrames: [CGRect],
        statusFrames: [CGRect],
        reportsMenuBar: [ScreenID: Bool]
    ) -> [ScreenID: MenuBarSpace] {
        let anyMenuBarFound = scan.values.contains { $0.menuBarHeight != nil }
        let appMenuWidth = leftAlignedWidth(appMenuFrames, screens: screens)
        let statusInset = rightAlignedInset(statusFrames, screens: screens)

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
            if let appMenuWidth {
                space.appMenuEnd = appMenuWidth
                space.appMenuMeasured = true
            }
            if let statusMinX = result?.statusMinX {
                space.statusStart = statusMinX - screen.frame.minX
                space.statusMeasured = true
            } else if let statusInset {
                space.statusStart = screen.frame.width - statusInset
                space.statusMeasured = true
            }
            spaces[screen.id] = space
        }
        return spaces
    }

    /// 항목들이 있는 화면의 왼쪽 끝에서 가장 오른쪽 항목 끝까지 폭
    private static func leftAlignedWidth(_ frames: [CGRect], screens: [MenuBarScanner.Screen]) -> CGFloat? {
        guard let host = hostScreen(frames, screens) else { return nil }
        let onHost = frames.filter { host.frame.intersects($0) }
        guard let maxX = onHost.map(\.maxX).max() else { return nil }
        return maxX - host.frame.minX
    }

    /// 항목들이 있는 화면의 오른쪽 끝에서 가장 왼쪽 항목 시작까지 폭
    private static func rightAlignedInset(_ frames: [CGRect], screens: [MenuBarScanner.Screen]) -> CGFloat? {
        guard let host = hostScreen(frames, screens) else { return nil }
        let onHost = frames.filter { host.frame.intersects($0) }
        guard let minX = onHost.map(\.minX).min() else { return nil }
        return host.frame.maxX - minX
    }

    /// 항목이 가장 많이 놓인 화면
    private static func hostScreen(_ frames: [CGRect], _ screens: [MenuBarScanner.Screen]) -> MenuBarScanner.Screen? {
        guard !frames.isEmpty else { return nil }
        return screens
            .map { screen in (screen, frames.filter { screen.frame.contains(CGPoint(x: $0.midX, y: $0.midY)) }.count) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }
}

// MARK: - 모니터

/// 화면별 메뉴바 빈 공간을 측정한다.
///
/// - 창 목록 조회(1ms 미만)는 메인 스레드 밖에서, 앞 앱 변경 · 화면 구성 변경 · 접힌 상태일 때 1초 주기로.
/// - 손쉬운 사용 권한이 있으면 앞 앱 메뉴(앱 변경 시 + 5초마다)와 상태 아이템(10초마다)을 AX 로 읽는다.
@MainActor
final class MenuBarSpaceMonitor {
    /// 측정값이 바뀌면 호출
    var onUpdate: (([ScreenID: MenuBarSpace]) -> Void)?
    /// 지금 측정할 화면들
    var screensProvider: () -> [NotchGeometry] = { [] }
    /// 1초 주기 측정을 할지 (접힌 상태가 보일 때만)
    var shouldPoll: () -> Bool = { false }

    private(set) var spaces: [ScreenID: MenuBarSpace] = [:]
    private(set) var accessibilityTrusted = false

    private var scan: [ScreenID: MenuBarScanner.Result] = [:]
    private var appMenuFrames: [CGRect] = []
    private var statusFrames: [CGRect] = []
    private var lastAppMenuRead = Date.distantPast
    private var lastStatusRead = Date.distantPast

    private var pollTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var refreshInFlight = false
    private var refreshQueued = false
    private var queuedForceAX = false
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var running = false

    private static let pollInterval: Double = 1
    private static let appMenuInterval: TimeInterval = 5
    private static let statusInterval: TimeInterval = 10
    private let logger = Logger(subsystem: "AgentNotch", category: "MenuBarSpace")

    func start() {
        guard !running else { return }
        running = true
        let workspace = NSWorkspace.shared.notificationCenter
        let activation = workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.frontAppChanged() }
        }
        tokens.append((workspace, activation))
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // 상태 아이템이 늘거나 줄었을 수 있다
                    self?.lastStatusRead = .distantPast
                    self?.refresh()
                }
            }
            tokens.append((workspace, token))
        }
        startPolling()
        refresh(forceAX: true)
    }

    func stop() {
        running = false
        pollTask?.cancel()
        pollTask = nil
        activationTask?.cancel()
        activationTask = nil
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    /// 화면 구성이 바뀌었을 때
    func screensChanged() {
        refresh(forceAX: true)
    }

    /// 앞 앱이 바뀌면 메뉴가 바뀐다. 메뉴는 활성화 직후 갱신되므로 조금 뒤에 한 번 더 읽는다.
    private func frontAppChanged() {
        refresh(forceAX: true)
        activationTask?.cancel()
        activationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.refresh(forceAX: true)
        }
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

    /// 창 목록(항상) + AX(권한이 있고 주기가 됐을 때)를 다시 읽는다.
    func refresh(forceAX: Bool = false) {
        guard running else { return }
        if refreshInFlight {
            refreshQueued = true
            queuedForceAX = queuedForceAX || forceAX
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
        let now = Date()
        let readAppMenu = forceAX || now.timeIntervalSince(lastAppMenuRead) >= Self.appMenuInterval
        let readStatus = now.timeIntervalSince(lastStatusRead) >= Self.statusInterval
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let statusPIDs = readStatus ? Self.statusItemPIDs() : []

        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                let trusted = AXIsProcessTrusted()
                let snapshot = WindowSnapshot.capture(primaryHeight: primaryHeight)
                let scan = MenuBarScanner.scan(snapshot, screens: screens, ownPID: ownPID)
                var appMenus: [CGRect]?
                var status: [CGRect]?
                if trusted {
                    if readAppMenu, let frontPID { appMenus = AXMenuBarReader.appMenuFrames(pid: frontPID, primaryHeight: primaryHeight) }
                    if readStatus { status = AXMenuBarReader.statusItemFrames(pids: statusPIDs, primaryHeight: primaryHeight) }
                }
                return (trusted, scan, appMenus, status)
            }.value
            guard let self else { return }
            self.refreshInFlight = false
            self.apply(trusted: result.0, scan: result.1, appMenus: result.2, status: result.3, at: now, screens: screens, reports: reports)
            if self.refreshQueued {
                let force = self.queuedForceAX
                self.refreshQueued = false
                self.queuedForceAX = false
                self.refresh(forceAX: force)
            }
        }
    }

    private func apply(
        trusted: Bool,
        scan: [ScreenID: MenuBarScanner.Result],
        appMenus: [CGRect]?,
        status: [CGRect]?,
        at date: Date,
        screens: [MenuBarScanner.Screen],
        reports: [ScreenID: Bool]
    ) {
        guard running else { return }
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
            logger.info("손쉬운 사용 권한: \(trusted, privacy: .public)")
        }
        self.scan = scan
        if trusted {
            if let appMenus {
                appMenuFrames = appMenus
                lastAppMenuRead = date
            }
            if let status {
                statusFrames = status
                lastStatusRead = date
            }
        } else {
            appMenuFrames = []
            statusFrames = []
        }
        let built = MenuBarSpaceBuilder.build(
            screens: screens,
            scan: scan,
            appMenuFrames: appMenuFrames,
            statusFrames: statusFrames,
            reportsMenuBar: reports
        )
        if built != spaces {
            spaces = built
            onUpdate?(built)
        }
    }

    /// 상태 아이템이 있을 수 있는 앱 (일반 앱 · 메뉴바 앱 + 시스템 메뉴 extras)
    private static func statusItemPIDs() -> [pid_t] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited && $0.processIdentifier != ownPID && !$0.isTerminated }
            .map(\.processIdentifier)
    }
}
