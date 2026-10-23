import AppKit
import NotchCore

// 전환 시트(`--render-island anim-*`)가 함께 돌리는 순수 계산 검사.
// - 열린 메뉴 · 팝오버 겹침 감지 (`OverlapScanner` · `OverlapMonitor.classify`): 잠깐 뜬 창 · 화면 테두리에 깜빡이지 않는지
// - 세션 상태 요약 자리 (`IslandLayoutEngine`): 개수가 한 자리 안에서 바뀌어도 폭이 같고, 흔한 메뉴바에서 요약이 빠지지 않는지

// MARK: - 겹침 감지

@MainActor
enum SnapshotOverlapCheck {
    static func run() -> (cases: Int, problems: [String]) {
        var problems: [String] = []
        var cases = 0

        // 1000×800 노치 화면 (Cocoa 전역, 원점 왼쪽 아래). 메뉴바 33pt, 노치 185×32
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let menuBarBottom: CGFloat = 800 - 33
        let target = OverlapScanner.Target(
            id: 1,
            screenFrame: screen,
            zone: CGRect(x: 260, y: 800 - 300, width: 480, height: 300),
            island: CGRect(x: 289, y: menuBarBottom - 6, width: 422, height: 39),
            notchRect: CGRect(x: 407.5, y: 768, width: 185, height: 32).insetBy(dx: 6, dy: 4)
        )
        let ownPID = 100
        let menu = WindowLevels.popUpMenu
        func window(
            _ number: Int, _ frame: CGRect, layer: Int = WindowLevels.popUpMenu, alpha: Double = 1, pid: Int = 200
        ) -> WindowSnapshot.Window {
            WindowSnapshot.Window(number: number, pid: pid, layer: layer, frame: frame, alpha: alpha)
        }
        func scan(_ windows: [WindowSnapshot.Window], includeOwn: Bool = false, target: OverlapScanner.Target = target) -> [OverlapScanner.Candidate] {
            OverlapScanner.scan(
                WindowSnapshot(windows: windows), targets: [target], ownPID: ownPID,
                ourLevel: NotchPanel.islandLevel.rawValue, includeOwnPopups: includeOwn
            )
        }

        // 1) 어떤 창을 겹침 후보로 보는지 (기대: nil = 후보 아님, (zone, island))
        let statusMenu = window(1, CGRect(x: 600, y: menuBarBottom - 200, width: 180, height: 200))
        let scanCases: [(String, WindowSnapshot.Window, Bool, (zone: Bool, island: Bool)?)] = [
            ("메뉴바에서 내려온 상태 아이템 메뉴", statusMenu, false, (true, true)),
            ("화면 끝까지 긴 메뉴", window(2, CGRect(x: 300, y: 0, width: 200, height: menuBarBottom)), false, (true, true)),
            ("카드 자리 아래쪽 툴팁", window(3, CGRect(x: 450, y: 600, width: 120, height: 20), layer: menu + 99), false, (true, false)),
            ("화면 위 테두리 띠 (4pt)", window(4, CGRect(x: 0, y: 796, width: 1000, height: 4), layer: menu + 50), false, nil),
            ("화면 위 테두리 띠 (12pt)", window(5, CGRect(x: 0, y: 788, width: 1000, height: 12), layer: menu + 50), false, nil),
            ("전체 화면 가림막", window(6, screen, layer: menu + 50, alpha: 0.3), false, nil),
            ("거의 전체 화면 오버레이", window(7, CGRect(x: 20, y: 20, width: 960, height: 760), layer: menu + 50), false, nil),
            ("투명한 팝업", window(8, CGRect(x: 450, y: 700, width: 100, height: 60), alpha: 0.02), false, nil),
            ("아주 작은 창", window(9, CGRect(x: 500, y: 780, width: 6, height: 6)), false, nil),
            ("보통 창 레벨", window(10, CGRect(x: 300, y: 600, width: 400, height: 300), layer: 0), false, nil),
            ("우리 창 (우리 메뉴 아닐 때)", window(11, CGRect(x: 600, y: 600, width: 180, height: 167), pid: ownPID), false, nil),
            ("우리 메뉴 (메뉴 추적 중)", window(12, CGRect(x: 600, y: 600, width: 180, height: 167), pid: ownPID), true, (true, true)),
        ]
        for (name, item, includeOwn, expected) in scanCases {
            cases += 1
            let found = scan([item], includeOwn: includeOwn).first { $0.overlapsZone }
            switch (expected, found) {
            case (nil, nil): break
            case (nil, _?): problems.append("\(name): 겹침으로 봄 (무시해야 함)")
            case (_?, nil): problems.append("\(name): 겹침으로 안 봄")
            case let (want?, got?):
                if got.overlapsIsland != want.island {
                    problems.append("\(name): 아일랜드 겹침 \(got.overlapsIsland) (기대 \(want.island))")
                }
            }
        }
        cases += 1
        if !OverlapScanner.isScreenOverlay(CGRect(x: 0, y: 0, width: 6, height: 800), screen: screen) {
            problems.append("화면 왼쪽 세로 테두리를 오버레이로 안 봄")
        }

        // 2) 조회 순서: 연달아 보여야 겹침, 사라지면 바로 풀림, 모양이 바뀌는 중엔 새로 숨기지 않음
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func run(
            _ name: String,
            _ steps: [(ms: Double, windows: [WindowSnapshot.Window], includeOwn: Bool, allows: Bool)],
            expect: [(occluded: Bool, concealed: Bool)]
        ) {
            cases += 1
            var tracking = OverlapMonitor.Tracking()
            var state = OverlapMonitor.State()
            for (index, step) in steps.enumerated() {
                var stepTarget = target
                stepTarget.allowsNewConcealment = step.allows
                let candidates = scan(step.windows, includeOwn: step.includeOwn, target: stepTarget)
                state = OverlapMonitor.classify(
                    candidates, targets: [stepTarget], previous: state, tracking: &tracking,
                    now: base.addingTimeInterval(step.ms / 1000)
                )
                let got = (state.occluded.contains(1), state.concealed.contains(1))
                let want = expect[index]
                if got != (want.occluded, want.concealed) {
                    problems.append(String(
                        format: "%@ %.0fms: 겹침 %@ · 숨김 %@ (기대 %@ · %@)", name, step.ms,
                        "\(got.0)", "\(got.1)", "\(want.occluded)", "\(want.concealed)"
                    ))
                }
            }
        }
        let flash = window(20, CGRect(x: 380, y: 700, width: 240, height: 100), layer: menu + 50)
        run("한 번만 보인 창", [(0, [flash], false, true), (250, [], false, true)], expect: [(false, false), (false, false)])
        run(
            "열린 메뉴",
            [(0, [statusMenu], false, true), (250, [statusMenu], false, true), (500, [], false, true)],
            expect: [(false, false), (true, true), (false, false)]
        )
        run(
            "알림 · 폴링이 겹쳐 10ms 간격으로 두 번 본 창",
            [(0, [statusMenu], false, true), (10, [statusMenu], false, true), (250, [statusMenu], false, true)],
            expect: [(false, false), (false, false), (true, true)]
        )
        let ownMenu = window(21, CGRect(x: 600, y: 600, width: 180, height: 167), pid: ownPID)
        run("우리 메뉴", [(0, [ownMenu], true, true), (100, [], false, true)], expect: [(true, true), (false, false)])
        run(
            "펼치고 접는 중 · 마우스가 위",
            [(0, [statusMenu], false, false), (250, [statusMenu], false, false), (500, [statusMenu], false, true)],
            expect: [(false, false), (true, false), (true, true)]
        )
        run(
            "숨긴 뒤 모양이 바뀜 (숨김 유지)",
            [(0, [statusMenu], false, true), (250, [statusMenu], false, true), (500, [statusMenu], false, false)],
            expect: [(false, false), (true, true), (true, true)]
        )
        let tooltip = window(22, CGRect(x: 450, y: 600, width: 120, height: 20), layer: menu + 99)
        run("카드 자리 아래쪽 툴팁", [(0, [tooltip], false, true), (250, [tooltip], false, true)], expect: [(false, false), (true, false)])
        // 메뉴바에서 옆 메뉴로 옮겨 열면 창 번호가 바뀐다: 이미 겹친(숨긴) 화면은 새 창이 처음 보인 조회에도 그대로
        let nextMenu = window(23, CGRect(x: 520, y: menuBarBottom - 240, width: 200, height: 240))
        run(
            "메뉴 바꿔 열기",
            [(0, [statusMenu], false, true), (250, [statusMenu], false, true), (500, [nextMenu], false, true), (750, [nextMenu], false, true)],
            expect: [(false, false), (true, true), (true, true), (true, true)]
        )
        run(
            "메뉴 바꿔 열기 (모양이 바뀌는 중에도 숨김 유지)",
            [(0, [statusMenu], false, true), (250, [statusMenu], false, true), (500, [nextMenu], false, false), (750, [], false, true)],
            expect: [(false, false), (true, true), (true, true), (false, false)]
        )
        run(
            "아일랜드에 닿던 메뉴 → 카드 자리 아래쪽 툴팁",
            [(0, [statusMenu], false, true), (250, [statusMenu], false, true), (500, [tooltip], false, true)],
            expect: [(false, false), (true, true), (true, false)]
        )
        run(
            "카드 자리만 겹친 뒤 처음 본 창이 아일랜드에 닿음 (새로 숨기려면 지속돼야 함)",
            [(0, [tooltip], false, true), (250, [tooltip], false, true), (500, [nextMenu], false, true), (750, [nextMenu], false, true)],
            expect: [(false, false), (true, false), (true, false), (true, true)]
        )
        return (cases, problems)
    }
}

// MARK: - 세션 상태 요약 자리

@MainActor
enum SnapshotSummaryCheck {
    static func run() -> (cases: Int, problems: [String]) {
        var problems: [String] = []
        var cases = 0

        // 개수가 한 자리 안에서 바뀌면 폭이 같다 (접힌 모양이 출렁이지 않게)
        let width = CompactText.summaryWidth
        let checks: [(String, Bool)] = [
            ("1·1·1 = 2·3·9", width(SessionStatusSummary(waiting: 1, working: 1, done: 1)) == width(SessionStatusSummary(waiting: 2, working: 3, done: 9))),
            ("끝남 1 = 끝남 7", width(SessionStatusSummary(done: 1)) == width(SessionStatusSummary(done: 7))),
            ("9 < 10 (자릿수)", width(SessionStatusSummary(done: 9)) < width(SessionStatusSummary(done: 10))),
            ("묶음이 늘면 넓어짐", width(SessionStatusSummary(done: 2)) < width(SessionStatusSummary(working: 1, done: 2))),
            ("비면 0", width(.empty) == 0),
        ]
        for (name, ok) in checks {
            cases += 1
            if !ok { problems.append("요약 폭 \(name) 아님") }
        }

        // 흔한 메뉴바에서 요약이 빠지지 않는지 (요약은 툴 이름 · 프로젝트명보다 먼저 남긴다)
        let summaries: [(String, SessionStatusSummary)] = [
            ("끝남 2", SessionStatusSummary(done: 2)),
            ("세 묶음", SessionStatusSummary(waiting: 1, working: 1, done: 2)),
        ]
        // 노치 화면은 메뉴바 배치와 관계없이 늘 노치 폭 띠라 한 가지만 본다
        let scenes: [(String, IslandSnapshotRenderer.Style, SnapshotMenuBar.Crowding)] = [
            ("노치 아래 띠", .notch, .bothBlocked),
            ("메뉴바 알약", .menuBar, .roomy),
        ]
        for (sceneName, style, crowding) in scenes {
            let bar = SnapshotMenuBar(style: style, crowding: crowding)
            let engine = IslandLayoutEngine(
                geometry: bar.geometry, space: bar.space, externalStyle: .inMenuBar
            )
            for (summaryName, summary) in summaries {
                cases += 1
                let metrics = CompactMetrics(
                    project: CompactText.width("api-server", font: IslandFont.bodyNS),
                    tool: CompactText.width("Bash", font: IslandFont.bodyNS),
                    trailing: CompactText.statWidth(added: 12, removed: 3),
                    summary: CompactText.summaryWidth(summary),
                    isAttention: false
                )
                let layout = engine.compactLayout(for: .session(metrics))
                let shown: Bool
                switch layout.compact {
                case let .strip(items): shown = items.contains(.summary)
                case let .pill(items): shown = items.contains(.summary)
                default: shown = false
                }
                if !shown { problems.append("\(sceneName) · \(summaryName): 요약 자리 없음") }
                // 개수만 바뀐 요약은 레이아웃이 같아야 한다
                var bumped = metrics
                bumped.summary = CompactText.summaryWidth(SessionStatusSummary(
                    waiting: summary.waiting > 0 ? summary.waiting + 1 : 0,
                    working: summary.working > 0 ? summary.working + 1 : 0,
                    done: summary.done + 1
                ))
                cases += 1
                if engine.compactLayout(for: .session(bumped)) != layout {
                    problems.append("\(sceneName) · \(summaryName): 개수만 바뀌었는데 레이아웃이 바뀜")
                }
            }
        }
        return (cases, problems)
    }
}

// MARK: - 메뉴바 알약 제목

/// 노치 없는 화면의 알약이 제목(프로젝트명 · 툴 제목)을 빼고 상태 아이콘만 남기지 않는지, 알약이 빈 곳 안에 있는지.
/// 상태 아이템도 못 잰 1920pt 외부 모니터 (빈 곳 추정 864…1160, 화면 가운데 960 → 가운데로는 176pt)
@MainActor
enum SnapshotPillCheck {
    static func run() -> (cases: Int, problems: [String]) {
        var problems: [String] = []
        var cases = 0

        let geometry = NotchGeometry(
            screenID: 2, frame: CGRect(x: 1732, y: 982, width: 1920, height: 1080),
            hasNotch: false, notchSize: .zero, isBuiltIn: false, menuBarHeight: 24
        )
        let unmeasured = MenuBarSpace(menuBarVisible: true, menuBarHeight: 24)
        func engine(_ style: ExternalDisplayStyle, space: MenuBarSpace = unmeasured) -> IslandLayoutEngine {
            IslandLayoutEngine(
                geometry: geometry, space: space, externalStyle: style
            )
        }
        let font = IslandFont.bodyNS
        func metrics(tool: String, project: String = "agent-notch", stat: (Int, Int) = (0, 0), summary: SessionStatusSummary = .empty) -> CompactMetrics {
            CompactMetrics(
                project: CompactText.width(project, font: font),
                tool: CompactText.width(tool, font: font),
                trailing: CompactText.statWidth(added: stat.0, removed: stat.1),
                summary: CompactText.summaryWidth(summary),
                isAttention: false
            )
        }
        // 접힌 상태 툴은 짧은 이름만 (MCP 는 서버 이름). 긴 서버 이름은 줄여서 넣는다
        let tools = ["Claude_Browser", "plugin_design_figma", "Bash", "생각 중"]
        let summaries: [(String, SessionStatusSummary)] = [("요약 없음", .empty), ("요약", SessionStatusSummary(waiting: 1, done: 2))]

        // 1) 메뉴바 안 알약: 제목이 들어가고, 빈 곳(여백 8pt 안쪽) 안에 있다
        let inMenuBar = engine(.inMenuBar)
        guard let gap = inMenuBar.menuBarGap else { return (1, ["추정 빈 곳 없음"]) }
        for tool in tools {
            for stat in [(0, 0), (12, 3)] {
                for (summaryName, summary) in summaries {
                    cases += 1
                    let name = "메뉴바 안 · \(tool) · +\(stat.0) −\(stat.1) · \(summaryName)"
                    let layout = inMenuBar.compactLayout(for: .session(metrics(tool: tool, stat: stat, summary: summary)))
                    guard case let .pill(items) = layout.compact else {
                        problems.append("\(name): 알약이 아님")
                        continue
                    }
                    if !items.contains(.tool), !items.contains(.project) { problems.append("\(name): 제목 없이 상태 아이콘만") }
                    if !summary.isEmpty, !items.contains(.summary) { problems.append("\(name): 요약 빠짐") }
                    let rect = layout.panelRect
                    if rect.minX < gap.start + IslandMetrics.menuBarMargin - 0.5 || rect.maxX > gap.end - IslandMetrics.menuBarMargin + 0.5 {
                        problems.append(String(format: "%@: 알약 %.0f…%.0f 이 빈 곳 밖", name, rect.minX, rect.maxX))
                    }
                }
            }
        }

        // 2) 짧은 제목은 화면 가운데 그대로 (가운데로 들어가면 옮기지 않는다)
        cases += 1
        let short = inMenuBar.compactLayout(for: .session(metrics(tool: "Read", project: "blog")))
        if abs(short.panelRect.midX - inMenuBar.midX) > 0.5 {
            problems.append(String(format: "짧은 제목: 알약 가운데 %.1f (화면 가운데 %.0f)", short.panelRect.midX, inMenuBar.midX))
        }

        // 3) 빈 곳이 좁아도 툴 제목 최소 폭이 들어가면 제목을 넣는다 (빈 곳 약 124pt: 추정한 앱 메뉴 끝 ~ 잰 상태 아이템 시작)
        cases += 1
        let tight = engine(.inMenuBar, space: MenuBarSpace(
            menuBarVisible: true, menuBarHeight: 24, statusStart: gap.start + 2 * IslandMetrics.menuBarMargin + 124, statusMeasured: true
        ))
        if case let .pill(items) = tight.compactLayout(for: .session(metrics(tool: "plugin_design_figma"))).compact {
            if !items.contains(.tool), !items.contains(.project) { problems.append("좁은 빈 곳: 제목 없이 상태 아이콘만") }
        } else {
            problems.append("좁은 빈 곳: 알약이 아님")
        }

        // 3-1) 빈 곳 폭을 80…200pt 로 훑기: 줄인 프로젝트명이라도 들어가면 상태 아이콘만 남기지 않는다.
        //      요약이 없으면 툴 제목이 먼저이고, 툴 제목이 줄여도 안 들어갈 때만 프로젝트명. 제목을 넣었으면 알약 안에 들어간다
        for tool in ["Claude_Browser", "plugin_design_figma"] {
            for stat in [(0, 0), (12, 3)] {
                for (summaryName, summary) in summaries {
                    cases += 1
                    let sweptMetrics = metrics(tool: tool, project: "api-server", stat: stat, summary: summary)
                    let base: CompactItems = summary.isEmpty ? [] : [.summary]
                    for room in stride(from: CGFloat(80), through: 200, by: 1) {
                        let swept = engine(.inMenuBar, space: MenuBarSpace(
                            menuBarVisible: true, menuBarHeight: 24,
                            statusStart: gap.start + 2 * IslandMetrics.menuBarMargin + room, statusMeasured: true
                        ))
                        let name = "빈 곳 \(Int(room))pt · \(tool) · +\(stat.0) −\(stat.1) · \(summaryName)"
                        let layout = swept.compactLayout(for: .session(sweptMetrics))
                        guard case let .pill(items) = layout.compact else {
                            problems.append("\(name): 알약이 아님")
                            break
                        }
                        let width = layout.size.width
                        let titled = items.contains(.project) || items.contains(.tool)
                        func fits(_ candidate: CompactItems) -> Bool {
                            IslandLayoutEngine.pillNeed(sweptMetrics, items: candidate, squeezed: true) <= width
                        }
                        if !titled, fits(base.union(.project)) {
                            problems.append("\(name): 줄인 프로젝트명이 들어가는데 상태 아이콘만")
                            break
                        }
                        if summary.isEmpty, !items.contains(.tool), fits([.tool]) {
                            problems.append("\(name): 줄인 툴 제목이 들어가는데 뺌")
                            break
                        }
                        if titled, !fits(items) {
                            problems.append("\(name): 고른 제목이 알약(\(Int(width))pt)에 안 들어감")
                            break
                        }
                    }
                }
            }
        }

        // 4) 메뉴바 아래 알약도 같은 규칙
        let below = engine(.belowMenuBar)
        for tool in tools {
            for (summaryName, summary) in summaries {
                cases += 1
                let layout = below.compactLayout(for: .session(metrics(tool: tool, stat: (12, 3), summary: summary)))
                guard case let .pill(items) = layout.compact else {
                    problems.append("메뉴바 아래 · \(tool) · \(summaryName): 알약이 아님")
                    continue
                }
                if !items.contains(.tool) { problems.append("메뉴바 아래 · \(tool) · \(summaryName): 툴 제목 빠짐") }
            }
        }

        // 5) 펼친 카드 목 알약: 빈 곳 안으로 민 알약을 그대로 이어받는다
        cases += 1
        let content = CompactContent.session(metrics(tool: "Claude_Browser"))
        let compact = inMenuBar.compactPlacement(for: content)
        var opened = inMenuBar
        opened.previousPill = compact
        if opened.cardPill(for: compact) != compact { problems.append("펼친 카드 목 알약이 접힌 알약과 다름") }
        return (cases, problems)
    }
}

// MARK: - 노치 아래 띠 요소

/// 노치 아래 띠가 메뉴바 알약과 같은 규칙으로 요소를 고르는지 (두 화면이 같은 세션 상태에 같은 내용을 보여주는지).
/// 띠 폭은 노치 폭 그대로이고, 백그라운드 배지 · 요약은 둘째 줄로 내릴 수 있다 (제목 줄 요소는 배지 · 요약 없이 고른다)
@MainActor
enum SnapshotStripCheck {
    static func run() -> (cases: Int, problems: [String]) {
        var problems: [String] = []
        var cases = 0
        let font = IslandFont.bodyNS
        func metrics(
            project: String, tool: String, stat: (Int, Int), summary: SessionStatusSummary, attention: String? = nil, background: Int = 0
        ) -> CompactMetrics {
            CompactMetrics(
                project: CompactText.width(project, font: font),
                tool: attention == nil ? CompactText.width(tool, font: font) : 0,
                trailing: attention.map { CompactText.width($0, font: font) } ?? CompactText.statWidth(added: stat.0, removed: stat.1),
                badge: CompactText.backgroundBadgeWidth(background),
                summary: CompactText.summaryWidth(summary),
                isAttention: attention != nil
            )
        }
        /// 배지를 끝 요소에 이어 붙여 잰 같은 내용 (배지를 따로 두지 않던 셈법)
        func inlineBadge(_ m: CompactMetrics) -> CompactMetrics {
            var inline = m
            inline.trailing = m.trailingWithBadge
            inline.badge = 0
            return inline
        }
        func withoutBadge(_ m: CompactMetrics) -> CompactMetrics {
            var plain = m
            plain.badge = 0
            return plain
        }
        typealias E = IslandLayoutEngine
        let title: CompactItems = [.project, .tool]

        // 1) 사용자 화면: 노치 아래 띠(노치 185pt)와 메뉴바 알약이 같은 요소 ("agent-notch · 생각 중")
        let notchBar = SnapshotMenuBar(style: .notch, crowding: .bothBlocked)
        let stripEngine = IslandLayoutEngine(
            geometry: notchBar.geometry, space: notchBar.space, externalStyle: .inMenuBar
        )
        let pillBar = SnapshotMenuBar(style: .menuBar, crowding: .roomy)
        let pillEngine = IslandLayoutEngine(
            geometry: pillBar.geometry, space: pillBar.space, externalStyle: .inMenuBar
        )
        func items(_ layout: IslandLayout) -> CompactItems? {
            switch layout.compact {
            case let .strip(items)?, let .pill(items)?: return items
            default: return nil
            }
        }
        let user = metrics(project: "agent-notch", tool: "생각 중", stat: (0, 0), summary: .empty)
        cases += 1
        let userStrip = items(stripEngine.compactLayout(for: .session(user)))
        let userPill = items(pillEngine.compactLayout(for: .session(user)))
        if userStrip != [.project, .tool] { problems.append("agent-notch · 생각 중: 노치 아래 띠 요소 \(String(describing: userStrip)) (프로젝트 · 툴 기대)") }
        if userStrip != userPill { problems.append("agent-notch · 생각 중: 띠 \(String(describing: userStrip)) ≠ 알약 \(String(describing: userPill))") }

        // 1-1) 백그라운드 배지가 있어도 두 화면 제목이 같다 ("blog · Bash +12 −3 ⧉ 3").
        //      띠는 배지(와 요약)를 둘째 줄로 내리고, 알약은 끝에 그대로 둔다.
        //      (에이전트 아이콘이 들어간 노치 185pt 띠에는 "api-server · Bash +12 −3" 이 들어가지 않아 짧은 프로젝트로 본다)
        for (summaryName, summary) in [("요약 없음", SessionStatusSummary.empty), ("요약 ● 2", SessionStatusSummary(done: 2))] {
            cases += 1
            let name = "blog · Bash +12 −3 ⧉ 3 · \(summaryName)"
            let background = metrics(project: "blog", tool: "Bash", stat: (12, 3), summary: summary, background: 3)
            let strip = stripEngine.compactLayout(for: .session(background))
            guard let stripItems = items(strip), let pillItems = items(pillEngine.compactLayout(for: .session(background))) else {
                problems.append("\(name): 띠 · 알약이 아님")
                continue
            }
            if !stripItems.isSuperset(of: title) || stripItems.intersection(title) != pillItems.intersection(title) {
                problems.append("\(name): 띠 제목 \(stripItems.rawValue) ≠ 알약 제목 \(pillItems.rawValue) (프로젝트 · 툴 기대)")
            }
            if !strip.hasTwoLineStrip { problems.append("\(name): 배지가 제목 줄에 함께 안 들어가는데 띠가 한 줄") }
        }

        // 2) 같은 측정값이면 두 폭에 다 들어가는 한 같은 요소 (같은 후보 순서 · 같은 줄임 규칙)
        let projects = ["agent-notch", "api-server", "blog", "a-very-long-project-name"]
        let tools = ["생각 중", "Bash", "Read", "Claude_Browser", "plugin_design_figma"]
        let stats = [(0, 0), (12, 3), (1234, 567)]
        let summaries: [SessionStatusSummary] = [.empty, SessionStatusSummary(waiting: 1, done: 2)]
        // 백그라운드 작업 없음 · 한 자리 · 두 자리
        let backgrounds = [0, 3, 12]
        var samples: [CompactMetrics] = []
        for project in projects {
            for background in backgrounds {
                for tool in tools {
                    for stat in stats {
                        for summary in summaries {
                            samples.append(metrics(project: project, tool: tool, stat: stat, summary: summary, background: background))
                        }
                    }
                }
                for summary in summaries {
                    samples.append(metrics(project: project, tool: "", stat: (0, 0), summary: summary, attention: "승인 필요", background: background))
                }
            }
        }
        for sample in samples {
            let content = CompactContent.session(sample)
            let strip = stripEngine.compactLayout(for: content)
            let pill = pillEngine.compactLayout(for: content)
            guard let stripItems = items(strip), let pillItems = items(pill) else {
                cases += 1
                problems.append(String(format: "프로젝트 %.0f · 툴 %.0f: 띠 · 알약이 아님", sample.project, sample.tool))
                continue
            }
            let name = String(
                format: "프로젝트 %.0f · 툴 %.0f · 뒤 %.0f · 배지 %.0f · 요약 %.0f%@",
                sample.project, sample.tool, sample.trailing, sample.badge, sample.summary, sample.isAttention ? " · 상태 문구" : ""
            )
            let first = E.pillVariants(sample)[0]
            let stripRoom = stripEngine.notchWidth
            // 띠(배지 · 요약 없이 제목 줄) · 알약(배지 · 요약까지 한 줄) 모두 첫 후보(가장 많은 요소)가 들어가면 둘 다 그것
            cases += 1
            if E.lineNeed(sample, items: first, squeezed: true, chrome: .strip) <= stripRoom,
               E.pillNeed(sample, items: first, squeezed: true) <= pill.size.width,
               stripItems != first || pillItems != first {
                problems.append("\(name): 둘 다 들어가는데 띠 \(stripItems.rawValue) · 알약 \(pillItems.rawValue) (기대 \(first.rawValue))")
            }
            // 띠는 알약 규칙(`lineItems`) 그대로: 들어가는 첫 후보
            cases += 1
            if stripItems != E.lineItems(sample, width: stripRoom, chrome: .strip) {
                problems.append("\(name): 띠 요소가 알약 규칙과 다름")
            }
            // 띠 제목 줄은 배지를 빼고 고른다: 배지가 없는 같은 내용과 같은 요소
            cases += 1
            if sample.badge > 0, items(stripEngine.compactLayout(for: .session(withoutBadge(sample)))) != stripItems {
                problems.append("\(name): 배지 때문에 띠 제목 줄 요소가 바뀜 (\(stripItems.rawValue))")
            }
            // 줄인 프로젝트명이라도 들어가면 상태 아이콘만 남기지 않는다
            cases += 1
            let titled = stripItems.contains(.project) || stripItems.contains(.tool)
            if !titled, E.lineNeed(sample, items: [.project], squeezed: true, chrome: .strip) <= stripRoom {
                problems.append("\(name): 줄인 프로젝트명이 들어가는데 상태 아이콘만")
            }
            // 띠 높이: 배지 · 요약이 줄이지 않은 제목 줄에 함께 안 들어갈 때만 두 줄 (폭은 늘 노치 폭).
            // 한 줄 기대값은 배지를 끝 요소에 이어 붙여 따로 잰다
            cases += 1
            let twoLine = strip.hasTwoLineStrip
            let inline = inlineBadge(sample)
            let wrapsExpected = (sample.badge > 0 || E.summaryNeed(sample, items: stripItems, chrome: .strip) > 0)
                && E.lineNeed(inline, items: stripItems, squeezed: false, chrome: .strip) + E.summaryNeed(inline, items: stripItems, chrome: .strip) > stripRoom
            if twoLine != wrapsExpected || twoLine != E.stripWraps(sample, items: stripItems, width: stripRoom) || abs(strip.size.width - stripRoom) > 0.5 {
                problems.append("\(name): 띠 높이 · 폭이 규칙과 다름 (두 줄 \(twoLine), 기대 \(wrapsExpected), 폭 \(Int(strip.size.width)))")
            }
            // 둘째 줄(배지 · 요약)은 띠 안 (좌우 여백 10)
            cases += 1
            if twoLine {
                let summary = stripItems.contains(.summary) ? sample.summary : 0
                let second = sample.badge + summary + (sample.badge > 0 && summary > 0 ? IslandMetrics.summaryLead : 0)
                if 20 + second > stripRoom { problems.append("\(name): 둘째 줄 \(Int(second))pt 가 띠 밖") }
            }
            // 알약은 배지를 끝 요소에 그대로 센다 (배지를 따로 두기 전 셈법과 같은 폭)
            cases += 1
            if E.pillNeed(sample, items: first) != E.pillNeed(inline, items: first) {
                problems.append("\(name): 알약이 배지를 끝 요소와 다르게 셈")
            }
        }
        return (cases, problems)
    }
}

// MARK: - 메뉴바 창 찾기

/// 창 목록으로 화면마다 메뉴바 높이를 찾을 때, 위 가장자리 높이가 같은 옆 화면의 메뉴바 창을 가져오지 않는지
@MainActor
enum SnapshotMenuBarScanCheck {
    static func run() -> (cases: Int, problems: [String]) {
        var problems: [String] = []
        var cases = 0
        // 주 화면(노치) 위에 나란히 둔 1920×1080 외부 모니터 두 대 (Cocoa 전역)
        let left = MenuBarScanner.Screen(id: 2, frame: CGRect(x: -188, y: 982, width: 1920, height: 1080), fallbackMenuBarHeight: 24)
        let right = MenuBarScanner.Screen(id: 3, frame: CGRect(x: 1732, y: 982, width: 1920, height: 1080), fallbackMenuBarHeight: 24)
        let builtIn = MenuBarScanner.Screen(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), fallbackMenuBarHeight: 33)
        func menuBar(_ number: Int, on screen: MenuBarScanner.Screen, height: CGFloat) -> WindowSnapshot.Window {
            WindowSnapshot.Window(
                number: number, pid: 300, layer: WindowLevels.mainMenu,
                frame: CGRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height),
                alpha: 1
            )
        }
        let screens = [builtIn, left, right]

        // 오른쪽 화면에만 메뉴바 창 (왼쪽은 메뉴바가 숨음): 왼쪽 화면 높이는 모름
        cases += 1
        var result = MenuBarScanner.scan(WindowSnapshot(windows: [menuBar(1, on: right, height: 30)]), screens: screens, ownPID: 100)
        if result[right.id]?.menuBarHeight != 30 { problems.append("오른쪽 화면 메뉴바 높이를 못 찾음") }
        if let height = result[left.id]?.menuBarHeight { problems.append(String(format: "왼쪽 화면이 옆 화면 메뉴바(%.0f)를 가져옴", height)) }
        if result[builtIn.id]?.menuBarHeight != nil { problems.append("주 화면이 외부 모니터 메뉴바를 가져옴") }

        // 화면마다 제 메뉴바 창
        cases += 1
        result = MenuBarScanner.scan(
            WindowSnapshot(windows: [menuBar(2, on: left, height: 24), menuBar(3, on: right, height: 30), menuBar(4, on: builtIn, height: 33)]),
            screens: screens, ownPID: 100
        )
        if result[left.id]?.menuBarHeight != 24 || result[right.id]?.menuBarHeight != 30 || result[builtIn.id]?.menuBarHeight != 33 {
            problems.append("화면마다 제 메뉴바 높이가 아님")
        }
        return (cases, problems)
    }
}
