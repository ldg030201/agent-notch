import AppKit
import Observation
import SwiftUI
import NotchCore
import os

/// 화면마다 패널 하나를 두고, 클릭 통과·마우스 추적·풀스크린 감지·단축키·메뉴바 겹침 감시를 처리한다.
@MainActor
final class ScreenManager {
    private let presentation: PresentationController
    private let makeRootView: @MainActor (ScreenID) -> AnyView
    private let spaceMonitor = MenuBarSpaceMonitor()
    private let overlapMonitor = OverlapMonitor()

    private var panels: [ScreenID: NotchPanel] = [:]
    private var lastModes: [ScreenID: IslandMode] = [:]
    /// 화면별 마지막으로 그린 모양(애니메이션 값)과 바뀐 시각 (부팅 후 초). 모양이 바뀌는 동안엔 접힌 상태를 새로 숨기지 않는다
    private var lastShapes: [ScreenID: IslandLayout] = [:]
    private var shapeChangedAt: [ScreenID: TimeInterval] = [:]
    /// 화면별 클릭 영역 (Cocoa 전역). 마우스 이동마다 레이아웃을 다시 계산하지 않도록 상태가 바뀔 때만 갱신한다.
    private var hitRectCache: [ScreenID: [CGRect]] = [:]
    /// 화면별 클릭 통과 영역 (아이콘 구멍, Cocoa 전역). 클릭 영역보다 우선한다.
    private var passThroughCache: [ScreenID: [CGRect]] = [:]
    /// 넓은 노치 날개 비켜주기 (아이콘 위치를 모를 때)
    private let wingRetract = WingRetractTracker()
    private var eventMonitors: [Any] = []
    private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var fullscreenTask: Task<Void, Never>?
    private var fullscreenRefreshTask: Task<Void, Never>?
    private var running = false
    /// 키 반납용 보이지 않는 패널 (`KeyReleasePanel`)
    private lazy var keyReleasePanel = KeyReleasePanel()
    /// 키를 반납하는 동안엔 아일랜드 패널이 다시 키 윈도우가 되지 않게 한다
    private var releasingKey = false
    /// stop/start 를 반복해도 관찰 루프가 겹치지 않게 하는 세대 번호
    private var generation = 0

    private let logger = Logger(subsystem: "com.ldg.agent-notch", category: "Screens")

    /// 풀스크린 감지 주기(초). 설정이 "전부 표시"면 감지하지 않는다.
    private static let fullscreenPollInterval: Double = 2

    init(presentation: PresentationController, makeRootView: @escaping @MainActor (ScreenID) -> AnyView) {
        self.presentation = presentation
        self.makeRootView = makeRootView
    }

    // MARK: - 생명주기

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        presentation.onRequestKey = { [weak self] id in self?.makeKey(id) }
        wingRetract.onChange = { [weak self] id, sides in
            self?.presentation.setRetractedWings(sides, on: id)
        }
        rebuildPanels()
        installEventMonitors()
        installNotifications()
        startFullscreenPolling()
        startOverlapMonitoring()
        armModeObservation()
        updateMouseState()
    }

    func stop() {
        guard running else { return }
        running = false
        presentation.onRequestKey = nil
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors.removeAll()
        for (center, token) in notificationTokens { center.removeObserver(token) }
        notificationTokens.removeAll()
        fullscreenTask?.cancel()
        fullscreenTask = nil
        fullscreenRefreshTask?.cancel()
        fullscreenRefreshTask = nil
        spaceMonitor.stop()
        overlapMonitor.stop()
        keyReleasePanel.orderOut(nil)
        wingRetract.reset()
        for panel in panels.values {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panels.removeAll()
        lastModes.removeAll()
        lastShapes.removeAll()
        shapeChangedAt.removeAll()
        hitRectCache.removeAll()
        passThroughCache.removeAll()
    }

    /// 마우스가 있는 화면(또는 정책상 대상 화면)에서 펼침 토글
    func toggleExpandedOnPreferredScreen() {
        updateMouseState()
        guard let id = presentation.preferredUserScreenID else { return }
        presentation.toggleExpanded(on: id)
    }

    // MARK: - 패널 구성

    private func rebuildPanels() {
        let geometries = NSScreen.screens.map(NotchGeometry.init(screen:))
        let ids = Set(geometries.map(\.screenID))

        for (id, panel) in panels where !ids.contains(id) {
            panel.orderOut(nil)
            panel.contentView = nil
            panels.removeValue(forKey: id)
            lastModes.removeValue(forKey: id)
            lastShapes.removeValue(forKey: id)
            shapeChangedAt.removeValue(forKey: id)
            hitRectCache.removeValue(forKey: id)
            passThroughCache.removeValue(forKey: id)
        }

        presentation.updateScreens(geometries)

        for geometry in geometries {
            let id = geometry.screenID
            if let panel = panels[id] {
                if panel.frame != geometry.panelFrame {
                    panel.setFrame(geometry.panelFrame, display: true)
                }
            } else {
                panels[id] = makePanel(for: geometry)
            }
        }
        logger.info("패널 재구성: 화면 \(geometries.count, privacy: .public)개")
        spaceMonitor.screensChanged()
        updateMouseState()
    }

    private func makePanel(for geometry: NotchGeometry) -> NotchPanel {
        let id = geometry.screenID
        let panel = NotchPanel(frame: geometry.panelFrame)
        panel.allowsKey = { [weak self, weak presentation] in
            guard self?.releasingKey != true else { return false }
            return presentation?.mode(for: id).wantsKey ?? false
        }
        let host = IslandHostingView(rootView: makeRootView(id))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.frame = CGRect(origin: .zero, size: geometry.panelFrame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.setFrame(geometry.panelFrame, display: false)
        panel.orderFrontRegardless()
        return panel
    }

    private func makeKey(_ id: ScreenID) {
        guard let panel = panels[id], panel.canBecomeKey, !panel.isKeyWindow else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - 모드 변화 감시 (키 윈도우 반납, 클릭 영역 갱신)

    /// 화면별 표시 상태 (모드 · 레이아웃 · 투명 숨김 · 비켜줄 날개 자리)
    private struct ScreenState {
        var mode: IslandMode
        var layout: IslandLayout
        var concealed: Bool
        var bands: WingBands
    }

    private func armModeObservation() {
        guard running else { return }
        let ids = Array(panels.keys)
        let current = generation
        let states = withObservationTracking {
            Dictionary(uniqueKeysWithValues: ids.map { id -> (ScreenID, ScreenState) in
                let mode = presentation.mode(for: id)
                return (id, ScreenState(
                    mode: mode,
                    layout: presentation.layout(for: id, mode: mode),
                    concealed: presentation.isConcealed(id),
                    bands: presentation.retractBands(for: id, mode: mode)
                ))
            })
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == current else { return }
                self.armModeObservation()
            }
        }
        applyModes(states)
    }

    private func applyModes(_ states: [ScreenID: ScreenState]) {
        var becameCompact = false
        var bands: [ScreenID: WingRetractTracker.Bands] = [:]
        let now = ProcessInfo.processInfo.systemUptime
        for (id, state) in states {
            let geometry = presentation.geometries[id]
            let shape = state.layout.animationKey
            if lastShapes[id] != shape {
                if lastShapes[id] != nil { shapeChangedAt[id] = now }
                lastShapes[id] = shape
            }
            hitRectCache[id] = hitRects(state, geometry: geometry)
            passThroughCache[id] = passThroughRects(state, geometry: geometry)
            if let geometry, !state.bands.isEmpty {
                bands[id] = WingRetractTracker.Bands(
                    left: state.bands.left.map(geometry.screenRect(fromPanel:)),
                    right: state.bands.right.map(geometry.screenRect(fromPanel:))
                )
            }
            let previous = lastModes[id]
            guard previous != state.mode else { continue }
            let wasCompact = previous.map { $0 == .idle || $0 == .working } ?? false
            if !wasCompact, state.mode == .idle || state.mode == .working { becameCompact = true }
            lastModes[id] = state.mode
            guard let panel = panels[id] else { continue }
            // 접히면 키 윈도우를 반납해 원래 앱으로 키보드 포커스를 돌려준다.
            // 다른 권한 요청이 새로 보이게 돼도 반납한다 (보지 못한 요청을 단축키로 결정하지 않게, 다시 클릭해야 함)
            if !state.mode.wantsKey || Self.showsNewPermission(state.mode, after: previous), panel.isKeyWindow {
                releaseKey(from: panel, geometry: geometry)
            }
        }
        wingRetract.setBands(bands)
        updateMouseState()
        // 접힌 상태가 새로 보이기 시작하면 메뉴바 빈 공간을 바로 다시 잰다
        if becameCompact { spaceMonitor.refresh() }
    }

    /// 키 윈도우를 반납해 키보드 포커스를 원래 앱으로 돌려준다.
    /// 아일랜드 패널은 화면에 그대로 두고(접히는 애니메이션이 끊기거나 한 프레임 비지 않게),
    /// 보이지 않는 패널을 잠깐 키 윈도우로 만들었다가 내린다. 넘기지 못했으면 예전처럼 패널을 내렸다 올린다.
    private func releaseKey(from panel: NotchPanel, geometry: NotchGeometry?) {
        releasingKey = true
        defer { releasingKey = false }
        let helper = keyReleasePanel
        if let geometry {
            helper.setFrameOrigin(CGPoint(x: geometry.frame.midX, y: geometry.frame.maxY - 1))
        }
        helper.makeKeyAndOrderFront(nil)
        helper.orderOut(nil)
        if panel.isKeyWindow || helper.isKeyWindow {
            logger.debug("보이지 않는 패널로 키 반납 실패 → 패널을 내렸다 올림")
            helper.orderOut(nil)
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    /// 이전과 다른 권한 요청이 보이기 시작했는지 (대기열 수만 바뀐 같은 요청은 제외)
    private static func showsNewPermission(_ mode: IslandMode, after previous: IslandMode?) -> Bool {
        guard case let .permission(request, _) = mode else { return false }
        if case let .permission(old, _)? = previous { return old.id != request.id }
        return true
    }

    // MARK: - 마우스 추적 / 클릭 통과

    private func installEventMonitors() {
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMouseState() }
        }) {
            eventMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: moveMask.union([.mouseEntered, .mouseExited]), handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateMouseState() }
            return event
        }) {
            eventMonitors.append(monitor)
        }
        // 다른 앱을 클릭하면 펼침을 접는다
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.presentation.clickedOutside() }
        }) {
            eventMonitors.append(monitor)
        }
        // 패널이 키 윈도우일 때의 단축키
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
            return handled ? nil : event
        }) {
            eventMonitors.append(monitor)
        }
    }

    /// 마우스 위치에 따라 활성 화면, 호버, 패널 클릭 통과 여부를 갱신
    func updateMouseState() {
        guard running else { return }
        let location = NSEvent.mouseLocation
        let geometries = presentation.screenOrder.compactMap { presentation.geometries[$0] }
        let active = geometries.first { $0.frame.contains(location) }
            ?? geometries.first { Self.containsInclusive($0.frame, location) }
        presentation.setActiveScreen(active?.screenID)

        // 마우스가 있는 화면의 아일랜드만 판정한다 (위아래로 붙은 화면 경계에서 오판 방지)
        var hovered: ScreenID?
        for (id, panel) in panels {
            let inside = id == active?.screenID && isInside(location, screen: id)
            // 비켜줄 날개 위에서는 커지는 효과를 주지 않는다 (곧 들어가므로)
            if inside, !wingRetract.isInBand(location, screen: id) { hovered = id }
            if panel.ignoresMouseEvents == inside {
                panel.ignoresMouseEvents = !inside
            }
        }
        presentation.setHoveredScreen(hovered)
        wingRetract.update(location: location, activeScreen: active?.screenID)
    }

    /// 아일랜드가 클릭을 받는 자리인지 (아이콘 구멍은 아래 메뉴바 아이템으로 통과)
    private func isInside(_ location: CGPoint, screen id: ScreenID) -> Bool {
        guard (hitRectCache[id] ?? []).contains(where: { Self.containsInclusive($0, location) }) else { return false }
        return !(passThroughCache[id] ?? []).contains { Self.containsInclusive($0, location) }
    }

    /// 아일랜드가 클릭을 받는 영역들 (Cocoa 전역 좌표). 숨김 · 투명 숨김이면 빈 배열.
    private func hitRects(_ state: ScreenState, geometry: NotchGeometry?) -> [CGRect] {
        guard let geometry, state.mode != .hidden, !state.concealed else { return [] }
        let layout = state.layout
        return layout.hitRects.map { rect in
            geometry.screenRect(fromPanel: rect.offsetBy(dx: layout.origin.x, dy: layout.origin.y))
        }
    }

    /// 클릭 통과 영역 (아이콘 구멍, Cocoa 전역)
    private func passThroughRects(_ state: ScreenState, geometry: NotchGeometry?) -> [CGRect] {
        guard let geometry, state.mode != .hidden, !state.concealed else { return [] }
        let layout = state.layout
        return layout.passThroughRects.map { rect in
            geometry.screenRect(fromPanel: rect.offsetBy(dx: layout.origin.x, dy: layout.origin.y))
        }
    }

    /// 화면 좌표가 아일랜드 위인지
    func isIslandHit(_ location: CGPoint) -> Bool {
        hitRectCache.keys.contains { isInside(location, screen: $0) }
    }

    /// 화면 맨 위 픽셀(y == maxY)도 포함하는 판정
    private static func containsInclusive(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    // MARK: - 단축키

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let window = event.window as? NotchPanel,
              let id = panels.first(where: { $0.value === window })?.key else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        switch event.keyCode {
        case 53: // ⎋
            return presentation.perform(.collapse, on: id)
        case 36, 76: // ↩, 키패드 엔터
            // 키를 누르고 있어 반복 입력된 이벤트로는 결정하지 않는다 (다음 요청까지 승인되지 않게)
            if event.isARepeat, flags.contains(.command) { return true }
            if flags == [.command] { return presentation.perform(.allow, on: id) }
            if flags == [.command, .option] { return presentation.perform(.allowAlways, on: id) }
            return false
        case 51, 117: // ⌫, ⌦
            if event.isARepeat, flags == [.command] { return true }
            if flags == [.command] { return presentation.perform(.deny, on: id) }
            return false
        default:
            return false
        }
    }

    // MARK: - 알림 (화면 변경, 스페이스 전환, 동작 줄이기)

    private func installNotifications() {
        let center = NotificationCenter.default
        let screenToken = center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildPanels()
                self?.scheduleFullscreenRefresh()
            }
        }
        notificationTokens.append((center, screenToken))

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleFullscreenRefresh() }
            }
            notificationTokens.append((workspace, token))
        }

        let motionToken = workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.presentation.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        }
        notificationTokens.append((workspace, motionToken))
    }

    // MARK: - 메뉴바 빈 공간 · 열린 메뉴 · 다른 노치 앱 감시

    private func startOverlapMonitoring() {
        spaceMonitor.screensProvider = { [weak self] in
            guard let self else { return [] }
            return self.presentation.screenOrder.compactMap { self.presentation.geometries[$0] }
        }
        // 1초 주기 측정은 접힌 상태가 보이는 화면이 있을 때만
        spaceMonitor.shouldPoll = { [weak self] in
            guard let self else { return false }
            return self.panels.keys.contains { id in
                let mode = self.presentation.mode(for: id)
                return mode == .idle || mode == .working
            }
        }
        spaceMonitor.onUpdate = { [weak self] spaces in
            self?.presentation.setSpaces(spaces)
        }
        spaceMonitor.start()

        overlapMonitor.ourLevel = NotchPanel.islandLevel.rawValue
        overlapMonitor.targetsProvider = { [weak self] in
            self?.overlapTargets() ?? []
        }
        overlapMonitor.onChange = { [weak self] state in
            guard let self else { return }
            self.presentation.setOccluded(state.occluded, concealed: state.concealed)
            self.presentation.setNotchConflicts(state.notchConflicts)
        }
        overlapMonitor.start { [weak self] location in
            self?.isIslandHit(location) ?? false
        }
    }

    /// 메뉴바 빈 공간을 지금 다시 잰다 (손쉬운 사용 권한 변경 등)
    func refreshMenuBarSpace() {
        spaceMonitor.refresh(forceAX: true)
    }

    /// 아일랜드가 보이는 화면의 감시 영역 (지금 아일랜드 + 카드가 펼쳐질 자리)
    private func overlapTargets() -> [OverlapScanner.Target] {
        let now = ProcessInfo.processInfo.systemUptime
        return panels.keys.compactMap { id in
            guard let geometry = presentation.geometries[id], presentation.mode(for: id) != .hidden,
                  let zones = presentation.overlapZones(for: id)
            else { return nil }
            return OverlapScanner.Target(
                id: id,
                screenFrame: geometry.frame,
                zone: geometry.screenRect(fromPanel: zones.zone),
                island: geometry.screenRect(fromPanel: zones.island),
                notchRect: geometry.notchRect?.insetBy(dx: 6, dy: 4),
                allowsNewConcealment: !isIslandBusy(id, now: now)
            )
        }
    }

    /// 접힌 상태를 새로 숨기면 안 되는 때: 펼치고 접는 중(모양이 자리 잡기 전) · 마우스가 아일랜드 위
    private func isIslandBusy(_ id: ScreenID, now: TimeInterval) -> Bool {
        if presentation.hoveredScreenID == id { return true }
        guard let changed = shapeChangedAt[id] else { return false }
        return now - changed < Self.shapeSettleTime
    }

    /// 모양이 바뀐 뒤 자리 잡았다고 보는 시간 (`IslandMotion.settleDelay` 와 같게)
    private static let shapeSettleTime: TimeInterval = {
        let parts = IslandMotion.settleDelay.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }()

    // MARK: - 풀스크린 감지 (best-effort)

    private func startFullscreenPolling() {
        fullscreenTask?.cancel()
        fullscreenTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let manager = self else { return }
                await manager.refreshFullscreen()
                try? await Task.sleep(for: .seconds(Self.fullscreenPollInterval))
            }
        }
    }

    /// 스페이스 전환 애니메이션이 끝난 뒤 한 번 더 확인
    private func scheduleFullscreenRefresh() {
        fullscreenRefreshTask?.cancel()
        fullscreenRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshFullscreen()
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.refreshFullscreen()
        }
    }

    /// 창 목록 조회(수 ms)는 메인 스레드 밖에서 한다.
    private func refreshFullscreen() async {
        guard running else { return }
        guard presentation.preferences.fullscreenBehavior != .showAll else {
            presentation.setFullscreenScreens([])
            return
        }
        let geometries = presentation.screenOrder.compactMap { presentation.geometries[$0] }
        // CG 좌표(원점 왼쪽 위, 주 화면 기준) → Cocoa 좌표 변환용
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let result = await Task.detached(priority: .utility) {
            FullscreenDetector.fullscreenScreens(geometries, primaryHeight: primaryHeight)
        }.value
        guard running, !Task.isCancelled else { return }
        presentation.setFullscreenScreens(result)
    }
}

/// 화면 녹화 권한 없이 얻을 수 있는 창 정보(경계, 레이어, 소유 PID)만으로 풀스크린을 추정한다.
/// 레이어 0 창이 화면 전체를 덮고, 그 화면에 메뉴바 창이 없으면 풀스크린으로 본다.
enum FullscreenDetector {
    static func fullscreenScreens(_ geometries: [NotchGeometry], primaryHeight: CGFloat) -> Set<ScreenID> {
        guard !geometries.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }

        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        let menuBarLevels: Set<Int> = [
            Int(CGWindowLevelForKey(.mainMenuWindow)),
            Int(CGWindowLevelForKey(.statusWindow)),
        ]

        var covered = Set<ScreenID>()
        var menuBarVisible = Set<ScreenID>()

        for info in list {
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1
            if pid == ownPID { continue }

            let rect = CGRect(
                x: bounds.minX,
                y: primaryHeight - bounds.maxY,
                width: bounds.width,
                height: bounds.height
            )

            for geometry in geometries {
                let screen = geometry.frame
                if layer == 0, approximatelyEqual(rect, screen) {
                    covered.insert(geometry.screenID)
                } else if menuBarLevels.contains(layer),
                          rect.intersects(screen),
                          abs(rect.maxY - screen.maxY) < 2 {
                    menuBarVisible.insert(geometry.screenID)
                }
            }
        }
        return covered.subtracting(menuBarVisible)
    }

    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2
            && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
}
