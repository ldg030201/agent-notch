import AppKit
import Observation
import SwiftUI
import NotchCore
import NotchShared
import os

/// 화면마다 패널 하나를 두고, 클릭 통과·마우스 추적·풀스크린 감지·단축키·메뉴바 겹침 감시를 처리한다.
@MainActor
final class ScreenManager {
    private let presentation: PresentationController
    private let makeRootView: @MainActor (ScreenID) -> AnyView
    private let spaceMonitor = MenuBarSpaceMonitor()
    private let overlapMonitor = OverlapMonitor()

    /// 화면 하나의 패널과 마지막으로 적용한 표시 상태
    private struct Screen {
        let panel: NotchPanel
        var lastMode: IslandMode?
        /// 마지막으로 그린 모양(애니메이션 값)과 바뀐 시각 (부팅 후 초). 모양이 바뀌는 동안엔 접힌 상태를 새로 숨기지 않는다
        var lastShape: IslandLayout?
        var shapeChangedAt: TimeInterval?
        /// 클릭 영역 (Cocoa 전역). 마우스 이동마다 레이아웃을 다시 계산하지 않도록 상태가 바뀔 때만 갱신한다.
        var hitRects: [CGRect] = []
        /// 열린 메뉴 겹침 감시 영역 (아일랜드가 보일 때만). 0.25초마다 레이아웃을 다시 계산하지 않도록 상태가 바뀔 때만 갱신한다
        var overlapTarget: OverlapScanner.Target?
    }

    private var screens: [ScreenID: Screen] = [:]
    private var eventMonitors: [Any] = []
    private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var fullscreenTask: Task<Void, Never>?
    private var fullscreenRefreshTask: Task<Void, Never>?
    private var running = false
    /// 키 반납용 보이지 않는 패널 (`KeyReleasePanel`)
    private lazy var keyReleasePanel = KeyReleasePanel()
    /// 키를 반납하는 동안엔 아일랜드 패널이 다시 키 윈도우가 되지 않게 한다
    private var releasingKey = false
    /// 모드 관찰을 걸 때마다 올리는 번호. 마지막으로 건 관찰만 다시 걸어서
    /// stop/start · 화면 변경으로 새로 걸어도 관찰 루프가 겹치지 않는다
    private var modeObservationSeq = 0

    private let logger = Logger(subsystem: NotchWire.logSubsystem, category: "Screens")

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
        presentation.onRequestKey = { [weak self] id in self?.makeKey(id) }
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
        for id in Array(screens.keys) { removeScreen(id) }
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

        for id in screens.keys where !ids.contains(id) { removeScreen(id) }

        presentation.updateScreens(geometries)

        for geometry in geometries {
            let id = geometry.screenID
            if let panel = screens[id]?.panel {
                if panel.frame != geometry.panelFrame {
                    panel.setFrame(geometry.panelFrame, display: true)
                }
            } else {
                screens[id] = Screen(panel: makePanel(for: geometry))
            }
        }
        logger.info("패널 재구성: 화면 \(geometries.count, privacy: .public)개")
        spaceMonitor.screensChanged()
        updateMouseState()
    }

    /// 패널을 내리고 화면 상태를 지운다
    private func removeScreen(_ id: ScreenID) {
        guard let panel = screens.removeValue(forKey: id)?.panel else { return }
        panel.orderOut(nil)
        panel.contentView = nil
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
        guard let panel = screens[id]?.panel, panel.canBecomeKey, !panel.isKeyWindow else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - 모드 변화 감시 (화면 상태 커밋, 키 윈도우 반납, 클릭 영역 갱신)

    private typealias ScreenFrame = PresentationController.ScreenFrame

    /// 관찰 패스: 모든 화면의 표시 상태(모드 · 레이아웃 · 투명 숨김)를 한 번에 계산해 커밋 · 적용하고,
    /// 그중 하나라도 바뀌면 다시 건다. 화면 상태(배치 이력 · 붙잡은 띠 · 접힌 폭 안정화)는 여기서 커밋할 때만 바뀐다.
    /// 화면 구성(`geometries`)도 함께 읽어, 패널이 하나도 없을 때(하나뿐인 모니터를 끔 · 덮개를 닫고 외부 모니터를 뺌 ·
    /// 화면 없이 실행)도 화면이 다시 생기면 깨어난다. 화면이 바뀌면 `rebuildPanels` 뒤에 바로 다시 건다 (사라진 화면 이력도 이때 지운다)
    private func armModeObservation() {
        guard running else { return }
        modeObservationSeq &+= 1
        let ids = Array(screens.keys)
        let current = modeObservationSeq
        let states = withObservationTracking {
            _ = presentation.geometries
            return presentation.frames(for: ids)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                // 그 사이 새로 걸었으면(화면 변경 · stop/start) 이 관찰은 끝 (관찰 루프가 겹치지 않게)
                guard let self, self.running, self.modeObservationSeq == current else { return }
                self.armModeObservation()
            }
        }
        presentation.commit(states)
        applyModes(states)
    }

    private func applyModes(_ states: [ScreenID: ScreenFrame]) {
        var becameCompact = false
        let now = ProcessInfo.processInfo.systemUptime
        for (id, state) in states {
            guard var screen = screens[id] else { continue }
            let geometry = presentation.geometries[id]
            let shape = state.layout.animationKey
            if screen.lastShape != shape {
                if screen.lastShape != nil { screen.shapeChangedAt = now }
                screen.lastShape = shape
            }
            screen.hitRects = Self.globalRects(state.layout.panelHitRects, state, geometry: geometry)
            screen.overlapTarget = overlapTarget(id, state, geometry: geometry)
            let previous = screen.lastMode
            screen.lastMode = state.mode
            screens[id] = screen
            guard previous != state.mode else { continue }
            if !(previous?.isCompact ?? false), state.mode.isCompact { becameCompact = true }
            // 접히면 키 윈도우를 반납해 원래 앱으로 키보드 포커스를 돌려준다.
            // 다른 권한 요청이 새로 보이게 돼도 반납한다 (보지 못한 요청을 단축키로 결정하지 않게, 다시 클릭해야 함)
            if !state.mode.wantsKey || Self.showsNewPermission(state.mode, after: previous), screen.panel.isKeyWindow {
                releaseKey(from: screen.panel, geometry: geometry)
            }
        }
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
        for (id, screen) in screens {
            let panel = screen.panel
            let inside = id == active?.screenID && isInside(location, screen: id)
            if inside { hovered = id }
            if panel.ignoresMouseEvents == inside {
                panel.ignoresMouseEvents = !inside
            }
        }
        presentation.setHoveredScreen(hovered)
    }

    /// 아일랜드가 클릭을 받는 자리인지
    private func isInside(_ location: CGPoint, screen id: ScreenID) -> Bool {
        screens[id]?.hitRects.contains { Self.containsInclusive($0, location) } ?? false
    }

    /// 패널 기준 사각형(클릭 영역) → Cocoa 전역 좌표. 숨김 · 투명 숨김이면 빈 배열.
    private static func globalRects(_ rects: [CGRect], _ state: ScreenFrame, geometry: NotchGeometry?) -> [CGRect] {
        guard let geometry, state.mode != .hidden, !state.concealed else { return [] }
        return rects.map(geometry.screenRect(fromPanel:))
    }

    /// 화면 좌표가 아일랜드 위인지
    func isIslandHit(_ location: CGPoint) -> Bool {
        screens.keys.contains { isInside(location, screen: $0) }
    }

    /// 화면 맨 위 픽셀(y == maxY)도 포함하는 판정
    private static func containsInclusive(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    // MARK: - 단축키

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let window = event.window as? NotchPanel,
              let id = screens.first(where: { $0.value.panel === window })?.key else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        // 질문 카드의 "기타" 글자 입력 중: ↩ · 숫자 · ⌫ 는 입력란이 받는다 (↩ 는 입력란이 보내기로 처리)
        let fieldEditor = window.firstResponder as? NSTextView
        switch event.keyCode {
        case 53: // ⎋
            // 한글 등 조합 중인 글자가 있으면 입력기가 먼저 받는다
            if fieldEditor?.hasMarkedText() == true { return false }
            return presentation.perform(.collapse, on: id)
        case 36, 76: // ↩, 키패드 엔터
            // 키를 누르고 있어 반복 입력된 이벤트로는 결정하지 않는다 (다음 요청까지 승인되지 않게)
            if event.isARepeat, flags.contains(.command) || flags.isEmpty { return true }
            if flags == [.command] { return presentation.perform(.allow, on: id) }
            if flags == [.command, .option] { return presentation.perform(.allowAlways, on: id) }
            if flags.isEmpty, fieldEditor == nil { return presentation.perform(.submit, on: id) }
            return false
        case 51, 117: // ⌫, ⌦
            if event.isARepeat, flags == [.command] { return true }
            if flags == [.command], fieldEditor == nil { return presentation.perform(.deny, on: id) }
            return false
        default:
            // 숫자 1–4: 질문 카드 선택지
            if fieldEditor == nil, !event.isARepeat,
               let digit = Self.optionDigit(characters: event.characters, keyCode: event.keyCode, flags: flags) {
                return presentation.perform(.pick(digit), on: id)
            }
            return false
        }
    }

    /// 질문 카드 선택지 위치 (0–3). 입력된 글자가 숫자면 그 숫자로 고른다 (⇧ 허용: AZERTY 처럼 ⇧ 를 눌러야 숫자가 나오는 자판).
    /// 숫자가 아닌 글자를 내면 수식키 없이 누른 위 줄 · 키패드 1–4 자리로 고른다 (AZERTY 의 "&" 자리 = 1)
    static func optionDigit(characters: String?, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Int? {
        let flags = flags.intersection([.command, .option, .shift, .control])
        guard flags.isSubset(of: [.shift]) else { return nil }
        if let typed = characters, typed.count == 1, let value = typed.first?.wholeNumberValue {
            return (1...4).contains(value) ? value - 1 : nil
        }
        guard flags.isEmpty else { return nil }
        return optionDigits[keyCode]
    }

    /// 숫자 키 자리 → 선택지 위치 (1–4 위 줄 · 키패드, 자판 배치와 무관한 키 코드)
    private static let optionDigits: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 83: 0, 84: 1, 85: 2, 86: 3]

    // MARK: - 알림 (화면 변경, 스페이스 전환, 동작 줄이기)

    private func installNotifications() {
        let center = NotificationCenter.default
        let screenToken = center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildPanels()
                // 새 패널 목록으로 관찰을 다시 걸고 클릭 영역을 바로 채운다 (패널이 없던 동안 관찰할 화면이 없었을 수 있다)
                self?.armModeObservation()
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

    // MARK: - 메뉴바 빈 공간 · 열린 메뉴 감시

    private func startOverlapMonitoring() {
        spaceMonitor.screensProvider = { [weak self] in
            guard let self else { return [] }
            return self.presentation.screenOrder.compactMap { self.presentation.geometries[$0] }
        }
        // 1초 주기 측정은 접힌 상태가 보이는 화면이 있을 때만
        spaceMonitor.shouldPoll = { [weak self] in
            self?.screens.values.contains { $0.lastMode?.isCompact == true } ?? false
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
        }
        overlapMonitor.start { [weak self] location in
            self?.isIslandHit(location) ?? false
        }
    }

    /// 아일랜드가 보이는 화면의 감시 영역 (지금 아일랜드 + 카드가 펼쳐질 자리).
    /// 영역은 표시 상태가 바뀔 때 계산해 둔 것을 쓰고, 지금 숨겨도 되는지만 새로 본다
    private func overlapTargets() -> [OverlapScanner.Target] {
        let now = ProcessInfo.processInfo.systemUptime
        return screens.compactMap { id, screen in
            guard var target = screen.overlapTarget else { return nil }
            target.allowsNewConcealment = !isIslandBusy(id, now: now)
            return target
        }
    }

    /// 화면의 감시 영역 (Cocoa 전역). 아일랜드를 숨겼으면 nil
    private func overlapTarget(_ id: ScreenID, _ state: ScreenFrame, geometry: NotchGeometry?) -> OverlapScanner.Target? {
        guard let geometry, state.mode != .hidden, let zones = presentation.overlapZones(for: id, layout: state.layout) else { return nil }
        return OverlapScanner.Target(
            id: id,
            screenFrame: geometry.frame,
            zone: geometry.screenRect(fromPanel: zones.zone),
            island: geometry.screenRect(fromPanel: zones.island),
            notchRect: geometry.notchRect?.insetBy(dx: 6, dy: 4)
        )
    }

    /// 접힌 상태를 새로 숨기면 안 되는 때: 펼치고 접는 중(모양이 자리 잡기 전, `IslandMotion.settleDelay`) · 마우스가 아일랜드 위
    private func isIslandBusy(_ id: ScreenID, now: TimeInterval) -> Bool {
        if presentation.hoveredScreenID == id { return true }
        guard let changed = screens[id]?.shapeChangedAt else { return false }
        return now - changed < IslandMotion.settleSeconds
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
        guard !geometries.isEmpty else { return [] }
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        let menuBarLevels: Set<Int> = [WindowLevels.mainMenu, WindowLevels.status]

        var covered = Set<ScreenID>()
        var menuBarVisible = Set<ScreenID>()

        for window in WindowSnapshot.capture(primaryHeight: primaryHeight).windows where window.pid != ownPID {
            let rect = window.frame
            for geometry in geometries {
                let screen = geometry.frame
                if window.layer == 0, approximatelyEqual(rect, screen) {
                    covered.insert(geometry.screenID)
                } else if menuBarLevels.contains(window.layer),
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
