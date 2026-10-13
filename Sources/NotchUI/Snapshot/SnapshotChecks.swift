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
