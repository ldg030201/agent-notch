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
        var panel: NotchPanel
        var lastMode: IslandMode?
        /// 마지막으로 그린 모양(애니메이션 값)과 바뀐 시각 (부팅 후 초). 모양이 바뀌는 동안엔 접힌 상태를 새로 숨기지 않는다
        var lastShape: IslandLayout?
        var shapeChangedAt: TimeInterval?
        /// 클릭 영역 (Cocoa 전역). 마우스 이동마다 레이아웃을 다시 계산하지 않도록 상태가 바뀔 때만 갱신한다.
        var hitRects: [CGRect] = []
        /// 열린 메뉴 겹침 감시 영역 (아일랜드가 보일 때만). 0.25초마다 레이아웃을 다시 계산하지 않도록 상태가 바뀔 때만 갱신한다
        var overlapTarget: OverlapScanner.Target?
        /// 패널이 화면에 없다고 본 연속 횟수 (`reviveMissingPanels`)
        var missingChecks = 0
        /// 다시 만든 뒤로 아직 화면에서 보지 못함 (잠금 화면처럼 모든 창이 빠지는 동안 계속 다시 만들지 않게 더 오래 기다린다)
        var revivedUnseen = false
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
    /// 비켜주기: 마우스가 접힌 아일랜드 위에 머무는 화면의 시계 (`dodgeDelay` 가 지나면 비킨다)
    private var dodgeTimers: [ScreenID: Task<Void, Never>] = [:]
    /// 비킨 화면 → 비킨 자리 (Cocoa 전역, 여유 포함). 마우스가 이 밖으로 나가면 다시 보인다
    private var dodgeAreas: [ScreenID: CGRect] = [:]
    /// 비킨 자리에서 마우스가 나간 화면의 시계 (`dodgeReturnDelay` 가 지나면 다시 보인다)
    private var returnTimers: [ScreenID: Task<Void, Never>] = [:]

    private let logger = Logger(subsystem: NotchWire.logSubsystem, category: "Screens")

    /// 풀스크린 감지 · 패널 확인 주기(초). 설정이 "전부 표시"면 풀스크린은 감지하지 않는다 (패널 확인은 늘 한다)
    private static let fullscreenPollInterval: Double = 2
    /// 비켜주기: 접힌 아일랜드 위에 마우스를 이만큼(초) 올려 두면 비킨다 (클릭하면 예전처럼 펼친다)
    static let dodgeDelay: Double = 2.5
    /// 비킨 자리에서 마우스가 나간 뒤 다시 보이기까지(초). 경계를 스치거나 뒤를 클릭하고 살짝 움직여도 바로 돌아오지 않게
    static let dodgeReturnDelay: Double = 0.5
    /// 비킨 자리 둘레 여유 (pt)
    static let dodgeMargin: CGFloat = 6

    /// 패널이 이 횟수만큼 연속으로 화면에 없으면 다시 만든다 (Space 전환 중 잠깐 빠지는 것과 헷갈리지 않게).
    /// 다시 만든 패널도 아직 못 봤으면 훨씬 오래 기다린다 (약 30초)
    private static let missingChecksBeforeRevive = 2
    private static let missingChecksAfterRevive = 15

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
        dodgeTimers.removeValue(forKey: id)?.cancel()
        endDodge(id)
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
            // 비켜주기 시계는 접힌 상태에 머문 시간만 잰다. 펼치거나 숨으면 비킨 것도 끝낸다
            dodgeTimers.removeValue(forKey: id)?.cancel()
            if !state.mode.isCompact { endDodge(id) }
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
        updateDodge(hovered: hovered, location: location)
    }

    // MARK: - 마우스를 올려 두면 비켜주기

    /// 접힌 아일랜드가 뒤의 탭 · 버튼을 가릴 때: 마우스를 `dodgeDelay` 동안 올려 두면(클릭 없이) 투명하게 비켜 클릭을 뒤로 통과시키고,
    /// 마우스가 비킨 자리(`dodgeMargin` 여유)를 떠나면 `dodgeReturnDelay` 뒤 다시 보인다. 비킨 동안 온 알림은 다시 보일 때 띄운다
    /// (`PresentationController.dodgedScreenIDs`). 펼친 카드 · 알림 카드는 비키지 않는다 (버튼을 눌러야 한다)
    private func updateDodge(hovered: ScreenID?, location: CGPoint) {
        guard presentation.dodgesOnHover else {
            for id in Array(dodgeTimers.keys) { dodgeTimers.removeValue(forKey: id)?.cancel() }
            for id in Array(dodgeAreas.keys) { endDodge(id) }
            return
        }
        // 비킨 화면: 비킨 자리 안에 있으면 그대로, 나가면 잠시 뒤 다시 보인다 (돌아오면 취소)
        for (id, area) in dodgeAreas {
            if Self.containsInclusive(area, location) {
                returnTimers.removeValue(forKey: id)?.cancel()
            } else if returnTimers[id] == nil {
                returnTimers[id] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(Self.dodgeReturnDelay))
                    guard !Task.isCancelled else { return }
                    self?.endDodge(id)
                }
            }
        }
        // 마우스가 떠난 화면의 시계는 멈춘다 (계속 올려 둔 시간만 잰다)
        for id in Array(dodgeTimers.keys) where id != hovered {
            dodgeTimers.removeValue(forKey: id)?.cancel()
        }
        guard let id = hovered, dodgeTimers[id] == nil, dodgeAreas[id] == nil,
              screens[id]?.lastMode?.isCompact == true else { return }
        dodgeTimers[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.dodgeDelay))
            guard !Task.isCancelled else { return }
            self?.dodge(id)
        }
    }

    /// 지금 접힌 아일랜드 자리를 기억하고 비킨다 (마우스가 아직 그 위에 있고 접힌 상태일 때만)
    private func dodge(_ id: ScreenID) {
        dodgeTimers[id] = nil
        guard running, let screen = screens[id], presentation.hoveredScreenID == id,
              screen.lastMode?.isCompact == true, let first = screen.hitRects.first else { return }
        let area = screen.hitRects.dropFirst().reduce(first) { $0.union($1) }
            .insetBy(dx: -Self.dodgeMargin, dy: -Self.dodgeMargin)
        dodgeAreas[id] = area
        logger.debug("마우스를 올려 둬서 비킴: 화면 \(id, privacy: .public)")
        // 관찰 패스가 투명 숨김을 적용하고 클릭 영역을 비운다 (그 뒤 클릭은 뒤의 앱으로 간다)
        presentation.setDodged(id, true)
    }

    /// 비킨 것을 끝내고 다시 보인다
    private func endDodge(_ id: ScreenID) {
        returnTimers.removeValue(forKey: id)?.cancel()
        guard dodgeAreas.removeValue(forKey: id) != nil else { return }
        logger.debug("비킨 자리를 떠나 다시 보임: 화면 \(id, privacy: .public)")
        presentation.setDodged(id, false)
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

    /// 창 목록 조회(수 ms)는 메인 스레드 밖에서 한다. 같은 목록으로 풀스크린 화면과 화면에 떠 있는 우리 패널을 함께 본다
    private func refreshFullscreen() async {
        guard running else { return }
        let detectsFullscreen = presentation.preferences.fullscreenBehavior != .showAll
        let geometries = presentation.screenOrder.compactMap { presentation.geometries[$0] }
        // CG 좌표(원점 왼쪽 위, 주 화면 기준) → Cocoa 좌표 변환용
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let (fullscreen, ownOnScreen) = await Task.detached(priority: .utility) {
            let snapshot = WindowSnapshot.capture(primaryHeight: primaryHeight)
            let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
            let own = Set(snapshot.windows.lazy.filter { $0.pid == ownPID }.map(\.number))
            let fullscreen = detectsFullscreen ? FullscreenDetector.fullscreenScreens(geometries, snapshot: snapshot) : []
            return (fullscreen, own)
        }.value
        guard running, !Task.isCancelled else { return }
        presentation.setFullscreenScreens(fullscreen)
        reviveMissingPanels(onScreen: ownOnScreen)
    }

    // MARK: - 화면에서 빠진 패널 다시 만들기

    /// 화면에 떠 있어야 할 패널이 창 목록에 없으면 다시 만든다.
    ///
    /// 패널은 모든 Space 에 나오지만(`canJoinAllSpaces`), macOS 는 패널을 띄울 때 그 화면이 보고 있지 않던 다른 앱의
    /// 전체 화면 Space 에는 넣지 않는다. 모니터를 다시 연결하며 전체 화면 앱의 Space 가 먼저 복원되면, 그 화면이 전체 화면
    /// Space 로 넘어가는 순간 아일랜드가 사라진다. 이렇게 빠진 패널은 다시 올리거나(orderFront) 내렸다 올려도, 동작 설정을
    /// 다시 넣어도 그 Space 에 들어가지 않고, 새로 만든 패널만 들어간다 (실제 화면에서 확인).
    /// 패널은 지울 때 말고는 내리지 않으므로(내용만 투명) 창 목록에 없으면 빠진 것이다
    private func reviveMissingPanels(onScreen: Set<Int>) {
        for (id, screen) in screens {
            if onScreen.contains(screen.panel.windowNumber) {
                if screen.missingChecks != 0 || screen.revivedUnseen {
                    screens[id]?.missingChecks = 0
                    screens[id]?.revivedUnseen = false
                }
                continue
            }
            let misses = screen.missingChecks + 1
            let limit = screen.revivedUnseen ? Self.missingChecksAfterRevive : Self.missingChecksBeforeRevive
            guard misses >= limit else {
                screens[id]?.missingChecks = misses
                continue
            }
            recreatePanel(id)
        }
    }

    /// 화면 상태(표시 이력 · 클릭 영역 등)는 그대로 두고 패널만 새로 만든다
    private func recreatePanel(_ id: ScreenID) {
        guard var screen = screens[id], let geometry = presentation.geometries[id] else { return }
        let old = screen.panel
        old.orderOut(nil)
        old.contentView = nil
        screen.panel = makePanel(for: geometry)
        screen.missingChecks = 0
        screen.revivedUnseen = true
        screens[id] = screen
        logger.info("화면에 없는 패널을 다시 만듦 (다른 앱의 전체 화면 Space 등)")
        updateMouseState()
    }
}

/// 화면 녹화 권한 없이 얻을 수 있는 창 정보(경계, 레이어, 소유 PID)만으로 풀스크린을 추정한다.
/// 레이어 0 창이 화면 전체를 덮고, 그 화면에 메뉴바 창이 없으면 풀스크린으로 본다.
enum FullscreenDetector {
    static func fullscreenScreens(_ geometries: [NotchGeometry], snapshot: WindowSnapshot) -> Set<ScreenID> {
        guard !geometries.isEmpty else { return [] }
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        let menuBarLevels: Set<Int> = [WindowLevels.mainMenu, WindowLevels.status]

        var covered = Set<ScreenID>()
        var menuBarVisible = Set<ScreenID>()

        for window in snapshot.windows where window.pid != ownPID {
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
