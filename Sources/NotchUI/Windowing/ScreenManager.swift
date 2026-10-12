import AppKit
import Observation
import SwiftUI
import NotchCore
import os

/// 화면마다 패널 하나를 두고, 클릭 통과·마우스 추적·풀스크린 감지·단축키를 처리한다.
@MainActor
final class ScreenManager {
    private let presentation: PresentationController
    private let makeRootView: @MainActor (ScreenID) -> AnyView

    private var panels: [ScreenID: NotchPanel] = [:]
    private var lastModes: [ScreenID: IslandMode] = [:]
    private var eventMonitors: [Any] = []
    private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var fullscreenTask: Task<Void, Never>?
    private var fullscreenRefreshTask: Task<Void, Never>?
    private var running = false
    /// stop/start 를 반복해도 관찰 루프가 겹치지 않게 하는 세대 번호
    private var generation = 0

    private let logger = Logger(subsystem: "AgentNotch", category: "Screens")

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
        rebuildPanels()
        installEventMonitors()
        installNotifications()
        startFullscreenPolling()
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
        for panel in panels.values {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panels.removeAll()
        lastModes.removeAll()
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
        updateMouseState()
    }

    private func makePanel(for geometry: NotchGeometry) -> NotchPanel {
        let id = geometry.screenID
        let panel = NotchPanel(frame: geometry.panelFrame)
        panel.allowsKey = { [weak presentation] in
            presentation?.mode(for: id).wantsKey ?? false
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

    private func armModeObservation() {
        guard running else { return }
        let ids = Array(panels.keys)
        let current = generation
        let modes = withObservationTracking {
            Dictionary(uniqueKeysWithValues: ids.map { ($0, presentation.mode(for: $0)) })
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == current else { return }
                self.armModeObservation()
            }
        }
        applyModes(modes)
    }

    private func applyModes(_ modes: [ScreenID: IslandMode]) {
        for (id, mode) in modes where lastModes[id] != mode {
            lastModes[id] = mode
            guard let panel = panels[id] else { continue }
            // 접히면 키 윈도우를 반납해 원래 앱으로 키보드 포커스를 돌려준다
            if !mode.wantsKey, panel.isKeyWindow {
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        }
        updateMouseState()
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
            let inside = id == active?.screenID
                && (islandRect(for: id).map { Self.containsInclusive($0, location) } ?? false)
            if inside { hovered = id }
            if panel.ignoresMouseEvents == inside {
                panel.ignoresMouseEvents = !inside
            }
        }
        presentation.setHoveredScreen(hovered)
    }

    /// 지금 모드의 아일랜드 사각형 (화면 좌표). 숨김이면 nil.
    private func islandRect(for id: ScreenID) -> CGRect? {
        guard let geometry = presentation.geometries[id] else { return nil }
        let mode = presentation.mode(for: id)
        guard mode != .hidden else { return nil }
        let layout = presentation.layout(for: mode, geometry: geometry)
        return geometry.islandRect(size: layout.frameSize)
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
            if flags == [.command] { return presentation.perform(.allow, on: id) }
            if flags == [.command, .option] { return presentation.perform(.allowAlways, on: id) }
            return false
        case 51, 117: // ⌫, ⌦
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
