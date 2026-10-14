import AppKit
import SwiftUI
import NotchCore
import NotchShared

// 표시 상태 · 클릭 · 키 처리 검사 (전환 시트가 함께 돌리는 순수 계산 검사).
// - 승인 대기 (`SnapshotDecisionCheck`): 막 보인 요청은 클릭 · 단축키 모두 승인하지 않는다 (다음 요청이 제자리에 바뀌어 들어온 순간 포함)
// - 숨김 → 카드 · 화면 재연결 (`SnapshotLayoutHistoryCheck`): 숨기기 전 · 화면이 빠지기 전 배치 이력을 쓰지 않는다
// - 클릭 모양 · 숫자 키 · 상태 아이템 시작 (`SnapshotInputCheck`)

// MARK: - 승인 대기

/// 요청 카드가 보인 지 `PresentationController.shortcutSettleDelay` 가 지나야 승인(허용 · 항상 허용 · 계획 승인 · 답)을 전달하는지.
/// 승인 대기는 모드가 바뀐 때가 아니라 아일랜드 뷰가 내용 교체를 끝내 그 요청 카드가 나타난 때부터 잰다.
/// 시간은 표시 상태의 시계(`uptime`)를 돌려서 재고, 내용 교체는 실제 패널의 `IslandViewState` 를 `IslandContainer` 순서대로 돌린다
@MainActor
enum SnapshotDecisionCheck {
    /// 결정을 받아 스토어에 적용하는 표시 상태 하나 (노치 화면 1개)
    @MainActor
    private final class Harness {
        var world: SnapshotWorld
        let presentation: PresentationController
        let screenID: ScreenID
        var now: TimeInterval = 1000
        var delivered: [(id: UUID, decision: PermissionDecision)] = []
        /// 패널 뷰 상태와 마지막으로 그린 내용 (모드 · 레이아웃 · 구조)
        private let view = IslandViewState()
        private var shownKey: IslandContentKey?
        private var current: IslandShownContent?
        /// 흐리는 중인 교체 (끝나면 보일 내용 구조 · 흐리기 시작한 시각 · 교체 지연)
        private var pendingSwap: (key: IslandContentKey, start: TimeInterval, delay: TimeInterval)?

        init?() {
            guard let defaults = MemoryDefaults() else { return nil }
            var world = SnapshotWorld()
            world.startSessions()
            self.world = world
            let actions = SnapshotActions()
            presentation = PresentationController(store: world.store, preferences: AppPreferences(defaults: defaults), actions: actions)
            let bar = SnapshotMenuBar(style: .notch, crowding: .roomy)
            screenID = bar.geometry.screenID
            presentation.updateScreens([bar.geometry])
            presentation.setActiveScreen(screenID)
            presentation.setSpaces([screenID: bar.space])
            presentation.uptime = { [unowned self] in self.now }
            let store = world.store
            actions.onResolvePermission = { [unowned self] id, decision in
                self.delivered.append((id, decision))
                store.resolvePermission(id: id, decision: decision)
            }
            // 처음 붙은 패널: 지금 내용(접힌 상태)이 바로 보인다
            _ = render(finishing: true)
        }

        /// 렌더 한 번 (`IslandContainer`): 관찰 패스를 돌리고, 내용 구조가 바뀌었으면 이전 내용을 흐리기 시작한다.
        /// `finishing` 이면 교체 지연(`contentDelay`)만큼 시계를 돌려 새 내용이 나타나게 한다
        func render(finishing: Bool) -> PermissionRequestInfo? {
            let frame = presentation.commitScreens()[screenID]
            let mode = frame?.mode ?? .hidden
            let layout = frame?.layout ?? IslandLayout(size: .zero, origin: .zero, shape: IslandShapeSpec())
            let key = IslandContentKey(mode: mode, layout: layout)
            current = IslandShownContent(mode: mode, layout: layout)
            _ = view.outgoingContent(current: mode, layout: layout, reduceMotion: false)
            if key != shownKey {
                let first = shownKey == nil
                shownKey = key
                pendingSwap = nil
                presentation.contentWillChange(on: screenID)
                if first {
                    presentation.contentDidAppear(key, on: screenID)
                } else {
                    switch view.beginSwap(to: key, reduceMotion: false) {
                    case .none, .restore:
                        presentation.contentDidAppear(key, on: screenID)
                    case .fadeOut:
                        let delay = view.contentDelay(to: key).components
                        pendingSwap = (key, now, Double(delay.seconds) + Double(delay.attoseconds) / 1e18)
                    }
                }
            }
            if finishing { finishSwap() }
            if case let .permission(request, _) = mode { return request }
            return nil
        }

        /// 지금 카드에 보이는 요청 (렌더 한 번 · 내용 교체가 끝날 때까지)
        func shown() -> PermissionRequestInfo? {
            render(finishing: true)
        }

        /// 흐리는 중인 교체를 끝낸다: 흐리기 시작한 뒤 교체 지연까지 시계가 흐르고 새 내용이 나타난다
        func finishSwap() {
            guard let swap = pendingSwap else { return }
            pendingSwap = nil
            now = max(now, swap.start + swap.delay)
            view.finishSwap()
            // 교체가 끝나면 다음 렌더부터 지금 내용을 그린다
            if let current { _ = view.outgoingContent(current: current.mode, layout: current.layout, reduceMotion: false) }
            presentation.contentDidAppear(swap.key, on: screenID)
        }

        /// 내용 교체 지연 (흐리기 시작 → 새 내용이 나타날 때까지, 초). 교체 중이 아니면 0
        var swapDelay: TimeInterval { pendingSwap?.delay ?? 0 }

        /// api-server 의 Bash 권한 요청 (예시 명령)
        func apiServerAsks(_ command: String, at seconds: TimeInterval) {
            let input: [String: Any] = ["command": command, "description": "정리"]
            world.send(SnapshotWorld.apiServer, "PreToolUse", at: seconds, [
                "tool_name": "Bash", "tool_input": input, "tool_use_id": "toolu_check_\(Int(seconds))",
            ])
            world.send(SnapshotWorld.apiServer, "PermissionRequest", at: seconds + 0.5, ["tool_name": "Bash", "tool_input": input])
        }
    }

    static func run() -> (cases: Int, problems: [String]) {
        var problems: [String] = []
        var cases = 0
        guard let h = Harness(), let q = Harness() else { return (1, ["표시 상태를 만들 수 없음"]) }

        /// `action` 으로 결정이 전달됐는지 (`expected`)
        func expect(_ name: String, _ harness: Harness, delivered expected: Bool, _ action: () -> Void) {
            cases += 1
            let before = harness.delivered.count
            action()
            let got = harness.delivered.count > before
            if got != expected { problems.append("\(name): 결정이 \(expected ? "전달돼야" : "막혀야") 하는데 반대") }
        }

        // 권한 요청 둘 (web-app → api-server). 카드가 보인 순간부터 잰다
        h.world.webAppAsksPermission()
        h.apiServerAsks("rm -rf build", at: 845)
        guard let first = h.shown() else { return (cases + 1, ["첫 권한 요청 카드가 안 보임"]) }
        h.now += 0.1
        expect("첫 요청 직후 허용 클릭", h, delivered: false) { h.presentation.resolve(first, decision: .allow) }
        expect("첫 요청 직후 항상 허용 클릭", h, delivered: false) { h.presentation.resolve(first, decision: .allowAlways) }
        expect("첫 요청 직후 ⌘↩", h, delivered: false) { _ = h.presentation.perform(.allow, on: h.screenID) }
        h.now += 0.5
        expect("첫 요청 0.6초 뒤 허용 클릭", h, delivered: true) { h.presentation.resolve(first, decision: .allow) }

        // 다음 요청이 같은 카드 자리에 바뀌어 들어옴 → 두 번째 클릭(더블클릭)은 새 요청을 승인하지 않는다.
        // 이전 요청 카드가 흐려지는 동안(내용 교체 중)과 새 카드가 나타난 직후 모두
        guard let second = h.render(finishing: false), second.id != first.id else {
            return (cases + 1, problems + ["다음 권한 요청 카드가 안 보임"])
        }
        cases += 1
        if IslandContentKey(mode: .permission(first, queueCount: 2), layout: IslandLayout(size: .zero, origin: .zero, shape: IslandShapeSpec()))
            == IslandContentKey(mode: .permission(second, queueCount: 1), layout: IslandLayout(size: .zero, origin: .zero, shape: IslandShapeSpec())) {
            problems.append("다음 요청으로 바뀌어도 카드 내용 구조가 같음 (제자리에서 글자만 바뀜)")
        }
        let changedAt = h.now
        let swapDelay = h.swapDelay
        cases += 1
        if swapDelay < 0.1 { problems.append("다음 요청으로 바뀔 때 이전 카드를 흐리지 않음 (교체 지연 \(swapDelay)초)") }
        h.now += 0.1
        expect("다음 요청으로 바뀌고 이전 카드가 흐려지는 중 허용 클릭", h, delivered: false) { h.presentation.resolve(second, decision: .allow) }
        h.finishSwap()
        h.now += 0.1
        expect("다음 요청 카드가 나타난 직후 허용 클릭", h, delivered: false) { h.presentation.resolve(second, decision: .allow) }
        expect("바뀐 직후 이전 요청 버튼", h, delivered: false) { h.presentation.resolve(first, decision: .allow) }
        // 요청이 바뀐 지는 대기 시간(0.5초)이 지났지만 새 카드가 나타난 지는 그보다 짧다 → 아직 받지 않는다
        // (예전처럼 모드가 바뀐 때부터 재면 내용 교체 지연만큼 막는 시간이 줄었다)
        let late = PresentationController.shortcutSettleDelay + 0.05
        h.now = changedAt + late
        expect(String(format: "요청이 바뀐 지 %.2f초 · 카드가 나타난 지 %.2f초 허용 클릭", late, late - swapDelay), h, delivered: false) {
            h.presentation.resolve(second, decision: .allow)
        }

        // 열린 메뉴에 가렸다가 다시 보이면 처음부터 다시 잰다
        h.now += 0.5
        h.presentation.setOccluded([h.screenID])
        cases += 1
        if h.shown() != nil { problems.append("메뉴에 가린 동안에도 카드가 보임") }
        h.now += 0.1
        h.presentation.setOccluded([])
        _ = h.shown()
        h.now += 0.1
        expect("가렸다 다시 보인 직후 허용 클릭", h, delivered: false) { h.presentation.resolve(second, decision: .allow) }
        h.now += 0.5
        expect("다시 보이고 0.6초 뒤 허용 클릭", h, delivered: true) { h.presentation.resolve(second, decision: .allow) }

        // 거부는 바로 받는다
        h.apiServerAsks("git push --force", at: 850)
        guard let third = h.shown() else { return (cases + 1, problems + ["세 번째 권한 요청 카드가 안 보임"]) }
        expect("요청 직후 거부 클릭", h, delivered: true) { h.presentation.resolve(third, decision: .deny(message: nil)) }

        // 계획 승인
        h.world.blogAsksPlanApproval()
        guard let plan = h.shown(), case .plan = plan.kind else { return (cases + 1, problems + ["계획 승인 카드가 안 보임"]) }
        h.now += 0.1
        expect("계획이 보인 직후 승인 클릭", h, delivered: false) { h.presentation.approvePlan(plan) }
        h.now += 0.5
        expect("계획 0.6초 뒤 승인 클릭", h, delivered: true) { h.presentation.approvePlan(plan) }

        // 질문: 막 보인 질문은 선택지를 골라도 보내지 않고, 보내기도 막는다
        q.world.blogAsksInNotch([SnapshotWorld.deployImageQuestion])
        guard let question = q.shown(), case .question = question.kind else { return (cases + 1, problems + ["질문 카드가 안 보임"]) }
        q.now += 0.1
        expect("질문이 보인 직후 선택지 클릭", q, delivered: false) { q.presentation.pickOption(0, in: question) }
        expect("질문이 보인 직후 보내기", q, delivered: false) { q.presentation.advanceOrSubmit(question) }
        q.now += 0.5
        expect("질문 0.6초 뒤 보내기", q, delivered: true) { q.presentation.advanceOrSubmit(question) }
        return (cases, problems)
    }

    /// 내용 교체 순서 검사용 권한 요청 (예시 명령)
    static func request(_ command: String) -> PermissionRequestInfo {
        PermissionRequestInfo(
            id: UUID(), sessionID: SnapshotWorld.apiServer.id, toolName: "Bash", title: "Bash 실행 요청", detail: command,
            toolInput: .object(["command": .string(command)]), suggestions: nil, receivedAt: SnapshotClock.base
        )
    }
}

// MARK: - 배치 이력

/// 숨겼다가 여는 카드 · 화면이 빠졌다 돌아온 뒤의 접힌 상태가 예전 배치 이력(부분 1 · 카드 띠)을 쓰지 않는지.
/// 이력이 없는 새 표시 상태로 계산한 레이아웃과 같아야 한다
@MainActor
enum SnapshotLayoutHistoryCheck {
    static func run() -> (cases: Int, problems: [String]) {
        var problems: [String] = []
        var cases = 0
        do {
            try hiddenToCard(&cases, &problems)
            try screenReturns(&cases, &problems)
        } catch {
            problems.append("장면 준비 실패: \(error.localizedDescription)")
        }
        return (cases, problems)
    }

    /// 같은 스토어 · 설정 · 화면으로 이력 없이 계산한 레이아웃
    private static func fresh(_ setup: SnapshotSetup, fullscreen: Set<ScreenID> = []) -> IslandLayout {
        let presentation = PresentationController(store: setup.world.store, preferences: setup.presentation.preferences, actions: SnapshotActions())
        presentation.updateScreens([setup.bar.geometry])
        presentation.setActiveScreen(setup.screenID)
        presentation.setSpaces([setup.screenID: setup.bar.space])
        presentation.setFullscreenScreens(fullscreen)
        return presentation.layout(for: setup.screenID, mode: presentation.mode(for: setup.screenID))
    }

    private static func describe(_ layout: IslandLayout) -> String {
        let p = layout.shape.part1.rect
        return String(format: "부분 1 %.0f×%.0f · 카드 %.0f×%.0f", p.width, p.height, layout.size.width, layout.size.height)
    }

    private static func same(_ a: IslandLayout, _ b: IslandLayout) -> Bool {
        let pa = a.shape.part1.rect
        let pb = b.shape.part1.rect
        return abs(pa.minX - pb.minX) < 0.5 && abs(pa.width - pb.width) < 0.5 && abs(pa.height - pb.height) < 0.5
            && abs(a.size.width - b.size.width) < 0.5 && abs(a.size.height - b.size.height) < 0.5
            && abs(a.origin.x - b.origin.x) < 0.5
    }

    /// 두 줄 띠(노치 아래 띠 + 백그라운드 배지)를 그린 뒤 풀스크린("알림만")으로 숨김 → 숨긴 동안 그 세션을 닫고
    /// 다른 세션의 권한 요청 카드: 카드 부분 1 은 숨기기 전 두 줄 띠가 아니라 지금 접힌 내용의 (한 줄) 띠다
    private static func hiddenToCard(_ cases: inout Int, _ problems: inout [String]) throws {
        let setup = try SnapshotStage.prepare(.workingBackgroundStrip, style: .notch)
        let id = setup.screenID
        let before = setup.draw()
        cases += 1
        guard before.hasTwoLineStrip else {
            problems.append("숨김 → 카드: 숨기기 전 접힌 상태가 두 줄 띠가 아님 (검사 장면이 맞지 않음)")
            return
        }
        setup.presentation.setFullscreenScreens([id])
        cases += 1
        guard setup.mode == .hidden else {
            problems.append("숨김 → 카드: 풀스크린 \"알림만\" 에서 접힌 상태가 숨지 않음")
            return
        }
        // 숨긴 상태를 커밋한다 (접힌 모양 이력을 지움)
        setup.draw()
        var world = setup.world
        world.store.dismiss(sessionID: SnapshotWorld.apiServer.id)
        world.webAppAsksPermission()
        let card = setup.draw()
        let expected = fresh(setup, fullscreen: [id])
        cases += 1
        guard case .permission = setup.mode, expected.compact == nil else {
            problems.append("숨김 → 카드: 권한 카드가 안 열림")
            return
        }
        if abs(expected.shape.part1.rect.height - before.shape.part1.rect.height) < 0.5 {
            problems.append("숨김 → 카드: 지금 내용의 띠도 숨기기 전과 같은 높이 (검사 장면이 맞지 않음)")
        }
        cases += 1
        if !same(card, expected) {
            problems.append("숨김 → 카드: \(describe(card)) (숨기기 전 \(describe(before)), 지금 내용 \(describe(expected)))")
        }
    }

    /// 카드를 연 채 화면이 빠졌다가(덮개 닫기 등) 같은 ScreenID 로 돌아와 접힌 상태가 되면 예전 카드 띠를 붙잡지 않는다.
    /// 실제 앱처럼 화면 구성이 바뀔 때마다 관찰 패스를 돌린다 (사라진 화면 이력은 커밋이 지운다)
    private static func screenReturns(_ cases: inout Int, _ problems: inout [String]) throws {
        func cardThenResolve() throws -> SnapshotSetup {
            let setup = try SnapshotStage.prepare(.permission, style: .notch, environment: .working)
            setup.draw()
            if let request = setup.world.store.pendingPermissions.first {
                setup.world.store.resolvePermission(id: request.id, decision: .allow)
            }
            setup.presentation.handleLatestSignal()
            return setup
        }
        // 화면이 그대로면 접히는 동안 카드 띠를 붙잡는다 (이 장면에서 붙잡은 모양이 새 접힌 모양과 달라야 검사가 뜻이 있다)
        let kept = try cardThenResolve()
        let held = kept.draw()
        let removed = try cardThenResolve()
        removed.presentation.updateScreens([])
        removed.presentation.commitScreens()
        removed.presentation.updateScreens([removed.bar.geometry])
        removed.presentation.setActiveScreen(removed.screenID)
        let returned = removed.draw()
        let expected = fresh(removed)
        cases += 1
        if same(held, expected) {
            problems.append("화면 재연결: 붙잡은 카드 띠가 새 접힌 모양과 같음 (검사 장면이 맞지 않음)")
        }
        cases += 1
        if !same(returned, expected) || returned.compact != expected.compact {
            problems.append("화면 재연결: 돌아온 화면이 예전 카드 띠를 붙잡음 (\(describe(returned)), 새 접힌 모양 \(describe(expected)))")
        }
    }
}

// MARK: - 클릭 모양 · 키 · 메뉴바 측정

@MainActor
enum SnapshotInputCheck {
    static func run() -> (cases: Int, problems: [String]) {
        var problems: [String] = []
        var cases = 0
        hitShape(&cases, &problems)
        digits(&cases, &problems)
        statusStart(&cases, &problems)
        return (cases, problems)
    }

    /// 클릭 모양이 레이아웃 클릭 영역(점 둘레 20×20)까지 받는지 (`ScreenManager` 의 클릭 판정과 같게)
    private static func hitShape(_ cases: inout Int, _ problems: inout [String]) {
        func path(_ setup: SnapshotSetup) -> (layout: IslandLayout, hit: Path, drawn: Path) {
            let layout = setup.layout
            let geometry = setup.bar.geometry
            let rect = CGRect(origin: .zero, size: geometry.panelFrame.size)
            let shape = IslandPanelShape(spec: layout.shapeSpec)
            return (layout, IslandHitShape(layout: layout, shape: shape).path(in: rect), shape.path(in: rect))
        }
        guard let dot = try? SnapshotStage.prepare(.menubarDot, style: .menuBar) else {
            problems.append("클릭 모양: 장면 준비 실패")
            return
        }
        let d = path(dot)
        cases += 1
        if case .dot? = d.layout.compact {
            let center = CGPoint(x: d.layout.panelRect.midX, y: d.layout.panelRect.midY)
            let ring = CGPoint(x: center.x + 8, y: center.y + 1)
            let outside = CGPoint(x: center.x + 12, y: center.y)
            if d.drawn.contains(ring) { problems.append("클릭 모양: 점 둘레 검사 자리가 점 안 (검사 장면이 맞지 않음)") }
            if !d.hit.contains(center) || !d.hit.contains(ring) { problems.append("클릭 모양: 점 둘레 클릭 영역을 받지 않음") }
            if d.hit.contains(outside) { problems.append("클릭 모양: 점 클릭 영역 밖도 받음") }
        } else {
            problems.append("클릭 모양: menubar-dot 장면이 점이 아님")
        }
    }

    /// 질문 선택지 숫자 키: 입력된 숫자(⇧ 포함) → 위 줄 · 키패드 자리 (수식키 없을 때만)
    private static func digits(_ cases: inout Int, _ problems: inout [String]) {
        let samples: [(name: String, characters: String?, keyCode: UInt16, flags: NSEvent.ModifierFlags, expected: Int?)] = [
            ("US 1", "1", 18, [], 0),
            ("US ⇧1 (!)", "!", 18, [.shift], nil),
            ("AZERTY & (1 자리)", "&", 18, [], 0),
            ("AZERTY ⇧& (1)", "1", 18, [.shift], 0),
            ("AZERTY ⇧é (2)", "2", 19, [.shift], 1),
            ("키패드 4", "4", 86, [], 3),
            ("5", "5", 23, [], nil),
            ("⌘1", "1", 18, [.command], nil),
            ("⌥1", "¡", 18, [.option], nil),
            ("죽은 키 (글자 없음)", "", 20, [], 2),
        ]
        for sample in samples {
            cases += 1
            let got = ScreenManager.optionDigit(characters: sample.characters, keyCode: sample.keyCode, flags: sample.flags)
            if got != sample.expected {
                problems.append("숫자 키 \(sample.name): \(got.map { "\($0 + 1)번" } ?? "없음") (기대 \(sample.expected.map { "\($0 + 1)번" } ?? "없음"))")
            }
        }
    }

    /// 창 목록의 상태 아이템 창으로 상태 아이템 시작을 잰다 (화면 왼쪽 기준). 창 목록에 없으면(macOS 27) 못 잰 것으로 둔다
    private static func statusStart(_ cases: inout Int, _ problems: inout [String]) {
        // 주 화면 오른쪽에 둔 1920pt 외부 모니터 (Cocoa 전역)
        let screen = MenuBarScanner.Screen(id: 7, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), fallbackMenuBarHeight: 24)
        let samples: [(name: String, statusMinX: CGFloat?, expected: CGFloat?)] = [
            ("상태 아이템 창 있음", 1512 + 1500, 1500),
            ("상태 아이템 창 없음 (macOS 27)", nil, nil),
        ]
        for sample in samples {
            cases += 1
            let scan = [screen.id: MenuBarScanner.Result(menuBarHeight: 24, statusMinX: sample.statusMinX)]
            let space = MenuBarSpaceBuilder.build(screens: [screen], scan: scan, reportsMenuBar: [:])[screen.id]
            let got = space?.statusMeasured == true ? space?.statusStart : nil
            let matches: Bool
            switch (got, sample.expected) {
            case (nil, nil): matches = true
            case let (value?, want?): matches = abs(value - want) <= 0.5
            default: matches = false
            }
            if !matches {
                problems.append(String(
                    format: "상태 아이템 시작 %@: %@ (기대 %@)", sample.name,
                    got.map { String(format: "%.0f", $0) } ?? "못 잼", sample.expected.map { String(format: "%.0f", $0) } ?? "못 잼"
                ))
            }
        }
        // 1~2pt 흔들림은 이전 값 그대로, 그보다 크면 새 값
        cases += 1
        let measured = MenuBarSpace(menuBarVisible: true, menuBarHeight: 24, statusStart: 1500, statusMeasured: true)
        func moved(_ x: CGFloat) -> CGFloat? {
            var next = measured
            next.statusStart = x
            return MenuBarSpaceBuilder.stabilized([screen.id: next], previous: [screen.id: measured])[screen.id]?.statusStart
        }
        if moved(1501.5) != 1500 || moved(1504) != 1504 {
            problems.append("상태 아이템 시작 흔들림 거르기가 다름 (1.5pt → \(String(describing: moved(1501.5))), 4pt → \(String(describing: moved(1504))))")
        }
    }
}
