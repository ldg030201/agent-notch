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
    /// 메뉴바 아이템(상태 아이콘 · 앞 앱 메뉴) 사각형. 패널 기준 (x 는 화면 왼쪽부터, y 는 화면 위부터).
    /// 손쉬운 사용 권한으로 상태 아이콘을 읽었을 때만 채운다 (`itemsMeasured`).
    var itemFrames: [CGRect]
    var itemsMeasured: Bool

    init(
        menuBarVisible: Bool = true,
        menuBarHeight: CGFloat? = nil,
        appMenuEnd: CGFloat = 0,
        appMenuMeasured: Bool = false,
        statusStart: CGFloat = 0,
        statusMeasured: Bool = false,
        itemFrames: [CGRect] = [],
        itemsMeasured: Bool = false
    ) {
        self.menuBarVisible = menuBarVisible
        self.menuBarHeight = menuBarHeight
        self.appMenuEnd = appMenuEnd
        self.appMenuMeasured = appMenuMeasured
        self.statusStart = statusStart
        self.statusMeasured = statusMeasured
        self.itemFrames = itemFrames
        self.itemsMeasured = itemsMeasured
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
    /// MenuBarAgent 트리를 훑을 때 깊이 · 요소 수 제한
    private static let maxDepth = 6
    private static let maxNodes = 240

    /// 앞 앱 메뉴바 항목 사각형 (Cocoa 전역 좌표)
    static func appMenuFrames(pid: pid_t, primaryHeight: CGFloat) -> [CGRect] {
        itemFrames(of: application(pid), barAttribute: "AXMenuBar", primaryHeight: primaryHeight)
    }

    /// 메뉴바 오른쪽 상태 아이템(menu extras) 사각형 (Cocoa 전역 좌표)
    static func statusItemFrames(pids: [pid_t], primaryHeight: CGFloat) -> [CGRect] {
        pids.flatMap { itemFrames(of: application($0), barAttribute: "AXExtrasMenuBar", primaryHeight: primaryHeight) }
    }

    /// 이 프로세스가 상태 아이템 막대(`AXExtrasMenuBar`)를 갖고 있는지.
    /// 응답이 없거나(제한 시간 초과) 권한이 막혀 확인하지 못했으면 `.failed`.
    static func extrasMenuBarCheck(pid: pid_t) -> MenuExtrasHosts.Check {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(application(pid), "AXExtrasMenuBar" as CFString, &value) {
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .absent }
            return .found
        case .cannotComplete, .apiDisabled, .failure:
            return .failed
        default:
            return .absent
        }
    }

    /// macOS 27 의 MenuBarAgent 처럼 메뉴바를 직접 그리는 프로세스의 메뉴바 항목 (Cocoa 전역 좌표).
    /// 구조가 정해져 있지 않아 창(디스플레이마다 하나) 아래를 훑으며 메뉴바 항목 · menu extra 역할인 요소만 모은다.
    /// - `extras`: menu extra 역할 (확실한 상태 아이템)
    /// - `items`: 그 밖의 메뉴바 항목 (앱 메뉴일 수도 있음)
    static func menuExtraFrames(pid: pid_t, primaryHeight: CGFloat) -> (extras: [CGRect], items: [CGRect]) {
        let app = application(pid)
        var roots: [AXUIElement] = []
        if let extras = element(app, "AXExtrasMenuBar") { roots.append(extras) }
        roots.append(contentsOf: elements(app, "AXWindows"))
        if roots.isEmpty { roots.append(contentsOf: elements(app, "AXChildren")) }

        var queue: [(element: AXUIElement, depth: Int)] = roots.map { ($0, 0) }
        var visited = 0
        var extras: [CGRect] = []
        var items: [CGRect] = []
        let attributes = ["AXRole", "AXSubrole", "AXPosition", "AXSize", "AXChildren"] as CFArray
        while !queue.isEmpty, visited < maxNodes {
            let (node, depth) = queue.removeFirst()
            visited += 1
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(node, attributes, AXCopyMultipleAttributeOptions(), &values) == .success,
                  let array = values as? [AnyObject], array.count == 5
            else { continue }
            let role = array[0] as? String
            let subrole = array[1] as? String
            let isExtra = role == "AXMenuExtra" || subrole == "AXMenuExtra"
            if isExtra || role == "AXMenuBarItem" {
                if let point = pointValue(array[2]), let size = sizeValue(array[3]), size.width > 0, size.height > 0 {
                    let frame = WindowSnapshot.cocoaRect(fromGlobalTopLeft: CGRect(origin: point, size: size), primaryHeight: primaryHeight)
                    if isExtra { extras.append(frame) } else { items.append(frame) }
                }
                continue
            }
            guard depth < maxDepth, let children = array[4] as? [AXUIElement] else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return (extras, items)
    }

    private static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return app
    }

    private static func itemFrames(of app: AXUIElement, barAttribute: String, primaryHeight: CGFloat) -> [CGRect] {
        guard let bar = element(app, barAttribute) else { return [] }
        var frames: [CGRect] = []
        let attributes = ["AXPosition", "AXSize"] as CFArray
        for child in elements(bar, "AXChildren") {
            var values: CFArray?
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

    private static func elements(_ parent: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let list = value as? [AXUIElement]
        else { return [] }
        return list
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

/// 상태 아이템(menu extras)을 가진 프로세스 찾기.
/// 시스템 메뉴 extras 는 ControlCenter · SystemUIServer · MenuBarAgent · TextInputMenuAgent · Spotlight 같은
/// 에이전트(백그라운드) 프로세스에 있어서 실행 중인 앱 전체를 보되, pid 마다 결과를 60초 동안 기억한다.
/// 우리 앱도 포함한다 (우리 상태 아이콘에도 구멍을 뚫어야 하므로). AX 요청은 메인 스레드 밖에서 하므로
/// 우리 메인 스레드가 응답할 수 있다.
struct MenuExtrasHosts: Sendable {
    struct Candidate: Sendable {
        var pid: pid_t
        /// 확인 순서 (작을수록 먼저): 시스템 extras 0, 메뉴바 앱 1, 일반 앱 2, 백그라운드 3
        var priority: Int
        /// macOS 27 메뉴바를 그리는 MenuBarAgent
        var isMenuBarAgent: Bool
    }

    /// 상태 아이템 막대 확인 결과
    enum Check: Sendable {
        case found
        case absent
        /// 응답 없음 등으로 확인 못 함 (이전 값을 두고 곧 다시 확인)
        case failed
    }

    private struct Entry: Sendable {
        var hasExtras: Bool
        /// 확인하지 못해 이전 값을 그대로 둔 것
        var uncertain: Bool
        var checkedAt: Date
    }

    static let recheckInterval: TimeInterval = 60
    /// 상태 아이템이 없던 앱(메뉴바 · 일반 앱)과 확인 못 한 앱은 이 간격으로 다시 본다
    /// (실행하고 한참 뒤에 상태 아이템을 만드는 앱, 잠깐 바빴던 앱)
    static let shortRecheckInterval: TimeInterval = 5
    /// 한 번에 새로 확인하는 시간 한도 (나머지는 다음 측정 때)
    static let discoveryBudget: TimeInterval = 0.1
    static let systemBundleIDs: Set<String> = [
        "com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.MenuBarAgent",
        "com.apple.TextInputMenuAgent", "com.apple.Spotlight",
    ]

    private var entries: [pid_t: Entry] = [:]
    /// MenuBarAgent 트리에서 아무것도 못 찾았으면 이 시각까지 다시 훑지 않는다
    private var agentRetryAt = Date.distantPast

    /// 지금 실행 중인 후보 (메인 스레드에서)
    @MainActor
    static func candidates() -> [Candidate] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated else { return nil }
            let bundleID = app.bundleIdentifier ?? ""
            let priority: Int
            if systemBundleIDs.contains(bundleID) {
                priority = 0
            } else {
                switch app.activationPolicy {
                case .accessory: priority = 1
                case .regular: priority = 2
                default: priority = 3
                }
            }
            return Candidate(pid: app.processIdentifier, priority: priority, isMenuBarAgent: bundleID == "com.apple.MenuBarAgent")
        }
    }

    /// 확인할 때가 된 pid 를 (시간 한도 안에서) 확인하고, 상태 아이템이 있는 pid 를 돌려준다.
    /// - 처음 보는 pid 와 `recheck`(방금 실행된 앱)를 먼저, 그다음 다시 볼 때가 된 pid 를 우선순위 순으로 본다.
    /// - 상태 아이템이 없던 메뉴바 · 일반 앱과 확인 못 한 pid 는 5초, 나머지는 60초마다 다시 본다.
    mutating func discover(
        _ candidates: [Candidate],
        recheck: Set<pid_t>,
        now: Date,
        check: (pid_t) -> Check
    ) -> [pid_t] {
        let alive = Set(candidates.map(\.pid))
        entries = entries.filter { alive.contains($0.key) }
        let due = candidates.compactMap { candidate -> (tier: Int, candidate: Candidate)? in
            guard let entry = entries[candidate.pid], !recheck.contains(candidate.pid) else { return (0, candidate) }
            let short = entry.uncertain || (!entry.hasExtras && candidate.priority <= 2)
            let interval = short ? Self.shortRecheckInterval : Self.recheckInterval
            return now.timeIntervalSince(entry.checkedAt) >= interval ? (1, candidate) : nil
        }
        .sorted { ($0.tier, $0.candidate.priority) < ($1.tier, $1.candidate.priority) }

        let started = Date()
        for (_, candidate) in due {
            if Date().timeIntervalSince(started) > Self.discoveryBudget { break }
            switch check(candidate.pid) {
            case .found:
                entries[candidate.pid] = Entry(hasExtras: true, uncertain: false, checkedAt: now)
            case .absent:
                entries[candidate.pid] = Entry(hasExtras: false, uncertain: false, checkedAt: now)
            case .failed:
                // 확인 못 했으면 이전 값을 그대로 두고 곧 다시 본다
                let previous = entries[candidate.pid]?.hasExtras ?? false
                entries[candidate.pid] = Entry(hasExtras: previous, uncertain: true, checkedAt: now)
            }
        }
        return entries.filter(\.value.hasExtras).map(\.key).sorted()
    }

    /// MenuBarAgent 트리를 지금 훑을지 (헛탕이면 60초 쉰다)
    func shouldScanAgent(now: Date) -> Bool { now >= agentRetryAt }

    mutating func noteAgentScan(found: Bool, now: Date) {
        agentRetryAt = found ? .distantPast : now.addingTimeInterval(Self.recheckInterval)
    }
}

// MARK: - 측정값 합치기

/// 손쉬운 사용으로 읽은 메뉴바 항목 사각형 (Cocoa 전역 좌표)
struct MenuBarItemReadings: Equatable, Sendable {
    /// 앞 앱 메뉴 (`AXMenuBar`)
    var appMenus: [CGRect] = []
    /// 상태 아이템 (`AXExtrasMenuBar`)
    var status: [CGRect] = []
    /// MenuBarAgent 의 menu extra 역할 항목 (확실한 상태 아이템)
    var agentExtras: [CGRect] = []
    /// MenuBarAgent 의 그 밖의 메뉴바 항목 (앱 메뉴일 수도 있음)
    var agentItems: [CGRect] = []
}

enum MenuBarSpaceBuilder {
    /// 창 목록 결과와 AX 결과를 화면별 상대값으로 합친다.
    /// - 앱 메뉴는 왼쪽 정렬이라 화면 왼쪽 기준 폭을, 상태 아이템은 오른쪽 정렬이라 화면 오른쪽 기준 폭을 다른 화면에도 그대로 쓴다.
    static func build(
        screens: [MenuBarScanner.Screen],
        scan: [ScreenID: MenuBarScanner.Result],
        readings: MenuBarItemReadings,
        reportsMenuBar: [ScreenID: Bool]
    ) -> [ScreenID: MenuBarSpace] {
        let anyMenuBarFound = scan.values.contains { $0.menuBarHeight != nil }
        let appMenuWidth = leftAlignedWidth(readings.appMenus, screens: screens)
        let statusInset = rightAlignedInset(readings.status, screens: screens)
        let items = itemFrames(screens: screens, scan: scan, readings: readings)

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
            if let measured = items[screen.id] {
                space.itemFrames = measured
                space.itemsMeasured = true
            }
            spaces[screen.id] = space
        }
        return spaces
    }

    /// 화면별 메뉴바 항목 사각형 (패널 기준). 상태 아이템을 하나도 못 읽은 화면은 nil.
    /// - 그 화면에서 읽은 값을 그대로 쓰고, 못 읽었으면 가장 많이 읽힌 화면의 값을 옮겨 쓴다
    ///   (상태 아이템은 오른쪽 정렬, 앞 앱 메뉴는 왼쪽 정렬)
    /// - MenuBarAgent 의 역할을 모르는 항목은 읽힌 화면에서만 쓴다
    static func itemFrames(
        screens: [MenuBarScanner.Screen],
        scan: [ScreenID: MenuBarScanner.Result],
        readings: MenuBarItemReadings
    ) -> [ScreenID: [CGRect]] {
        let status = byScreen(readings.status + readings.agentExtras, screens)
        let appMenus = byScreen(readings.appMenus, screens)
        let others = byScreen(readings.agentItems, screens)
        let statusHost = host(status, screens)
        let appHost = host(appMenus, screens)

        var result: [ScreenID: [CGRect]] = [:]
        for screen in screens {
            var statusFrames = status[screen.id] ?? []
            if statusFrames.isEmpty, let statusHost, statusHost.id != screen.id {
                let shift = screen.frame.width - statusHost.frame.width
                statusFrames = (status[statusHost.id] ?? []).map { $0.offsetBy(dx: shift, dy: 0) }
            }
            guard !statusFrames.isEmpty else { continue }
            var menus = appMenus[screen.id] ?? []
            if menus.isEmpty, let appHost, appHost.id != screen.id {
                menus = appMenus[appHost.id] ?? []
            }
            let band = scan[screen.id]?.menuBarHeight ?? screen.fallbackMenuBarHeight
            result[screen.id] = MenuBarItemFrames.normalize(
                statusFrames + menus + (others[screen.id] ?? []),
                screenWidth: screen.frame.width,
                bandHeight: band
            )
        }
        return result
    }

    /// 사각형을 가운데가 들어 있는 화면별로 나누고 패널 기준으로 바꾼다
    private static func byScreen(_ frames: [CGRect], _ screens: [MenuBarScanner.Screen]) -> [ScreenID: [CGRect]] {
        var result: [ScreenID: [CGRect]] = [:]
        for frame in frames {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            guard let screen = screens.first(where: { $0.frame.contains(center) }) else { continue }
            let local = CGRect(
                x: frame.minX - screen.frame.minX,
                y: screen.frame.maxY - frame.maxY,
                width: frame.width,
                height: frame.height
            )
            result[screen.id, default: []].append(local)
        }
        return result
    }

    /// 항목이 가장 많이 읽힌 화면
    private static func host(_ frames: [ScreenID: [CGRect]], _ screens: [MenuBarScanner.Screen]) -> MenuBarScanner.Screen? {
        screens
            .map { ($0, frames[$0.id]?.count ?? 0) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
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
/// - 손쉬운 사용 권한이 있으면 앞 앱 메뉴(앱 변경 시 + 5초마다)와 상태 아이템(앱 변경 시 + 5초마다)을 AX 로 읽는다.
///   상태 아이템을 가진 프로세스는 pid 마다 60초(상태 아이템이 없던 앱 · 확인 못 한 앱은 5초)에 한 번 다시 찾는다 (`MenuExtrasHosts`).
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
    private var readings = MenuBarItemReadings()
    private var extrasHosts = MenuExtrasHosts()
    /// 방금 실행된 앱: 기억한 결과와 관계없이 상태 아이템을 다시 찾는다
    private var pendingRecheck: Set<pid_t> = []
    private var lastAppMenuRead = Date.distantPast
    private var lastStatusRead = Date.distantPast
    /// 화면별로 마지막에 기록한 아이템 수 (바뀔 때만 로그)
    private var loggedItemCounts: [ScreenID: Int] = [:]

    private var pollTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var launchTasks: [Task<Void, Never>] = []
    private var refreshInFlight = false
    private var refreshQueued = false
    private var queuedForceAX = false
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var running = false

    private static let pollInterval: Double = 1
    private static let appMenuInterval: TimeInterval = 5
    private static let statusInterval: TimeInterval = 5
    /// 실행 직후엔 상태 아이템이 아직 없을 수 있어 조금 뒤에 다시 찾는다
    private static let launchRecheckDelay: Duration = .seconds(3)
    private let logger = Logger(subsystem: "com.ldg.agent-notch", category: "MenuBarSpace")

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
        let launch = workspace.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.appLaunched(pid: pid) }
        }
        tokens.append((workspace, launch))
        let terminate = workspace.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // 상태 아이템이 줄었을 수 있다
                self?.lastStatusRead = .distantPast
                self?.refresh()
            }
        }
        tokens.append((workspace, terminate))
        startPolling()
        refresh(forceAX: true)
    }

    func stop() {
        running = false
        pollTask?.cancel()
        pollTask = nil
        activationTask?.cancel()
        activationTask = nil
        for task in launchTasks { task.cancel() }
        launchTasks.removeAll()
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    /// 화면 구성이 바뀌었을 때
    func screensChanged() {
        refresh(forceAX: true)
    }

    /// 앞 앱이 바뀌면 메뉴가 바뀐다 (macOS 27 은 메뉴 길이에 따라 상태 아이콘 접힘도 바뀐다).
    /// 메뉴는 활성화 직후 갱신되므로 조금 뒤에 한 번 더 읽는다.
    private func frontAppChanged() {
        refresh(forceAX: true)
        activationTask?.cancel()
        activationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.refresh(forceAX: true)
        }
    }

    /// 새 앱: 바로 한 번, 상태 아이템을 만들 시간을 두고 한 번 더 찾는다
    private func appLaunched(pid: pid_t?) {
        lastStatusRead = .distantPast
        refresh()
        guard let pid else { return }
        launchTasks.removeAll { $0.isCancelled }
        launchTasks.append(Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.launchRecheckDelay)
            guard !Task.isCancelled, let self, self.running else { return }
            self.pendingRecheck.insert(pid)
            self.lastStatusRead = .distantPast
            self.refresh()
        })
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
        let readStatus = forceAX || now.timeIntervalSince(lastStatusRead) >= Self.statusInterval
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let candidates = readStatus ? MenuExtrasHosts.candidates() : []
        let hosts = extrasHosts
        let recheck = readStatus ? pendingRecheck : []
        if readStatus { pendingRecheck.removeAll() }

        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                let trusted = AXIsProcessTrusted()
                let snapshot = WindowSnapshot.capture(primaryHeight: primaryHeight)
                let scan = MenuBarScanner.scan(snapshot, screens: screens, ownPID: ownPID)
                var appMenus: [CGRect]?
                var status: (status: [CGRect], extras: [CGRect], items: [CGRect])?
                var hosts = hosts
                if trusted {
                    if readAppMenu, let frontPID { appMenus = AXMenuBarReader.appMenuFrames(pid: frontPID, primaryHeight: primaryHeight) }
                    if readStatus {
                        let pids = hosts.discover(candidates, recheck: recheck, now: now) { AXMenuBarReader.extrasMenuBarCheck(pid: $0) }
                        var agent: (extras: [CGRect], items: [CGRect]) = ([], [])
                        if let agentPID = candidates.first(where: \.isMenuBarAgent)?.pid, hosts.shouldScanAgent(now: now) {
                            agent = AXMenuBarReader.menuExtraFrames(pid: agentPID, primaryHeight: primaryHeight)
                            hosts.noteAgentScan(found: !agent.extras.isEmpty || !agent.items.isEmpty, now: now)
                        }
                        status = (AXMenuBarReader.statusItemFrames(pids: pids, primaryHeight: primaryHeight), agent.extras, agent.items)
                    }
                }
                return (trusted: trusted, scan: scan, appMenus: appMenus, status: status, hosts: hosts)
            }.value
            guard let self else { return }
            self.refreshInFlight = false
            if result.status != nil { self.extrasHosts = result.hosts }
            self.apply(
                trusted: result.trusted, scan: result.scan, appMenus: result.appMenus, status: result.status,
                at: now, screens: screens, reports: reports
            )
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
        status: (status: [CGRect], extras: [CGRect], items: [CGRect])?,
        at date: Date,
        screens: [MenuBarScanner.Screen],
        reports: [ScreenID: Bool]
    ) {
        guard running else { return }
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
            logger.info("손쉬운 사용 권한: \(trusted, privacy: .public)")
            if trusted {
                // 방금 허용됐으면 바로 다시 읽는다
                lastAppMenuRead = .distantPast
                lastStatusRead = .distantPast
                refreshQueued = true
                queuedForceAX = true
            }
        }
        self.scan = scan
        if trusted {
            if let appMenus {
                readings.appMenus = appMenus
                lastAppMenuRead = date
            }
            if let status {
                readings.status = status.status
                readings.agentExtras = status.extras
                readings.agentItems = status.items
                lastStatusRead = date
            }
        } else {
            readings = MenuBarItemReadings()
            extrasHosts = MenuExtrasHosts()
        }
        let built = MenuBarSpaceBuilder.build(
            screens: screens,
            scan: scan,
            readings: readings,
            reportsMenuBar: reports
        )
        logItemCounts(built)
        if built != spaces {
            spaces = built
            onUpdate?(built)
        }
    }

    /// 화면별 아이템 수가 바뀌면 기록 (숫자만)
    private func logItemCounts(_ spaces: [ScreenID: MenuBarSpace]) {
        let counts = spaces.mapValues { $0.itemsMeasured ? $0.itemFrames.count : -1 }
        guard counts != loggedItemCounts else { return }
        loggedItemCounts = counts
        for (id, count) in counts.sorted(by: { $0.key < $1.key }) {
            if count >= 0 {
                logger.info("메뉴바 아이템 \(count, privacy: .public)개 (화면 \(id, privacy: .public))")
            } else {
                logger.info("메뉴바 아이템 위치 모름 (화면 \(id, privacy: .public))")
            }
        }
    }
}
