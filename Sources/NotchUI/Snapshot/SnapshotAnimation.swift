import AppKit
import SwiftUI
import NotchCore

// 전환 애니메이션 시트 (`--render-island anim-<전>-<후>`).
// 실제 패널과 같은 스프링 곡선으로 프레임을 골라 한 장에 늘어놓고, 프레임마다 모양 검사 결과를 stdout 에 찍는다.
// - 검은 모양: IslandContainer 처럼 크기 · 위치 · IslandShapeSpec 을 같은 스프링 값으로 보간해 IslandShape 로 그린다
// - 내용: 실제 패널의 IslandViewState 를 같은 순서로 돌린다 (내용 구조가 바뀌면 이전 내용이 제자리에서 0.1s 흐려짐 →
//   contentDelay(종류 변화) · branchContentDelay(같은 종류에서 표시 방식 변화) 뒤 새 내용(최종 배치) 0.18s 나타남,
//   IslandContainer.beginContentSwap)

// MARK: - 전환 정의

/// 두 장면 사이 전환 (`anim-<전>-<후>`)
@MainActor
struct SnapshotTransition {
    let name: String
    let from: SnapshotScenario
    let to: SnapshotScenario
    /// 메뉴바 배치 · 외부 모니터 표시 방식을 가져올 장면 (두 상태가 같은 화면이어야 하므로 하나로 맞춘다)
    let environment: SnapshotScenario
    /// `from` 카드를 접은 직후(카드 띠를 붙잡은 `to` 접힌 상태) → 띠를 놓은 `to` 접힌 상태 (접힌 뒤 띠가 바뀌는 단계)
    var afterCollapse = false
    /// 한 표시 상태로 이어서 계산하는 전환 (`SnapshotSequence`, `environment` 화면). 있으면 `from` · `to` 는 쓰지 않는다
    var sequence: (sequence: SnapshotSequence, phase: SnapshotSequence.Phase)?
    /// 화면 종류를 고정한다 (nil 이면 `--style` 대로)
    var style: IslandSnapshotRenderer.Style?

    static func named(_ name: String) -> SnapshotTransition? {
        all.first { $0.name == name }
    }

    static var all: [SnapshotTransition] {
        func t(
            _ from: SnapshotScenario,
            _ to: SnapshotScenario,
            env: SnapshotScenario? = nil,
            name: String? = nil
        ) -> SnapshotTransition {
            SnapshotTransition(
                name: name ?? "anim-\(from.rawValue)-\(to.rawValue)",
                from: from,
                to: to,
                environment: env ?? from
            )
        }
        var list: [SnapshotTransition] = [
            // 기본 화면 (노치 양옆 넉넉함)
            t(.idle, .working, env: .working),
            t(.working, .peek),
            t(.peek, .working, env: .working),
            t(.working, .permission),
            t(.permission, .working, env: .working),
            // 노치에서 답하는 질문 · 계획 승인 카드 (권한 카드와 같은 카드 규칙)
            t(.working, .question),
            t(.question, .working, env: .working),
            t(.working, .questionPages),
            t(.working, .plan),
            t(.plan, .working, env: .working),
            t(.working, .expanded),
            t(.expanded, .working, env: .working),
            t(.working, .done),
            t(.done, .idle, env: .working),
            // 카드가 열려 있는 동안 접힌 내용이 바뀐 채 접힘 (다른 세션 요약이 생김 · 작업이 끝나 쉬는 중):
            // 접히는 동안 카드 띠를 붙잡고, 모양이 자리 잡은 뒤 띠를 놓는다 (`-release`)
            t(.permission, .workingSummary, env: .working),
            t(.permission, .idle, env: .working),
            t(.expanded, .idle, env: .working),
            // 메뉴바 알약 → 카드
            t(.menubarWorking, .menubarPermission, env: .menubarWorking),
            t(.menubarPermission, .menubarWorking, env: .menubarWorking),
            t(.menubarWorking, .menubarQuestion, env: .menubarWorking),
            t(.menubarQuestion, .menubarWorking, env: .menubarWorking),
            // 메뉴바 안 점 ↔ 카드 (빈 곳이 좁은 외부 모니터: 점이 부분 1)
            t(.menubarDot, .menubarPermission, env: .menubarDot),
            t(.menubarPermission, .menubarDot, env: .menubarDot),
            // 메뉴바 아래 알약 ↔ 카드 (외부 모니터 "메뉴바 아래" 방식)
            t(.menubarBelowWorking, .menubarBelowPermission, env: .menubarBelowWorking),
            t(.menubarBelowPermission, .menubarBelowWorking, env: .menubarBelowWorking),
            // 화면 가운데가 좁아 빈 곳 안으로 밀어 놓은 메뉴바 알약 ↔ 카드
            t(.menubarWorkingLongTool, .menubarPermission, env: .menubarWorkingLongTool),
            t(.menubarPermission, .menubarWorkingLongTool, env: .menubarWorkingLongTool),
            // 실제 사용 환경에 가까운 것: 노치 양옆이 앱 메뉴 · 상태 아이콘으로 꽉 참 (노치 아래 띠는 메뉴바를 가리지 않음)
            t(.workingSummaryStrip, .peek, env: .workingSummaryStrip, name: "anim-working-strip-peek"),
            t(.permissionCollapsed, .permission, env: .working),
        ]
        for (from, to) in [(SnapshotScenario.permission, SnapshotScenario.workingSummary), (.permission, .idle), (.expanded, .idle)] {
            var release = t(from, to, env: .working, name: "anim-\(from.rawValue)-\(to.rawValue)-release")
            release.afterCollapse = true
            list.append(release)
        }
        // 접힌 내용이 카드를 여는 순간 · 열린 동안 바뀌는 전환 (한 표시 상태로 이어서): 노치 아래 띠 ·
        // 메뉴바 알약 · 메뉴바 아래 알약 · 메뉴바 안 점
        for sequence in SnapshotSequence.all {
            for env in SnapshotSequence.environments {
                for phase in SnapshotSequence.Phase.allCases where phase != .change || sequence.during != nil {
                    var seq = t(env.scene, env.scene, env: env.scene, name: "anim-seq-\(sequence.name)-\(env.name)-\(phase.rawValue)")
                    seq.sequence = (sequence, phase)
                    seq.style = env.style
                    list.append(seq)
                }
            }
        }
        return list
    }
}

// MARK: - 이어서 계산하는 전환

/// 한 표시 상태(`PresentationController`)로 접힌 상태 → 카드 → 접힌 상태를 이어서 계산하는 전환.
/// 실제 앱처럼 접힌 내용이 카드를 여는 순간(완료 확인 · 권한 요청) · 열린 동안(다른 세션 · 보여주는 세션이 바뀜) 바뀐다.
/// 단계: open(접힌 상태 → 카드) · change(카드 → 접힌 내용이 바뀐 카드) · close(카드 → 붙잡은 접힌 상태) · release(붙잡은 띠를 놓음)
@MainActor
struct SnapshotSequence {
    enum Phase: String, CaseIterable {
        case open, change, close, release
    }

    typealias Step = @MainActor (inout SnapshotWorld, PresentationController, ScreenID) -> Void

    let name: String
    /// 카드를 열기 전 접힌 상태
    let before: Step
    /// 카드를 연다 (이때 접힌 내용이 바뀔 수 있다)
    let open: Step
    /// 카드가 열린 동안 접힌 내용이 바뀐다 (없으면 change 단계 없음)
    let during: Step?
    /// 카드를 접는다
    let close: Step

    /// 화면 (장면 · 이름 · 고정할 화면 종류). 노치 아래 띠는 노치 화면만
    /// (노치 없는 화면은 메뉴바 알약 `pill` · 메뉴바 아래 알약 `below` · 빈 곳이 좁은 메뉴바의 점 `dot` 으로 본다)
    static let environments: [(scene: SnapshotScenario, name: String, style: IslandSnapshotRenderer.Style?)] = [
        (.working, "strip", .notch), (.workingSummaryStrip, "strip-crowded", .notch),
        (.menubarWorking, "pill", .menuBar), (.menubarBelowWorking, "below", .menuBar), (.menubarDot, "dot", .menuBar),
    ]

    static var all: [SnapshotSequence] {
        let web = SnapshotWorld.webApp
        return [
            // 완료(미확인) 세션을 펼치면 확인 처리돼 접힌 내용이 쉬는 중 요약으로 바뀜
            SnapshotSequence(
                name: "seen",
                before: { world, _, _ in
                    world.apiServerEdits()
                    world.apiServerCompletes()
                },
                open: { _, presentation, id in presentation.toggleExpanded(on: id) },
                during: nil,
                close: { _, presentation, id in presentation.toggleExpanded(on: id) }
            ),
            // 쉬는 중 → 권한 요청 카드 (보여주는 세션 · 요약이 바뀜) → 열린 동안 다른 세션이 긴 명령 실행 → 허용하고 접음
            SnapshotSequence(
                name: "permission",
                before: { _, _, _ in },
                open: { world, presentation, _ in
                    world.webAppAsksPermission()
                    presentation.handleLatestSignal()
                },
                during: { world, _, _ in world.runsLongCommand(SnapshotWorld.apiServer, at: 850) },
                close: { world, presentation, _ in
                    if let request = world.store.pendingPermissions.first {
                        world.store.resolvePermission(id: request.id, decision: .allow)
                    }
                    presentation.handleLatestSignal()
                }
            ),
            // 작업 중 → 펼침 → 열린 동안 다른 세션이 긴 명령을 실행하고 그 세션을 고름 (보여주는 세션 · 툴 · 요약이 바뀜) → 접음
            SnapshotSequence(
                name: "focus",
                before: { world, _, _ in
                    world.startMoreSessions()
                    world.apiServerEdits()
                    world.apiServerRunsTests()
                },
                open: { _, presentation, id in presentation.toggleExpanded(on: id) },
                during: { world, _, _ in
                    world.runsLongCommand(web, at: 850)
                    world.store.focus(sessionID: web.id)
                },
                close: { _, presentation, id in presentation.toggleExpanded(on: id) }
            ),
        ]
    }

    /// 같은 단계들을 차례로 밟는 표시 상태. 단계마다 관찰 패스를 돌려(계산 · 커밋) 배치 이력을 남긴다
    @MainActor
    private struct Run {
        var setup: SnapshotSetup
        var world: SnapshotWorld
        var layout: IslandLayout

        var current: SnapshotSetup {
            SnapshotSetup(bar: setup.bar, presentation: setup.presentation, world: world, uptime: setup.uptime)
        }

        mutating func apply(_ step: Step, draw: Bool = true) {
            step(&world, setup.presentation, setup.screenID)
            if draw { layout = current.draw() }
        }
    }

    /// 단계 `count` 개(접힌 상태 · 열기 · 열린 동안 · 접기)를 밟고 그린 표시 상태
    private func run(steps count: Int, style: IslandSnapshotRenderer.Style, environment: SnapshotScenario) throws -> Run {
        let setup = try SnapshotStage.prepare(.idle, style: style, environment: environment)
        var run = Run(setup: setup, world: setup.world, layout: setup.draw())
        let steps: [Step] = [before, open, during ?? { _, _, _ in }, close]
        for step in steps.prefix(count) { run.apply(step) }
        return run
    }

    /// 전 상태(내용을 그릴 표시 상태) · 전 레이아웃 · 후 상태 (후 레이아웃은 시트가 계산한다)
    func prepare(
        _ phase: Phase,
        style: IslandSnapshotRenderer.Style,
        environment: SnapshotScenario
    ) throws -> (from: SnapshotSetup, fromLayout: IslandLayout, to: SnapshotSetup, note: String) {
        let index: Int
        let next: Step?
        switch phase {
        case .open: (index, next) = (1, open)
        case .change: (index, next) = (2, during)
        case .close: (index, next) = (3, close)
        case .release: (index, next) = (4, nil)
        }
        var main = try run(steps: index, style: style, environment: environment)
        let fromLayout = main.layout
        let note = "이어서 계산 · \(name) · \(phase.rawValue)"
        guard let next else {
            // 붙잡은 띠를 놓을 시각이 지난다 (접힌 상태 안의 변화)
            main.setup.uptime.advance(by: SnapshotAnimationSheet.collapseHoldElapsed)
            return (main.current, fromLayout, main.current, note)
        }
        // 전 내용은 같은 단계까지 밟은 다른 표시 상태로 그린다 (후 상태가 이어서 바뀌므로)
        let replica = try run(steps: index, style: style, environment: environment)
        main.apply(next, draw: false)
        return (replica.current, fromLayout, main.current, note)
    }
}

// MARK: - 곡선

/// SwiftUI `.spring(response:dampingFraction:)` 의 값 곡선 (0 → 1, 처음 속도 0).
/// 질량 1, 강성 (2π/response)², 감쇠비 dampingFraction 인 감쇠 조화 진동자의 해석해.
struct SnapshotSpringCurve {
    let name: String
    let response: Double
    let dampingFraction: Double

    /// 모드 종류가 바뀔 때 (IslandMotion.resize(reduceMotion: false))
    static let resize = SnapshotSpringCurve(
        name: "resize", response: IslandMotion.resizeResponse, dampingFraction: IslandMotion.resizeDamping
    )
    /// 같은 종류 안의 크기 변화 (IslandMotion.adjust)
    static let adjust = SnapshotSpringCurve(name: "adjust", response: IslandMotion.adjustResponse, dampingFraction: 1.0)

    var animation: Animation { .spring(response: response, dampingFraction: dampingFraction) }

    func value(at t: Double) -> Double {
        guard t > 0 else { return 0 }
        let w0 = 2 * Double.pi / response
        let z = dampingFraction
        if z < 1 {
            let wd = w0 * (1 - z * z).squareRoot()
            return 1 - exp(-z * w0 * t) * (cos(wd * t) + (z * w0 / wd) * sin(wd * t))
        }
        if z == 1 {
            return 1 - exp(-w0 * t) * (1 + w0 * t)
        }
        let s = (z * z - 1).squareRoot()
        let r1 = -w0 * (z - s)
        let r2 = -w0 * (z + s)
        let a = -r2 / (r2 - r1)
        let b = r1 / (r2 - r1)
        return 1 + a * exp(r1 * t) + b * exp(r2 * t)
    }

    /// 최대값 (값, 시각). 오버슈트가 없으면 (1, 1.2s)
    var peak: (value: Double, time: Double) {
        guard dampingFraction < 1 else { return (1, 1.2) }
        let w0 = 2 * Double.pi / response
        let wd = w0 * (1 - dampingFraction * dampingFraction).squareRoot()
        let time = Double.pi / wd
        return (value(at: time), time)
    }

    /// SwiftUI 의 Spring 모델과 비교 (최대 차이)
    func maxDifferenceFromSwiftUI() -> Double {
        let spring = Spring(response: response, dampingRatio: dampingFraction)
        var worst = 0.0
        for step in 0...200 {
            let t = Double(step) * 0.005
            let swiftUI = spring.value(target: 1.0, initialVelocity: 0.0, time: t)
            worst = max(worst, abs(swiftUI - value(at: t)))
        }
        return worst
    }
}

/// 전환 하나의 시간 축: 모양 스프링 + 내용 흐려짐/나타남
struct SnapshotTimeline {
    let spring: SnapshotSpringCurve
    /// 내용이 다시 나타나기 시작하는 시각 (IslandMotion.contentDelay)
    let swapMs: Double
    let fadeOutMs = 100.0
    let fadeInMs = 180.0

    /// 샘플 시각 (ms): 앞쪽은 60fps 로 촘촘히, 뒤쪽은 성기게 (24장)
    static let frameTimes: [Double] = [
        0, 17, 33, 50, 67, 83, 100, 117, 133, 150, 167, 183,
        200, 217, 233, 250, 283, 317, 350, 383, 417, 467, 517, 667,
    ]

    init(spring: SnapshotSpringCurve, swapDelay: Duration = IslandMotion.contentDelay) {
        self.spring = spring
        let delay = swapDelay.components
        swapMs = Double(delay.seconds) * 1000 + Double(delay.attoseconds) / 1e15
    }

    func value(ms: Double) -> Double { spring.value(at: ms / 1000) }

    /// 이전 내용 투명도 (easeOut 0.1s 로 1 → 0)
    func fadeOut(ms: Double) -> Double {
        1 - UnitCurve.easeOut.value(at: min(1, max(0, ms / fadeOutMs)))
    }

    /// 새 내용 투명도 (swap 뒤 easeOut 0.18s 로 0 → 1)
    func fadeIn(ms: Double) -> Double {
        guard ms >= swapMs else { return 0 }
        return UnitCurve.easeOut.value(at: min(1, (ms - swapMs) / fadeInMs))
    }

    /// 값 v 에 처음 닿는 시각 (ms, 최대값 전 구간)
    func time(forValue v: Double) -> Double {
        var lo = 0.0
        var hi = spring.peak.time * 1000
        guard v < spring.value(at: hi / 1000) else { return hi }
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if value(ms: mid) < v { lo = mid } else { hi = mid }
        }
        return hi
    }

    /// 실제 앱 설정과 다르면 경고 (Animation 은 값을 꺼낼 수 없어서 설명 문자열로 비교)
    static func syncWarnings() -> [String] {
        var warnings: [String] = []
        let pairs: [(String, Animation, SnapshotSpringCurve)] = [
            ("IslandMotion.resize", IslandMotion.resize(reduceMotion: false), .resize),
            ("IslandMotion.adjust", IslandMotion.adjust(reduceMotion: false), .adjust),
        ]
        for (name, live, curve) in pairs {
            if String(describing: live) != String(describing: curve.animation) {
                warnings.append("\(name) 와 시트 곡선이 다름: \(live) ≠ \(curve.animation)")
            }
            let diff = curve.maxDifferenceFromSwiftUI()
            if diff > 0.002 { warnings.append(String(format: "%@ 해석해와 SwiftUI Spring 값 차이 %.4f", name, diff)) }
        }
        if String(describing: IslandMotion.contentFadeOut) != String(describing: Animation.easeOut(duration: 0.1)) {
            warnings.append("내용 흐려짐이 IslandMotion.contentFadeOut 과 다름")
        }
        if String(describing: IslandMotion.contentFadeIn) != String(describing: Animation.easeOut(duration: 0.18)) {
            warnings.append("내용 나타남이 IslandMotion.contentFadeIn 과 다름")
        }
        return warnings
    }
}

// MARK: - 내용 교체 순서 검사

/// IslandViewState 를 실제 패널 순서(렌더 → onChange → 지연 뒤 교체 끝)대로 돌려
/// 여러 번 · 되돌아가는 전환 뒤에도 늘 지금 모드를 그리게 되는지 검사한다.
@MainActor
enum SnapshotContentSwapCheck {
    /// IslandContainer 를 흉내 낸 패널 하나 (애니메이션 · 타이머 없이 순서만)
    @MainActor
    private final class Panel {
        let state = IslandViewState()
        var mode: IslandMode
        var layout: IslandLayout
        var reduceMotion = false
        /// 예약된 교체 끝 (IslandContainer.swapTask)
        var pendingFinish = false

        init(_ mode: IslandMode, width: CGFloat, compact: CompactVariant? = nil) {
            self.mode = mode
            layout = SnapshotContentSwapCheck.layout(width, compact: compact)
            _ = render()
        }

        /// 렌더 한 번: 지금 그리는 (모드, 레이아웃 폭)
        @discardableResult
        func render() -> (kind: IslandMode.Kind, width: CGFloat) {
            let shown = state.outgoingContent(current: mode, layout: layout, reduceMotion: reduceMotion)
                ?? IslandShownContent(mode: mode, layout: layout)
            return (shown.mode.kind, shown.layout.size.width)
        }

        /// 모드를 바꾼다: 새 모드로 첫 렌더 → (내용 구조가 바뀌었으면) onChange
        func change(to next: IslandMode, width: CGFloat, compact: CompactVariant? = nil) -> (kind: IslandMode.Kind, width: CGFloat) {
            let before = IslandContentKey(mode: mode, layout: layout)
            mode = next
            layout = SnapshotContentSwapCheck.layout(width, compact: compact)
            let key = IslandContentKey(mode: mode, layout: layout)
            let first = render()
            if key != before {
                pendingFinish = false
                switch state.beginSwap(to: key, reduceMotion: reduceMotion) {
                case .none, .restore: state.contentVisible = true
                case .fadeOut:
                    state.contentVisible = false
                    pendingFinish = true
                }
            }
            return first
        }

        /// contentDelay 가 지났다
        func elapse() {
            guard pendingFinish else { return }
            pendingFinish = false
            state.finishSwap()
            state.contentVisible = true
        }
    }

    private static func layout(_ width: CGFloat, compact: CompactVariant? = nil) -> IslandLayout {
        IslandLayout(size: CGSize(width: width, height: 32), origin: .zero, shape: IslandShapeSpec(), compact: compact)
    }

    /// 문제 목록 (비면 통과)과 검사한 경우 수
    static func run() -> (cases: Int, problems: [String]) {
        var problems: [String] = []
        var cases = 0
        func expect(_ name: String, _ got: (kind: IslandMode.Kind, width: CGFloat), _ kind: IslandMode.Kind, _ width: CGFloat? = nil) {
            if got.kind != kind || (width.map { abs($0 - got.width) > 0.01 } ?? false) {
                problems.append("\(name): \(got.kind) 폭 \(Int(got.width)) 를 그림 (기대 \(kind)\(width.map { " 폭 \(Int($0))" } ?? ""))")
            }
        }
        func settled(_ name: String, _ panel: Panel) {
            cases += 1
            expect(name + " 끝", panel.render(), panel.mode.kind, panel.layout.size.width)
            expect(name + " 끝(다시)", panel.render(), panel.mode.kind, panel.layout.size.width)
            if !panel.state.contentVisible { problems.append("\(name): 끝난 뒤에도 내용이 흐린 채") }
            if panel.state.needsSwap(current: IslandContentKey(mode: panel.mode, layout: panel.layout)) {
                problems.append("\(name): 끝난 뒤에도 교체가 남음")
            }
        }

        // A → B: 첫 렌더 · onChange 뒤엔 이전 내용(이전 레이아웃), 교체 끝에 새 내용
        do {
            let panel = Panel(.working, width: 300)
            expect("A→B 첫 렌더", panel.change(to: .expanded, width: 620), .working, 300)
            expect("A→B 교체 중", panel.render(), .working, 300)
            if panel.state.contentVisible { problems.append("A→B: 교체 중인데 내용이 보임") }
            panel.elapse()
            settled("A→B", panel)
        }
        // A → B → (끝) → C: 두 번째 전환도 끝나야 한다 (교체 상태가 풀리지 않던 문제)
        do {
            let panel = Panel(.idle, width: 120)
            _ = panel.change(to: .working, width: 300)
            panel.elapse()
            settled("A→B", panel)
            expect("A→B→C 첫 렌더", panel.change(to: .expanded, width: 620), .working, 300)
            panel.elapse()
            settled("A→B→C", panel)
            expect("A→B→C→A 첫 렌더", panel.change(to: .idle, width: 120), .expanded, 620)
            panel.elapse()
            settled("A→B→C→A", panel)
        }
        // A → B → A (교체 끝 전): 원래 내용으로 바로 돌아온다
        do {
            let panel = Panel(.working, width: 300)
            _ = panel.change(to: .expanded, width: 620)
            expect("A→B→A 첫 렌더", panel.change(to: .working, width: 304), .working, 304)
            if panel.pendingFinish { problems.append("A→B→A: 교체 예약이 남음") }
            settled("A→B→A", panel)
        }
        // A → B → C (교체 끝 전): A 를 흐린 채 기다렸다가 C
        do {
            let panel = Panel(.working, width: 300)
            _ = panel.change(to: .expanded, width: 620)
            expect("A→B→C(빠름) 첫 렌더", panel.change(to: .idle, width: 120), .working, 300)
            panel.elapse()
            settled("A→B→C(빠름)", panel)
        }
        // 같은 종류 안의 변화: 교체 없이 바로 새 레이아웃
        do {
            let panel = Panel(.working, width: 300)
            expect("같은 종류", panel.change(to: .working, width: 320), .working, 320)
            settled("같은 종류", panel)
        }
        // 같은 종류 · 같은 표시 방식에서 폭만 바뀜: 교체 없이 바로 새 레이아웃
        do {
            let panel = Panel(.working, width: 300, compact: .pill(items: .all))
            expect("같은 표시 방식", panel.change(to: .working, width: 280, compact: .pill(items: .all)), .working, 280)
            if panel.pendingFinish { problems.append("같은 표시 방식: 교체 예약이 생김") }
            settled("같은 표시 방식", panel)
        }
        // 같은 종류에서 표시 방식만 바뀜 (메뉴바 빈 곳이 줄어 알약 → 점): 이전 내용이 흐려진 뒤 새 내용
        do {
            let panel = Panel(.working, width: 300, compact: .pill(items: .all))
            expect("알약→점 첫 렌더", panel.change(to: .working, width: 12, compact: .dot), .working, 300)
            expect("알약→점 교체 중", panel.render(), .working, 300)
            if panel.state.contentVisible { problems.append("알약→점: 교체 중인데 내용이 보임") }
            if panel.state.contentDelay(to: IslandContentKey(mode: panel.mode, layout: panel.layout)) != IslandMotion.branchContentDelay {
                problems.append("알약→점: 표시 방식 교체 지연이 branchContentDelay 가 아님")
            }
            panel.elapse()
            settled("알약→점", panel)
            // 교체 끝 전에 다시 알약으로: 원래 내용을 바로 보인다
            _ = panel.change(to: .working, width: 300, compact: .pill(items: .all))
            expect("점→알약→점 첫 렌더", panel.change(to: .working, width: 12, compact: .dot), .working, 12)
            settled("점→알약→점", panel)
        }
        // 카드에서 대기열의 다음 요청으로 바뀜: 이전 요청 카드가 흐려진 뒤 새 요청 카드 (대기 수만 바뀌면 그대로)
        do {
            let first = SnapshotDecisionCheck.request("ls")
            let second = SnapshotDecisionCheck.request("rm -rf build")
            let panel = Panel(.permission(first, queueCount: 2), width: 480)
            _ = panel.change(to: .permission(first, queueCount: 3), width: 480)
            if panel.pendingFinish { problems.append("같은 요청 대기 수 변화: 교체 예약이 생김") }
            _ = panel.change(to: .permission(second, queueCount: 2), width: 480)
            if panel.state.outgoing?.mode != .permission(first, queueCount: 3) { problems.append("다음 요청: 첫 렌더에 이전 요청 카드를 그리지 않음") }
            if panel.state.contentVisible || !panel.pendingFinish { problems.append("다음 요청: 이전 요청 카드를 흐리지 않음") }
            panel.elapse()
            settled("다음 요청", panel)
            if panel.state.outgoing != nil { problems.append("다음 요청: 교체가 끝난 뒤에도 이전 요청 카드가 남음") }
        }
        // 동작 줄이기: 교체 없이 바로 새 모드
        do {
            let panel = Panel(.working, width: 300)
            panel.reduceMotion = true
            expect("동작 줄이기", panel.change(to: .expanded, width: 620), .expanded, 620)
            settled("동작 줄이기", panel)
        }
        return (cases, problems)
    }
}

// MARK: - 호버 밝힘 순서 검사

/// IslandViewState 의 호버 밝힘 규칙을 실제 패널 순서(렌더 → onChange)대로 돌려 검사한다.
/// - 클릭으로 펼쳤다 같은 자리를 다시 눌러 접으면 접힌 아일랜드 위에 마우스가 있어도 다시 밝아지지 않아야 한다
/// - 모양이 자리 잡기 전(`settleDelay`)엔 밝히기 시작하지 않는다 (이미 밝으면 유지)
@MainActor
enum SnapshotHoverCheck {
    static func run() -> (cases: Int, problems: [String]) {
        var problems: [String] = []
        var cases = 0
        let state = IslandViewState()
        let compact = IslandContentKey(mode: .working, layout: IslandLayout(size: .zero, origin: .zero, shape: IslandShapeSpec(), compact: .strip(items: [])))
        let card = IslandContentKey(mode: .expanded, layout: IslandLayout(size: .zero, origin: .zero, shape: IslandShapeSpec(), compact: nil))
        func expect(_ name: String, wants: Bool, _ lit: Bool) {
            cases += 1
            if state.hoverHighlight(wants: wants) != lit { problems.append("\(name): 밝힘 \(lit ? "돼야" : "안 돼야") 하는데 반대") }
        }

        // 자리 잡은 접힌 아일랜드에 마우스를 올림 → 밝아짐
        expect("자리 잡은 뒤 호버", wants: true, true)
        // 클릭해서 펼침 (마우스는 위에 있음): 내용 교체 + 모양 변화 → 펼친 동안엔 밝히지 않음
        state.blockHover()
        _ = state.beginSwap(to: card, reduceMotion: false)
        state.layoutChanged()
        expect("펼친 카드", wants: false, false)
        state.finishSwap()
        state.markSettled()
        // 같은 자리를 다시 눌러 접음 → 교체가 끝난 뒤(220ms) 마우스가 접힌 아일랜드 위에 있어도 밝히지 않음
        state.blockHover()
        _ = state.beginSwap(to: compact, reduceMotion: false)
        state.layoutChanged()
        state.finishSwap()
        expect("접힌 직후 (자리 잡기 전)", wants: true, false)
        state.markSettled()
        expect("접히고 자리 잡은 뒤 (마우스가 그대로)", wants: true, false)
        // 마우스가 나갔다 들어오면 다시 밝아짐
        state.pointerLeft()
        expect("나간 동안", wants: false, false)
        expect("다시 들어옴", wants: true, true)
        // 밝은 동안 폭이 바뀌어도 유지 (어두워졌다 다시 밝아지지 않게)
        state.layoutChanged()
        expect("밝은 채 폭 변화", wants: true, true)
        // 모양이 바뀌는 중에 새로 들어오면 자리 잡은 뒤에 밝아짐
        state.pointerLeft()
        expect("나감", wants: false, false)
        state.layoutChanged()
        expect("모양 변화 중 들어옴", wants: true, false)
        state.markSettled()
        expect("자리 잡은 뒤", wants: true, true)
        return (cases, problems)
    }
}

// MARK: - 보간

enum SnapshotInterpolation {
    static func mix(_ a: CGFloat, _ b: CGFloat, _ v: Double) -> CGFloat { a + (b - a) * CGFloat(v) }

    static func mix(_ a: IslandShapeSpec, _ b: IslandShapeSpec, _ v: Double) -> IslandShapeSpec {
        var delta = b - a
        delta.scale(by: v)
        return a + delta
    }

    /// SwiftUI 가 레이아웃 변경 한 번에 같은 스프링으로 함께 보간하는 값: 프레임 크기 · 위치 · 모양.
    /// 숫자가 아닌 값(접힌 방식 등)은 후 상태 그대로.
    static func mix(_ a: IslandLayout, _ b: IslandLayout, _ v: Double) -> IslandLayout {
        var result = b
        result.size = CGSize(width: mix(a.size.width, b.size.width, v), height: mix(a.size.height, b.size.height, v))
        result.origin = CGPoint(x: mix(a.origin.x, b.origin.x, v), y: mix(a.origin.y, b.origin.y, v))
        result.shape = mix(a.shape, b.shape, v)
        result.cardWidth = mix(a.cardWidth, b.cardWidth, v)
        result.header = HeaderSlot(
            top: mix(a.header.top, b.header.top, v),
            height: mix(a.header.height, b.header.height, v),
            leftInset: mix(a.header.leftInset, b.header.leftInset, v),
            rightInset: mix(a.header.rightInset, b.header.rightInset, v)
        )
        return result
    }
}

// MARK: - 모양 검사

/// 프레임 하나의 검사
enum SnapshotShapeCheck {
    struct Context {
        let geometry: NotchGeometry
        let from: IslandLayout
        let to: IslandLayout
        /// 가짜 메뉴바에 그린 글자 · 아이콘 자리 (패널 기준). 전 · 후 상태에서 보이던 것은 중간에도 가려지면 안 된다
        var glyphs: [(name: String, rect: CGRect)] = []
    }

    /// 메뉴바 글자 · 아이콘 자리 (가짜 메뉴바와 같은 배치)
    @MainActor
    static func glyphs(of bar: SnapshotMenuBar) -> [(name: String, rect: CGRect)] {
        let height = bar.geometry.menuBarHeight
        var result: [(String, CGRect)] = []
        let icon = SnapshotMenuBar.iconSize
        for x in bar.statusIconXs {
            result.append((String(format: "아이콘 %.0f", x), CGRect(x: x, y: (height - icon.height) / 2, width: icon.width, height: icon.height)))
        }
        for item in bar.menuItems {
            let width = SnapshotMenuBar.textWidth(item.text, bold: item.bold)
            result.append(("메뉴 " + item.text, CGRect(x: item.x, y: (height - 13) / 2, width: width, height: 13)))
        }
        return result
    }

    /// 검은 모양이 사각형 안의 점을 하나라도 덮는지
    static func covers(_ layout: IslandLayout, _ rect: CGRect) -> Bool {
        let filled = IslandShape(spec: layout.shapeSpec).path(in: CGRect(origin: .zero, size: layout.size))
        let inner = rect.insetBy(dx: 1, dy: 1)
        for fx in [0.0, 0.25, 0.5, 0.75, 1.0] {
            for fy in [0.0, 0.5, 1.0] {
                let point = CGPoint(
                    x: inner.minX + inner.width * fx - layout.origin.x,
                    y: inner.minY + inner.height * fy - layout.origin.y
                )
                if filled.contains(point) { return true }
            }
        }
        return false
    }

    /// 주 외곽선 (목 + 몸통 = 부분 2. 접힌 상태에서는 그리지 않지만 펼치고 접는 전환의 끝값)
    static func outline(_ layout: IslandLayout) -> IslandOutline {
        IslandShape.outline(layout.shapeSpec, in: CGRect(origin: .zero, size: layout.size))
    }

    /// 접힌 상태(부분 1 만 그림)인지
    static func drawsPart1Only(_ layout: IslandLayout) -> Bool {
        if case .part1 = IslandShape.drawn(layout.shapeSpec, in: CGRect(origin: .zero, size: layout.size)) { return true }
        return false
    }

    /// 실제로 그리는 외곽선: 접힌 상태면 부분 1, 아니면 주 외곽선 (부분 1 은 그대로 합쳐 그린다)
    static func drawnOutline(_ layout: IslandLayout) -> IslandOutline {
        switch IslandShape.drawn(layout.shapeSpec, in: CGRect(origin: .zero, size: layout.size)) {
        case let .part1(o), let .main(o): return o
        case let .union(main, _): return main
        }
    }

    /// 그리는 모양 전체의 가로 범위 (부분 1 을 합쳐 그리면 둘 다)
    static func drawnExtent(_ layout: IslandLayout) -> (minX: CGFloat, maxX: CGFloat) {
        let outlines = IslandShape.drawn(layout.shapeSpec, in: CGRect(origin: .zero, size: layout.size)).outlines.filter { !$0.isEmpty }
        return (outlines.map(\.minX).min() ?? 0, outlines.map(\.maxX).max() ?? 0)
    }

    static func check(layout: IslandLayout, context: Context) -> [String] {
        var issues: [String] = []
        let size = layout.size
        let rect = CGRect(origin: .zero, size: size)
        let spec = layout.shape
        // 접힌 상태끼리 바뀌는 중(부분 1 만 그림)이면 부분 1 끼리, 아니면 주 외곽선끼리 비교한다
        let part1Only = drawsPart1Only(layout) && drawsPart1Only(context.from) && drawsPart1Only(context.to)
        let pick: (IslandLayout) -> IslandOutline = { part1Only ? drawnOutline($0) : outline($0) }
        let o = pick(layout)

        if size.width <= 1 || size.height <= 1 { issues.append("크기 0 → 모양 사라짐") }
        if o.isEmpty { issues.append("목 폭 ≤ 1 → 모양 사라짐") }

        // 음수 값 (목표를 크게 지나쳐 0 아래로 내려감 → IslandShape 가 0 으로 자름).
        // 거의 오버슈트 없는 스프링이 지나치는 만큼(변화량의 0.3%)은 정상
        let fields: [(String, KeyPath<IslandShapeSpec, CGFloat>)] = [
            ("neckLeft", \.neckLeft), ("neckRight", \.neckRight), ("neckHeight", \.neckHeight),
            ("bodyLeft", \.bodyLeft), ("bodyRight", \.bodyRight),
            ("topRadius", \.topRadius), ("bodyTopRadius", \.bodyTopRadius), ("shoulderRadius", \.shoulderRadius),
            ("bottomRadius", \.bottomRadius),
        ]
        for (name, field) in fields {
            let value = spec[keyPath: field]
            let delta = abs(context.to.shape[keyPath: field] - context.from.shape[keyPath: field])
            if value < -(0.3 + delta * 0.003) { issues.append(String(format: "%@ 음수 %.1f", name, value)) }
        }

        // 양 끝 상태에 없는 모양: 보이는 반경 · 턱이 두 끝값 범위를 벗어남
        let a = pick(context.from)
        let b = pick(context.to)
        func outside(_ name: String, _ value: CGFloat, _ x: CGFloat, _ y: CGFloat) {
            // 스프링이 목표를 살짝 지나치는 만큼(0.2%)과 반올림은 정상
            let tolerance = 0.75 + abs(x - y) * 0.003
            if value < min(x, y) - tolerance || value > max(x, y) + tolerance {
                issues.append(String(format: "%@ %.1f (양 끝 %.1f…%.1f 밖)", name, value, min(x, y), max(x, y)))
            }
        }
        outside("아래반경", o.bottomR, a.bottomR, b.bottomR)
        outside("위반경L", o.topRL, a.topRL, b.topRL)
        outside("위반경R", o.topRR, a.topRR, b.topRR)
        // 목 → 몸통 계단은 쪽마다 양 끝값 사이에서만 움직여야 한다 (좁은 몸통 → 넓은 몸통이면 0 을 한 번 지난다)
        outside("몸통 턱L", o.widenL, a.widenL, b.widenL)
        outside("몸통 턱R", o.widenR, a.widenR, b.widenR)

        // 실제 경로 검사
        let path = IslandShape(spec: layout.shapeSpec).path(in: rect)
        issues.append(contentsOf: pathCheck(path, rect: rect, expected: o, extent: drawnExtent(layout)))

        // 하드웨어 노치를 덮는지
        if context.geometry.hasNotch {
            let notchWidth = context.geometry.notchSize.width
            let notch = CGRect(
                x: (context.geometry.frame.width - notchWidth) / 2, y: 0,
                width: notchWidth, height: context.geometry.notchSize.height
            )
            let neckMinX = layout.origin.x + o.nx0
            let neckMaxX = layout.origin.x + o.nx1
            if neckMinX > notch.minX + 0.25 { issues.append(String(format: "노치 왼쪽 %.1fpt 드러남", neckMinX - notch.minX)) }
            if neckMaxX < notch.maxX - 0.25 { issues.append(String(format: "노치 오른쪽 %.1fpt 드러남", notch.maxX - neckMaxX)) }
            if layout.origin.y > 0.25 { issues.append(String(format: "화면 맨 위에서 %.1fpt 떨어짐", layout.origin.y)) }
            if layout.origin.y + o.bottom < notch.maxY - 0.25 {
                issues.append(String(format: "노치가 아래로 %.1fpt 삐져나옴", notch.maxY - layout.origin.y - o.bottom))
            }
        }

        // 전 · 후 상태에서 보이던 메뉴바 글자 · 아이콘이 중간 프레임에서 가려지는지
        for glyph in context.glyphs where covers(layout, glyph.rect) {
            if !covers(context.from, glyph.rect), !covers(context.to, glyph.rect) {
                issues.append("\(glyph.name) 전환 중에만 가려짐")
            }
        }
        return issues
    }

    /// 경로 경계 · 하위 경로(주 외곽선 · 부분 1)마다 자기 교차.
    /// 모양이 여러 조각으로 보이는지는 칠한 래스터로 본다 (`SnapshotSeamCheck.rasterIssues`: 주 외곽선과 부분 1 은 하위 경로 둘이라
    /// 경로 조각 수로는 알 수 없다)
    static func pathCheck(_ path: Path, rect: CGRect, expected: IslandOutline, extent range: (minX: CGFloat, maxX: CGFloat)) -> [String] {
        var issues: [String] = []
        if path.isEmpty {
            if !expected.isEmpty { issues.append("빈 경로") }
            return issues
        }
        let polygons = flatten(path)
        let bounds = path.boundingRect
        if bounds.minX < rect.minX - 0.5 || bounds.maxX > rect.maxX + 0.5 || bounds.minY < rect.minY - 0.5 || bounds.maxY > rect.maxY + 0.5 {
            // 노치 보호로 프레임 밖까지 그리는 것은 0.5pt 이내만 정상
            issues.append(String(format: "경로가 프레임 밖 (%.1f,%.1f %.1f×%.1f)", bounds.minX, bounds.minY, bounds.width, bounds.height))
        }
        if abs(bounds.minX - range.minX) > 1 || abs(bounds.maxX - range.maxX) > 1 {
            issues.append(String(format: "경로 가로 범위가 치수와 다름 (경로 x %.1f…%.1f, 예상 %.1f…%.1f)", bounds.minX, bounds.maxX, range.minX, range.maxX))
        }
        for polygon in polygons {
            if let point = selfIntersection(polygon) {
                issues.append(String(format: "자기 교차 (%.1f, %.1f)", point.x, point.y))
            }
        }
        return issues
    }

    /// 스프링 값 0 → 최대값을 촘촘히 훑어 칠한 모양이 여러 조각으로 갈라지는 구간 (이어진 구간 하나로 보고).
    /// 주 외곽선과 부분 1 을 함께 그리는 순간만 본다: 둘은 각각 닫힌 경로 하나라, 갈라진다면 서로 떨어진 것이다.
    /// 둘이 만나는 위쪽 띠(부분 1 · 목 아래끝 + 4pt)만 1배로 칠해(스프링 값 0.001 간격) 칠한 픽셀(절반 이상)이 이어진 덩어리를 센다
    /// (목이 띠 안에 있어 띠 안의 주 외곽선은 한 덩어리다)
    static func denseFragments(from: IslandLayout, to: IslandLayout, maxValue: Double, timeline: SnapshotTimeline) -> [String] {
        let step = 0.001
        var reports: [String] = []
        var run: (start: Double, last: Double, count: Int)?
        func close() {
            guard let open = run else { return }
            let ms0 = timeline.time(forValue: min(open.start, 1))
            let ms1 = timeline.time(forValue: min(open.last, 1))
            reports.append(String(format: "v %.4f…%.4f (≈%.0f…%.0fms) 모양 조각 %d개", open.start, open.last, ms0, ms1, open.count))
            run = nil
        }
        var v = 0.0
        while v <= maxValue + step / 2 {
            let layout = SnapshotInterpolation.mix(from, to, v)
            let frame = CGRect(origin: .zero, size: layout.size)
            var count = 1
            if case let .union(main, part1) = IslandShape.drawn(layout.shapeSpec, in: frame) {
                let band = min(layout.size.height, max(part1.bottom, main.neckBottom) + 4)
                let path = IslandShape(spec: layout.shapeSpec).path(in: frame)
                if let raster = SnapshotSeamCheck.rasterize(path, size: CGSize(width: layout.size.width, height: band), scale: 1) {
                    count = raster.componentCount
                }
            }
            if count > 1 {
                if run == nil { run = (v, v, count) } else { run?.last = v }
            } else {
                close()
            }
            v += step
        }
        close()
        return reports
    }

    /// 2차 베지어 곡선 위의 점. 식을 한 줄로 쓰면 예전 Swift(6.1)가 타입 추론 시간 초과로 빌드를 멈춰서 항마다 나눈다
    private static func quadPoint(_ start: CGPoint, _ control: CGPoint, _ end: CGPoint, t: CGFloat) -> CGPoint {
        let u: CGFloat = 1 - t
        let w0: CGFloat = u * u
        let w1: CGFloat = 2 * u * t
        let w2: CGFloat = t * t
        let x: CGFloat = w0 * start.x + w1 * control.x + w2 * end.x
        let y: CGFloat = w0 * start.y + w1 * control.y + w2 * end.y
        return CGPoint(x: x, y: y)
    }

    /// 3차 베지어 곡선 위의 점 (`quadPoint` 처럼 항마다 나눈다)
    private static func cubicPoint(_ start: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ end: CGPoint, t: CGFloat) -> CGPoint {
        let u: CGFloat = 1 - t
        let w0: CGFloat = u * u * u
        let w1: CGFloat = 3 * u * u * t
        let w2: CGFloat = 3 * u * t * t
        let w3: CGFloat = t * t * t
        let x: CGFloat = w0 * start.x + w1 * c1.x + w2 * c2.x + w3 * end.x
        let y: CGFloat = w0 * start.y + w1 * c1.y + w2 * c2.y + w3 * end.y
        return CGPoint(x: x, y: y)
    }

    /// 경로를 꺾은선으로 (곡선은 잘게 나눈다). 하위 경로마다 하나
    static func flatten(_ path: Path) -> [[CGPoint]] {
        var polygons: [[CGPoint]] = []
        var current: [CGPoint] = []
        var last = CGPoint.zero
        path.forEach { element in
            switch element {
            case let .move(to: point):
                if current.count > 2 { polygons.append(current) }
                current = [point]
                last = point
            case let .line(to: point):
                current.append(point)
                last = point
            case let .quadCurve(to: point, control: control):
                for step in 1...10 {
                    current.append(quadPoint(last, control, point, t: CGFloat(step) / 10))
                }
                last = point
            case let .curve(to: point, control1: c1, control2: c2):
                for step in 1...12 {
                    current.append(cubicPoint(last, c1, c2, point, t: CGFloat(step) / 12))
                }
                last = point
            case .closeSubpath:
                if current.count > 2 { polygons.append(current) }
                current = []
            }
        }
        if current.count > 2 { polygons.append(current) }
        // 길이 0 인 변 제거
        return polygons.map { polygon in
            var cleaned: [CGPoint] = []
            for point in polygon where cleaned.last.map({ hypot($0.x - point.x, $0.y - point.y) > 0.01 }) ?? true {
                cleaned.append(point)
            }
            if let first = cleaned.first, let lastPoint = cleaned.last, hypot(first.x - lastPoint.x, first.y - lastPoint.y) <= 0.01 {
                cleaned.removeLast()
            }
            return cleaned
        }
    }

    /// 이웃하지 않은 두 변이 교차하는 첫 점 (없으면 nil)
    static func selfIntersection(_ polygon: [CGPoint]) -> CGPoint? {
        let n = polygon.count
        guard n > 3 else { return nil }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        for i in 0..<n {
            let p1 = polygon[i]
            let p2 = polygon[(i + 1) % n]
            for j in (i + 2)..<max(i + 2, n) {
                if i == 0, j == n - 1 { continue }
                let q1 = polygon[j]
                let q2 = polygon[(j + 1) % n]
                let d1 = cross(q1, q2, p1)
                let d2 = cross(q1, q2, p2)
                let d3 = cross(p1, p2, q1)
                let d4 = cross(p1, p2, q2)
                let tol: CGFloat = 1e-6
                if ((d1 > tol && d2 < -tol) || (d1 < -tol && d2 > tol)) && ((d3 > tol && d4 < -tol) || (d3 < -tol && d4 > tol)) {
                    let t = d1 / (d1 - d2)
                    return CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t)
                }
            }
        }
        return nil
    }

    /// 스프링 값 0 → 최대값 구간을 촘촘히 훑어 보이는 치수가 튀는 곳(불연속)을 찾는다
    static func discontinuities(from: IslandLayout, to: IslandLayout, maxValue: Double, timeline: SnapshotTimeline) -> [String] {
        let step = 0.0005
        // 입력 값이 한 칸에 움직이는 최대 거리 (이보다 훨씬 크게 움직이면 불연속)
        let rawDeltas: [CGFloat] = [
            to.size.width - from.size.width, to.size.height - from.size.height,
            to.origin.x - from.origin.x, to.origin.y - from.origin.y,
            to.shape.neckLeft - from.shape.neckLeft, to.shape.neckRight - from.shape.neckRight,
            to.shape.neckHeight - from.shape.neckHeight, to.shape.bodyLeft - from.shape.bodyLeft,
            to.shape.bodyRight - from.shape.bodyRight, to.shape.topRadius - from.shape.topRadius,
            to.shape.bodyTopRadius - from.shape.bodyTopRadius, to.shape.shoulderRadius - from.shape.shoulderRadius,
            to.shape.bottomRadius - from.shape.bottomRadius,
        ]
        let rawStep = (rawDeltas.map(abs).max() ?? 0) * CGFloat(step)
        // 몸통 끝은 입력보다 최대 12배 가파르다 (부분 2 가 나오는 폭 6배 × 1 → 2pt 곧은 옆면 풀림 2배).
        // 같은 칸에서 목 폭 등 다른 입력이 함께 움직이는 만큼 10% 여유 (키 큰 펼침 카드에서 경계값을 넘지 않게)
        let threshold = max(1.0, rawStep * 12 * 1.1)

        // 접힌 상태끼리면 부분 1 (그리는 모양), 아니면 주 외곽선 + 부분 1 층
        let part1Only = drawsPart1Only(from) && drawsPart1Only(to)
        func features(_ v: Double) -> [(String, CGFloat)] {
            let layout = SnapshotInterpolation.mix(from, to, v)
            let o = part1Only ? drawnOutline(layout) : outline(layout)
            var part1: [(String, CGFloat)] = []
            if !part1Only {
                let p = IslandShape.part1Outline(layout.shapeSpec, in: CGRect(origin: .zero, size: layout.size)) ?? IslandOutline()
                let x = layout.origin.x
                part1 = [
                    ("부분1 왼쪽", x + p.nx0), ("부분1 오른쪽", x + p.nx1), ("부분1 아래", layout.origin.y + p.bottom),
                    ("부분1 아래반경", p.bottomR), ("부분1 어깨L", p.shoulderL), ("부분1 어깨R", p.shoulderR),
                ]
            }
            return part1 + [
                ("목왼쪽", o.nx0), ("목오른쪽", o.nx1), ("목높이", o.neckBottom), ("아래", o.bottom),
                ("계단L", o.stepL), ("계단R", o.stepR),
                ("몸통왼쪽", o.bx0), ("몸통오른쪽", o.bx1),
                ("위반경L", o.topRL), ("위반경R", o.topRR),
                ("아래반경", o.bottomR), ("어깨L", o.shoulderL), ("어깨R", o.shoulderR),
                ("몸통위L", o.bodyTopL), ("몸통위R", o.bodyTopR),
            ]
        }

        var reports: [String] = []
        var previous = features(0)
        var v = step
        var lastReportedV = -1.0
        while v <= maxValue + step / 2 {
            let current = features(v)
            var jumps: [String] = []
            for (old, new) in zip(previous, current) where abs(new.1 - old.1) > threshold {
                jumps.append(String(format: "%@ %.1f→%.1f", new.0, old.1, new.1))
            }
            if !jumps.isEmpty, v - lastReportedV > step * 1.5 {
                let ms = v <= 1 ? timeline.time(forValue: v) : timeline.spring.peak.time * 1000
                reports.append(String(format: "v %.4f→%.4f (≈%.0fms): ", v - step, v, ms) + jumps.joined(separator: ", "))
            }
            if !jumps.isEmpty { lastReportedV = v }
            previous = current
            v += step
        }
        return reports
    }
}

// MARK: - 시트

@MainActor
enum SnapshotAnimationSheet {
    /// 한 줄에 놓을 프레임 수
    static let columns = 4
    /// 접히는 동안 붙잡은 카드 띠를 놓을 시각이 지나도록 표시 상태의 시계를 돌릴 시간 (`IslandMotion.settleSeconds` 보다 조금 더)
    static let collapseHoldElapsed: TimeInterval = IslandMotion.settleSeconds + 0.05

    struct Frame {
        let ms: Double
        let value: Double
        let layout: IslandLayout
        let content: Content?
        let issues: [String]
    }

    struct Content {
        let mode: IslandMode
        let layout: IslandLayout
        let presentation: PresentationController
        let opacity: Double
        /// 프레임 기준 위치 (사라지는 내용은 화면 위 원래 자리에 머물도록 프레임 이동과 반대로 옮긴다)
        let offset: CGSize
        let label: String
    }

    static func render(_ transition: SnapshotTransition, style requested: IslandSnapshotRenderer.Style) throws -> CGImage {
        let style = transition.style ?? requested
        let from: SnapshotSetup
        let fromLayout: IslandLayout
        let to: SnapshotSetup
        var sheetNote = ""
        if let (sequence, phase) = transition.sequence {
            let prepared = try sequence.prepare(phase, style: style, environment: transition.environment)
            from = prepared.from
            fromLayout = prepared.fromLayout
            to = prepared.to
            sheetNote = prepared.note
        } else if transition.afterCollapse {
            // 카드를 그려 카드 띠를 커밋 → 접힌 상태가 그 띠를 붙잡음(전) → 놓을 시각이 지나 띠를 놓음(후). 같은 표시 상태에서 이어서 계산한다
            let card = try SnapshotStage.prepare(transition.from, style: style, environment: transition.environment)
            card.draw()
            from = try SnapshotStage.prepare(transition.to, style: style, environment: transition.environment)
            from.presentation.adoptLayoutHistory(from: card.presentation)
            fromLayout = from.draw()
            from.uptime.advance(by: Self.collapseHoldElapsed)
            to = from
            sheetNote = "\(transition.from.rawValue) 카드를 접은 뒤 붙잡은 띠를 놓음"
        } else {
            from = try SnapshotStage.prepare(transition.from, style: style, environment: transition.environment)
            // 전 상태를 그리면서(관찰 패스 · 커밋) 배치 이력(직전 접힌 모양 · 열린 카드 띠)이 남는다
            fromLayout = from.draw()
            to = try SnapshotStage.prepare(transition.to, style: style, environment: transition.environment)
            // 실제 앱처럼 전 상태의 배치 이력을 기억한 채 후 상태를 계산한다 (카드 띠 이력 유지, 카드를 접으면 띠를 붙잡음)
            to.presentation.adoptLayoutHistory(from: from.presentation)
        }
        let fromMode = from.mode
        let toMode = Self.sameRequest(to.mode, as: fromMode)
        // 후 상태에서 관찰 패스를 돌린다 (모드가 바뀌며 일어날 일 — 카드 띠를 붙잡는 등 — 을 커밋)
        let toLayout = to.draw()
        let sameKind = fromMode.kind == toMode.kind
        // 내용 구조(모드 종류 · 접힌 표시 방식)가 같으면 내용을 유지하고, 다르면 교체한다 (IslandContainer 와 같은 규칙)
        let sameKey = IslandContentKey(mode: fromMode, layout: fromLayout) == IslandContentKey(mode: toMode, layout: toLayout)
        // 종류가 바뀌면 resize, 같은 종류 안의 크기 변화는 adjust. 같은 종류에서 표시 방식만 바뀌면 교체 지연이 길다
        let timeline = SnapshotTimeline(
            spring: sameKind ? .adjust : .resize,
            swapDelay: sameKind ? IslandMotion.branchContentDelay : IslandMotion.contentDelay
        )
        // 배경 메뉴바는 후 상태 기준
        let bar = to.bar

        var context = SnapshotShapeCheck.Context(geometry: bar.geometry, from: fromLayout, to: toLayout)
        context.glyphs = SnapshotShapeCheck.glyphs(of: bar)
        /// 내용 교체 순서 문제 (보고 앞쪽에 찍는다)
        var report0: [String] = []

        // 내용 교체는 실제 패널의 IslandViewState 를 그대로 돌린다:
        // 전 상태 렌더 → 내용 구조가 바뀐 첫 렌더 → onChange(beginSwap) → contentDelay(to:) 뒤 finishSwap
        let swapState = IslandViewState()
        _ = swapState.outgoingContent(current: fromMode, layout: fromLayout, reduceMotion: false)
        var began = false
        var finished = false
        var frames: [Frame] = []
        let seamEnds = SnapshotSeamCheck.Ends(from: fromLayout, to: toLayout)
        // 부분 1 검사 (카드 ↔ 접힌 상태): 촘촘한 훑기를 먼저 해서 맞닿아 늘어나 보이는 구간을 프레임에도 표시한다
        let peak = timeline.spring.peak
        let part1Ends = SnapshotPart1Check.Ends(from: fromLayout, to: toLayout, cardToCard: transition.sequence?.phase == .change)
        let part1Dense = part1Ends.map {
            SnapshotPart1Check.dense(ends: $0, from: fromLayout, to: toLayout, maxValue: max(1, peak.value), timeline: timeline)
        }
        let part1Header = part1Ends.map { SnapshotPart1Check.headerIssues(ends: $0) } ?? []
        for ms in SnapshotTimeline.frameTimes {
            let v = timeline.value(ms: ms)
            let layout = SnapshotInterpolation.mix(fromLayout, toLayout, v)
            if began, !finished, ms >= timeline.swapMs {
                swapState.finishSwap()
                finished = true
            }
            let outgoing = swapState.outgoingContent(current: toMode, layout: toLayout, reduceMotion: false)
            if !began {
                began = true
                let key = IslandContentKey(mode: toMode, layout: toLayout)
                if !sameKey, swapState.beginSwap(to: key, reduceMotion: false) != .fadeOut {
                    report0.append("   ✗ 내용 교체가 시작되지 않음 (beginSwap)")
                }
                if !sameKey, swapState.contentDelay(to: key) != (sameKind ? IslandMotion.branchContentDelay : IslandMotion.contentDelay) {
                    report0.append("   ✗ 내용 교체 지연이 시트와 다름 (IslandViewState.contentDelay)")
                }
            }
            let content: Content?
            if let outgoing {
                let opacity = timeline.fadeOut(ms: ms)
                let pin = CGSize(width: outgoing.layout.origin.x - layout.origin.x, height: outgoing.layout.origin.y - layout.origin.y)
                content = opacity > 0.001
                    ? Content(mode: outgoing.mode, layout: outgoing.layout, presentation: from.presentation, opacity: opacity, offset: pin, label: String(format: "이전 내용 %.2f", opacity))
                    : nil
            } else if sameKey {
                // 내용 구조가 같으면 내용을 바꾸지 않고 배치만 함께 움직인다
                content = Content(mode: toMode, layout: layout, presentation: to.presentation, opacity: 1, offset: .zero, label: "내용 유지")
            } else {
                if !finished { report0.append(String(format: "   ✗ t=%.0fms: 교체 전에 새 내용이 그려짐", ms)) }
                let opacity = timeline.fadeIn(ms: ms)
                content = Content(mode: toMode, layout: toLayout, presentation: to.presentation, opacity: opacity, offset: .zero, label: String(format: "새 내용 %.2f", opacity))
            }
            // 모양 검사 + 이음매 검사 (목 ↔ 몸통 끊김 · 물림 · 거의 겹친 이음매)
            var issues = SnapshotShapeCheck.check(layout: layout, context: context) + SnapshotSeamCheck.check(layout: layout, ends: seamEnds)
            if let ends = part1Ends {
                issues += SnapshotPart1Check.issues(layout, ends: ends)
                if let hit = SnapshotPart1Check.merged(layout, ends: ends), part1Dense?.mergedRanges.contains(where: { $0.contains(v) }) == true {
                    issues.append(String(format: "부분 1 늘어나 보임 %@ (%.1fpt)", hit.side, hit.depth))
                }
            }
            frames.append(Frame(ms: ms, value: v, layout: layout, content: content, issues: issues))
        }
        if !sameKey, swapState.outgoing != nil || swapState.lastShown?.key != IslandContentKey(mode: toMode, layout: toLayout) {
            report0.append("   ✗ 교체가 끝난 뒤에도 이전 내용이 남음")
        }

        // 연속성 검사 (스프링 값 0 → 최대값)
        let jumps = SnapshotShapeCheck.discontinuities(from: fromLayout, to: toLayout, maxValue: max(1, peak.value), timeline: timeline)
        // 시트 프레임 사이의 경로 조각 (모양이 여러 조각으로 갈라짐)
        let fragmentRuns = SnapshotShapeCheck.denseFragments(from: fromLayout, to: toLayout, maxValue: max(1, peak.value), timeline: timeline)
        // 시트 프레임 사이의 이음매 (거의 겹친 목 끝 · 몸통 끝)
        let seamRuns = SnapshotSeamCheck.denseJointIssues(from: fromLayout, to: toLayout, maxValue: max(1, peak.value), timeline: timeline)

        // stdout 보고
        let styleName = style.rawValue
        var report: [String] = []
        report.append("== \(transition.name) (\(styleName)): \(describe(fromMode)) → \(describe(toMode))")
        let swapLabel = sameKey ? "내용 유지" : String(format: "내용 교체 %.0fms", timeline.swapMs)
        report.append(String(
            format: "   %@ 스프링 response %.2f · damping %.2f · 최대 %.4f @ %.0fms · %@",
            timeline.spring.name, timeline.spring.response, timeline.spring.dampingFraction, peak.value, peak.time * 1000, swapLabel
        ))
        report.append("   전: \(describe(fromLayout))")
        report.append("   후: \(describe(toLayout))")
        if !sheetNote.isEmpty { report.append("   " + sheetNote) }
        for warning in SnapshotTimeline.syncWarnings() { report.append("   ⚠︎ \(warning)") }
        report.append(contentsOf: report0)
        let swapCheck = SnapshotContentSwapCheck.run()
        if swapCheck.problems.isEmpty {
            report.append("   내용 교체 순서 검사 \(swapCheck.cases)개 통과")
        } else {
            report0.append(contentsOf: swapCheck.problems.map { "   ✗ 내용 교체 순서: \($0)" })
            report.append(contentsOf: swapCheck.problems.map { "   ✗ 내용 교체 순서: \($0)" })
        }
        let hoverCheck = SnapshotHoverCheck.run()
        if hoverCheck.problems.isEmpty {
            report.append("   호버 밝힘 순서 검사 \(hoverCheck.cases)개 통과")
        } else {
            report0.append(contentsOf: hoverCheck.problems.map { "   ✗ 호버 밝힘 순서: \($0)" })
            report.append(contentsOf: hoverCheck.problems.map { "   ✗ 호버 밝힘 순서: \($0)" })
        }
        let seamSelfTest = (cases: 5, problems: SnapshotSeamCheck.selfTest())
        for (label, check) in [
            ("겹침 감지", SnapshotOverlapCheck.run()), ("세션 요약 자리", SnapshotSummaryCheck.run()), ("이음매 래스터 자체", seamSelfTest),
            ("메뉴바 알약 제목", SnapshotPillCheck.run()), ("노치 아래 띠 요소", SnapshotStripCheck.run()),
            ("메뉴바 창 찾기", SnapshotMenuBarScanCheck.run()),
            ("승인 대기", SnapshotDecisionCheck.run()), ("배치 이력", SnapshotLayoutHistoryCheck.run()),
            ("비켜주기", SnapshotDodgeCheck.run()), ("앱 안내", SnapshotNoticeCheck.run()),
            ("클릭 모양 · 숫자 키 · 키 녹화 · 상태 아이템", SnapshotInputCheck.run()),
        ] {
            if check.problems.isEmpty {
                report.append("   \(label) 검사 \(check.cases)개 통과")
            } else {
                report0.append(contentsOf: check.problems.map { "   ✗ \(label): \($0)" })
                report.append(contentsOf: check.problems.map { "   ✗ \(label): \($0)" })
            }
        }
        if sameKind, !sameKey { report.append("   같은 종류 · 표시 방식 교체 (이전 내용 제자리 흐림 → 모양이 자리 잡은 뒤 새 내용)") }
        for jump in jumps { report.append("   ✗ 불연속 \(jump)") }
        for run in fragmentRuns { report.append("   ✗ 촘촘히 \(run)") }
        for run in seamRuns { report.append("   ✗ 촘촘히 \(run)") }
        let seamFrames = frames.reduce(0) { $0 + $1.issues.filter { $0.hasPrefix("이음매") }.count }
        report.append("   이음매 검사: 위반 \(seamFrames + seamRuns.count) (프레임 \(seamFrames) · 촘촘히 \(seamRuns.count))")
        let part1Runs = part1Dense?.reports ?? []
        for run in part1Runs { report.append("   ✗ 촘촘히 \(run)") }
        for issue in part1Header { report.append("   ✗ \(issue)") }
        if part1Ends != nil {
            let part1Frames = frames.reduce(0) { $0 + $1.issues.filter { $0.hasPrefix("부분 1") }.count }
            report.append("   부분 1 검사: 위반 \(part1Frames + part1Runs.count + part1Header.count) (프레임 \(part1Frames) · 촘촘히 \(part1Runs.count) · 상단 행 \(part1Header.count))")
        }
        for frame in frames where !frame.issues.isEmpty {
            report.append(String(format: "   ✗ t=%3.0fms v=%.3f: ", frame.ms, frame.value) + frame.issues.joined(separator: " · "))
        }
        if jumps.isEmpty, fragmentRuns.isEmpty, seamRuns.isEmpty, part1Runs.isEmpty, part1Header.isEmpty, report0.isEmpty, frames.allSatisfy({ $0.issues.isEmpty }) {
            report.append("   ✓ 문제 없음")
        }
        // 시트 머리에 적을 프레임 사이 문제 (불연속 · 경로 조각 · 이음매 · 부분 1)
        let notes = jumps.map { "불연속 " + $0 } + fragmentRuns + seamRuns.map { "이음매 " + $0 } + part1Runs + part1Header
        let crop = cropRect(frames: frames, bar: bar, extra: [fromLayout.panelRect, toLayout.panelRect])
        let cellSize = SnapshotAnimationSheetView.cellSize(crop: crop)
        report.append(String(
            format: "   시트: 칸 %.0f×%.0fpt (간격 %.0f, 여백 12) · 머리 %.0fpt · 칸 안 그림 = 화면 x %.0f…%.0f, y 0…%.0f",
            cellSize.width, cellSize.height, SnapshotAnimationSheetView.spacing,
            SnapshotAnimationSheetView.headerHeight(notes: notes.count), crop.minX, crop.maxX, crop.height
        ))
        print(report.joined(separator: "\n"))

        let sheet = SnapshotAnimationSheetView(
            title: "\(transition.name) · \(styleName)",
            subtitle: "\(describe(fromMode)) → \(describe(toMode)) · \(timeline.spring.name) spring(response \(timeline.spring.response), damping \(timeline.spring.dampingFraction)) · \(swapLabel)"
                + (sheetNote.isEmpty ? "" : " · " + sheetNote),
            notes: notes,
            bar: bar,
            crop: crop,
            frames: frames,
            timeline: timeline
        )
        .environment(\.islandRenderContext, IslandRenderContext(isSnapshot: true, fixedNow: to.world.clock.now))
        .environment(\.colorScheme, .light)

        let rows = (frames.count + columns - 1) / columns
        let cell = SnapshotAnimationSheetView.cellSize(crop: crop)
        let size = CGSize(
            width: CGFloat(columns) * cell.width + CGFloat(columns - 1) * SnapshotAnimationSheetView.spacing + 24,
            height: SnapshotAnimationSheetView.headerHeight(notes: notes.count) + CGFloat(rows) * cell.height
                + CGFloat(rows - 1) * SnapshotAnimationSheetView.spacing + 24
        )
        return try SnapshotStage.image(of: sheet, size: size)
    }

    /// 전 · 후를 다른 표시 상태(스냅숏 세계)로 계산하면 같은 요청도 요청 ID 가 다르다 (스토어가 ID 를 새로 만든다).
    /// ID 말고는 같은 요청이면 전 요청 ID 로 맞춘다: 실제 앱에선 한 요청이라 카드 내용을 바꾸지 않는다 (`IslandContentKey.request`)
    private static func sameRequest(_ mode: IslandMode, as reference: IslandMode) -> IslandMode {
        guard case let .permission(old, _) = reference, case .permission(var request, let count) = mode, request.id != old.id else {
            return mode
        }
        request.id = old.id
        return request == old ? .permission(request, queueCount: count) : mode
    }

    private static func cropRect(frames: [Frame], bar: SnapshotMenuBar, extra: [CGRect]) -> CGRect {
        var union = extra.reduce(CGRect.null) { $0.union($1) }
        for frame in frames { union = union.union(frame.layout.panelRect) }
        if bar.geometry.hasNotch {
            let notchWidth = bar.geometry.notchSize.width
            union = union.union(CGRect(x: (bar.geometry.frame.width - notchWidth) / 2, y: 0, width: notchWidth, height: bar.geometry.notchSize.height))
        }
        let minX = max(0, (union.minX - 24).rounded(.down))
        let maxX = min(bar.geometry.frame.width, (union.maxX + 24).rounded(.up))
        let maxY = min(bar.canvasHeight, (union.maxY + 14).rounded(.up))
        return CGRect(x: minX, y: 0, width: maxX - minX, height: max(maxY, bar.geometry.menuBarHeight + 20))
    }

    private static func describe(_ mode: IslandMode) -> String {
        "\(mode.kind)"
    }

    private static func describe(_ layout: IslandLayout) -> String {
        let s = layout.shape
        let text = String(
            format: "프레임 (%.1f,%.1f) %.1f×%.1f · 목 L%.1f R%.1f H%.1f · 몸통 L%.1f R%.1f · 위 %.0f · 몸통위 %.0f · 어깨 %.0f · 아래 %.0f",
            layout.origin.x, layout.origin.y, layout.size.width, layout.size.height,
            s.neckLeft, s.neckRight, s.neckHeight, s.bodyLeft, s.bodyRight,
            s.topRadius, s.bodyTopRadius, s.shoulderRadius, s.bottomRadius
        )
        return text
    }
}

// MARK: - 시트 뷰

struct SnapshotAnimationSheetView: View {
    let title: String
    let subtitle: String
    let notes: [String]
    let bar: SnapshotMenuBar
    let crop: CGRect
    let frames: [SnapshotAnimationSheet.Frame]
    let timeline: SnapshotTimeline

    static let spacing: CGFloat = 10
    static let labelHeight: CGFloat = 44

    static func cellSize(crop: CGRect) -> CGSize {
        CGSize(width: max(crop.width, 260), height: crop.height + labelHeight)
    }

    static func headerHeight(notes: Int) -> CGFloat {
        64 + CGFloat(min(notes, 6)) * 14 + 8
    }

    var body: some View {
        let columns = SnapshotAnimationSheet.columns
        let rows = stride(from: 0, to: frames.count, by: columns).map { Array(frames[$0..<min($0 + columns, frames.count)]) }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Color(hex: 0x555555)).lineLimit(1)
                SnapshotCurvePlot(timeline: timeline, marks: frames.map(\.ms))
                    .frame(width: 360, height: 26)
                ForEach(Array(notes.prefix(6).enumerated()), id: \.offset) { _, note in
                    Text(note).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(hex: 0xC0261E)).lineLimit(1)
                }
            }
            .frame(height: Self.headerHeight(notes: notes.count), alignment: .topLeading)

            VStack(alignment: .leading, spacing: Self.spacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: Self.spacing) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, frame in
                            SnapshotAnimationCell(bar: bar, crop: crop, frame: frame)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
    }
}

/// 스프링 곡선과 샘플 위치
private struct SnapshotCurvePlot: View {
    let timeline: SnapshotTimeline
    let marks: [Double]

    var body: some View {
        Canvas { context, size in
            let maxMs = 800.0
            let top = 1.05
            func point(_ ms: Double) -> CGPoint {
                CGPoint(x: size.width * ms / maxMs, y: size.height * (1 - timeline.value(ms: ms) / top))
            }
            var curve = Path()
            curve.move(to: point(0))
            for ms in stride(from: 0.0, through: maxMs, by: 4) { curve.addLine(to: point(ms)) }
            var one = Path()
            one.move(to: CGPoint(x: 0, y: size.height * (1 - 1 / top)))
            one.addLine(to: CGPoint(x: size.width, y: size.height * (1 - 1 / top)))
            context.stroke(one, with: .color(Color(hex: 0xBBBBBB)), lineWidth: 0.5)
            context.stroke(curve, with: .color(Color(hex: 0x333333)), lineWidth: 1)
            let swap = timeline.swapMs
            var swapLine = Path()
            swapLine.move(to: CGPoint(x: size.width * swap / maxMs, y: 0))
            swapLine.addLine(to: CGPoint(x: size.width * swap / maxMs, y: size.height))
            context.stroke(swapLine, with: .color(Color(hex: 0x2B6CB0)), lineWidth: 0.5)
            for ms in marks {
                let p = point(ms)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)), with: .color(Color(hex: 0xC0261E)))
            }
        }
    }
}

private struct SnapshotAnimationCell: View {
    let bar: SnapshotMenuBar
    let crop: CGRect
    let frame: SnapshotAnimationSheet.Frame

    var body: some View {
        let geometry = bar.geometry
        let cell = SnapshotAnimationSheetView.cellSize(crop: crop)
        VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .topLeading) {
                Color(hex: 0xDAD8D1)
                SnapshotMenuBarStrip(bar: bar)
                SnapshotAnimatedIsland(layout: frame.layout, content: frame.content)
                if geometry.hasNotch {
                    // 하드웨어 노치 (실제처럼 검정, 아일랜드 위)
                    UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                        .fill(Palette.background)
                        .frame(width: geometry.notchSize.width, height: geometry.notchSize.height)
                        .offset(x: (geometry.frame.width - geometry.notchSize.width) / 2)
                }
            }
            .frame(width: geometry.frame.width, height: bar.canvasHeight, alignment: .topLeading)
            .offset(x: -crop.minX, y: -crop.minY)
            .frame(width: crop.width, height: crop.height, alignment: .topLeading)
            .clipped()

            // 문제가 있는 프레임은 그림 아래에 빨간 막대 (그림 가장자리를 가리지 않게)
            Rectangle()
                .fill(frame.issues.isEmpty ? Color.black.opacity(0.12) : Color(hex: 0xC0261E))
                .frame(width: crop.width, height: frame.issues.isEmpty ? 1 : 3)

            Text(String(format: "t=%3.0fms  v=%.3f  %@", frame.ms, frame.value, frame.content?.label ?? "내용 없음"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(hex: 0x222222))
            if !frame.issues.isEmpty {
                Text(frame.issues.joined(separator: " · "))
                    .font(.system(size: 9))
                    .foregroundStyle(Color(hex: 0xC0261E))
                    .lineLimit(2)
                    .frame(width: crop.width, alignment: .leading)
            }
        }
        .frame(width: cell.width, height: cell.height, alignment: .topLeading)
    }
}

/// IslandContainer 와 같은 짜임: 내용 → 프레임 → 배경(모양) → 모양으로 자르기 → 위치.
/// 레이아웃 값만 애니메이션 중간값으로 직접 넣는다.
private struct SnapshotAnimatedIsland: View {
    let layout: IslandLayout
    let content: SnapshotAnimationSheet.Content?

    var body: some View {
        let spec = layout.shapeSpec
        ZStack(alignment: .topLeading) {
            if let content {
                IslandContentView(mode: content.mode, layout: content.layout, presentation: content.presentation, reduceMotion: false)
                    .frame(width: content.layout.size.width, height: content.layout.size.height, alignment: .topLeading)
                    .offset(content.offset)
                    .opacity(content.opacity)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .background {
            IslandBackground(shape: IslandShape(spec: spec))
        }
        .clipShape(IslandShape(spec: spec))
        .offset(x: layout.origin.x, y: layout.origin.y)
    }
}
