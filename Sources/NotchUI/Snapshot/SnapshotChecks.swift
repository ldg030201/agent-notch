import AppKit
import NotchCore

// 전환 시트(`--render-island anim-*`)가 함께 돌리는 순수 계산 검사.
// - 열린 메뉴 · 팝오버 겹침 감지 (`OverlapScanner` · `OverlapMonitor.classify`): 잠깐 뜬 창 · 화면 테두리에 깜빡이지 않는지
// - 다른 세션 상태 요약 자리 (`IslandLayoutEngine`): 개수가 한 자리 안에서 바뀌어도 폭이 같고, 흔한 메뉴바에서 요약이 빠지지 않는지

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
            WindowSnapshot.Window(number: number, pid: pid, layer: layer, frame: frame, alpha: alpha, ownerName: "다른 앱")
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

// MARK: - 다른 세션 상태 요약 자리

@MainActor
enum SnapshotSummaryCheck {
    static func run() -> (cases: Int, problems: [String]) {
        var problems: [String] = []
        var cases = 0

        // 개수가 한 자리 안에서 바뀌면 폭이 같다 (접힌 날개가 출렁이지 않게)
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
        let scenes: [(String, IslandSnapshotRenderer.Style, SnapshotMenuBar.Crowding, Bool, NotchStyle)] = [
            ("넓은 노치 · 넉넉함", .notch, .roomy, false, .wings),
            ("넓은 노치 · 아이콘 구멍", .notch, .iconsToNotch, true, .wings),
            ("넓은 노치 · 아이콘 가까움", .notch, .iconsNearNotch, true, .wings),
            ("노치 아래 · 양옆 막힘", .notch, .bothBlocked, false, .belowNotch),
            ("노치 아래 · 왼쪽 날개", .notch, .iconsToNotch, false, .belowNotch),
            ("메뉴바 알약", .menuBar, .roomy, false, .wings),
        ]
        for (sceneName, style, crowding, measures, notchStyle) in scenes {
            let bar = SnapshotMenuBar(style: style, crowding: crowding, measuresItems: measures)
            let engine = IslandLayoutEngine(
                geometry: bar.geometry, space: bar.space, externalStyle: .inMenuBar,
                notchStyle: notchStyle, overlapStyle: .belowNotch, notchConflict: false
            )
            for (summaryName, summary) in summaries {
                cases += 1
                let metrics = CompactMetrics(
                    project: CompactText.width("api-server", font: IslandFont.bodyNS),
                    shortTool: CompactText.width("Bash", font: IslandFont.bodyNS),
                    fullTool: CompactText.width("Bash npm test", font: IslandFont.bodyNS),
                    trailing: CompactText.statWidth(added: 12, removed: 3),
                    summary: CompactText.summaryWidth(summary),
                    isAttention: false
                )
                let layout = engine.compactLayout(for: .session(metrics))
                let shown: Bool
                switch layout.compact {
                case let .wings(spec): shown = spec.arrangement == .strip || spec.items.contains(.summary)
                case .strip: shown = true
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
/// 손쉬운 사용 권한이 없는 1920pt 외부 모니터 (빈 곳 추정 864…1160, 화면 가운데 960 → 가운데로는 176pt)
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
        func engine(_ style: ExternalDisplayStyle, space: MenuBarSpace = unmeasured, geometry: NotchGeometry = geometry) -> IslandLayoutEngine {
            IslandLayoutEngine(
                geometry: geometry, space: space, externalStyle: style,
                notchStyle: .wings, overlapStyle: .belowNotch, notchConflict: false
            )
        }
        let font = IslandFont.bodyNS
        func metrics(tool: String, project: String = "agent-notch", stat: (Int, Int) = (0, 0), summary: SessionStatusSummary = .empty) -> CompactMetrics {
            CompactMetrics(
                project: CompactText.width(project, font: font),
                shortTool: CompactText.width(String(tool.split(separator: " ").first ?? ""), font: font),
                fullTool: CompactText.width(tool, font: font),
                trailing: CompactText.statWidth(added: stat.0, removed: stat.1),
                summary: CompactText.summaryWidth(summary),
                isAttention: false
            )
        }
        let tools = ["Claude_Browser · computer", "Claude_Browser · browser_batch", "Bash npm run build -- --filter web-app --verbose", "생각 중"]
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

        // 3) 빈 곳이 좁아도 툴 제목 최소 폭이 들어가면 제목을 넣는다 (빈 곳 약 124pt)
        cases += 1
        let tight = engine(.inMenuBar, space: MenuBarSpace(
            menuBarVisible: true, menuBarHeight: 24, appMenuEnd: 880, appMenuMeasured: true, statusStart: 1020, statusMeasured: true
        ))
        if case let .pill(items) = tight.compactLayout(for: .session(metrics(tool: "Claude_Browser · browser_batch"))).compact {
            if !items.contains(.tool), !items.contains(.project) { problems.append("좁은 빈 곳: 제목 없이 상태 아이콘만") }
        } else {
            problems.append("좁은 빈 곳: 알약이 아님")
        }

        // 3-1) 빈 곳 폭을 80…200pt 로 훑기: 줄인 프로젝트명이라도 들어가면 상태 아이콘만 남기지 않는다.
        //      요약이 없으면 툴 제목이 먼저이고, 툴 제목이 줄여도 안 들어갈 때만 프로젝트명. 제목을 넣었으면 알약 안에 들어간다
        for tool in ["Claude_Browser · browser_batch", "Bash npm run build -- --filter web-app --verbose"] {
            for stat in [(0, 0), (12, 3)] {
                for (summaryName, summary) in summaries {
                    cases += 1
                    let sweptMetrics = metrics(tool: tool, project: "api-server", stat: stat, summary: summary)
                    let base: CompactItems = summary.isEmpty ? [] : [.summary]
                    for room in stride(from: CGFloat(80), through: 200, by: 1) {
                        let swept = engine(.inMenuBar, space: MenuBarSpace(
                            menuBarVisible: true, menuBarHeight: 24, appMenuEnd: 880, appMenuMeasured: true,
                            statusStart: 880 + 2 * IslandMetrics.menuBarMargin + room, statusMeasured: true
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
        let content = CompactContent.session(metrics(tool: "Claude_Browser · browser_batch"))
        let compact = inMenuBar.compactPlacement(for: content)
        var opened = inMenuBar
        opened.previousPill = compact
        if opened.cardPill(for: compact) != compact { problems.append("펼친 카드 목 알약이 접힌 알약과 다름") }
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
                alpha: 1, ownerName: "Window Server"
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
