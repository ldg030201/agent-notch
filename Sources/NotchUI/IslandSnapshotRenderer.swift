import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import NotchCore

/// 아일랜드 화면을 PNG 로 그려내는 진입점 (CI 검증, README 스크린샷, 개발 중 확인용).
/// 화면 기록 권한 없이 뷰를 오프스크린으로 렌더링한다. 가짜 데이터만 사용한다.
///
/// NOTE: 공개 시그니처는 App(`--render-island`)이 의존하는 계약이므로 변경하지 않는다.
public enum IslandSnapshotRenderer {
    public enum Style: String, CaseIterable, Sendable {
        /// 노치 화면 (노치에 붙는 모양)
        case notch
        /// 노치 없는 화면 (메뉴바 안 알약)
        case menuBar
    }

    public enum RenderError: Error, LocalizedError {
        case unknownScenario(String)
        case renderFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unknownScenario(let name): return "알 수 없는 장면: \(name)"
            case .renderFailed(let reason): return "렌더링 실패: \(reason)"
            }
        }
    }

    /// 렌더링할 수 있는 장면 이름 (예: idle, working, peek, permission, needsInput, done, failed, expanded, …)
    /// `anim-<전>-<후>` 는 전환 애니메이션을 프레임별로 늘어놓은 시트 (`SnapshotTransition`)
    @MainActor
    public static var scenarios: [String] {
        SnapshotScenario.allCases.map(\.rawValue) + SnapshotTransition.all.map(\.name)
    }

    /// 장면 하나를 PNG 로 저장한다. 배경은 메뉴바 일부를 흉내 낸 밝은 띠 위에 아일랜드를 올린 모양.
    @MainActor
    public static func renderPNG(scenario: String, style: Style, to url: URL) throws {
        if let transition = SnapshotTransition.named(scenario) {
            let image = try SnapshotAnimationSheet.render(transition, style: style)
            try write(image, to: url)
            return
        }
        guard let scene = SnapshotScenario(rawValue: scenario) else {
            throw RenderError.unknownScenario(scenario)
        }
        let image = try SnapshotStage.render(scene, style: style)
        try write(image, to: url)
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.renderFailed("PNG 파일을 만들 수 없음")
        }
        // 2배율로 그렸으니 144 DPI 로 기록해 미리보기에서 pt 크기로 보이게 한다
        let properties = [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw RenderError.renderFailed("PNG 저장 실패")
        }
    }
}

// MARK: - 장면

enum SnapshotScenario: String, CaseIterable {
    case idle
    case idleWings = "idle-wings"
    /// 쉬는 세션 5개: 모든 세션 요약 ("● 5")
    case idleSummary = "idle-summary"
    case working
    case workingWings = "working-wings"
    case workingWingsIcons = "working-wings-icons"
    case workingWingsRetracted = "working-wings-retracted"
    case workingWingsIconsStrip = "working-wings-icons-strip"
    /// 넓은 노치 + 아이콘 구멍, 노치 오른쪽 첫 아이콘이 110pt 남짓 떨어진 화면 (카드 목이 아이콘 앞에서 멈춤)
    case workingWingsIconsNear = "working-wings-icons-near"
    case workingRightWing = "working-right-wing"
    case workingBelowNotch = "working-below-notch"
    /// 노치 아래 방식 + 오른쪽은 상태 아이콘이 노치까지, 왼쪽은 빈 메뉴바 (왼쪽 한쪽 날개)
    case workingBelowNotchLeft = "working-below-notch-left"
    /// `working-below-notch-left` 에서 앞 앱 메뉴만 노치까지 길어진 화면 (왼쪽 날개도 못 써서 노치 아래 띠)
    case workingBelowNotchStrip = "working-below-notch-strip"
    /// 노치 아래 방식 + 노치 왼쪽 빈 곳이 64pt 뿐인 화면: 쉬는 중 요약은 왼쪽 날개, 세션 내용은 노치 아래 띠
    case workingBelowNotchNarrow = "working-below-notch-narrow"
    case workingMinimal = "working-minimal"
    /// 작업 중 + 백그라운드 셸 1 · 서브에이전트 2 (접힌 상태 끝에 배지 "⧉ 3")
    case workingBackground = "working-background"
    /// `working-background` 를 노치 아래 띠로 (양옆이 막힌 메뉴바)
    case workingBackgroundStrip = "working-background-strip"
    /// 세션 5개: 접힌 상태가 보여주는 세션(권한 대기, 카드 접음) 말고 기다리는 중 1 · 진행 중 1 · 끝남 2 요약
    case workingSummary = "working-summary"
    /// `working-summary` 를 노치 아래 띠로 (양옆이 막힌 메뉴바)
    case workingSummaryStrip = "working-summary-strip"
    case peek
    case permission
    case permissionClipped = "permission-clipped"
    case permissionScope = "permission-scope"
    case permissionCollapsed = "permission-collapsed"
    case needsInput = "needs-input"
    /// `needs-input` 인데 질문한 세션이 Claude 데스크톱 앱에서 돌아감 (버튼이 "Claude로")
    case needsInputDesktop = "needs-input-desktop"
    /// Claude 데스크톱 앱 세션의 권한 요청을 "Claude로" 넘긴 뒤: 훅 대기 없이 앱에서 승인을 기다림 (문구 · 버튼이 Claude 앱)
    case permissionHandoffDesktop = "permission-handoff-desktop"
    /// 노치에서 답하는 질문: 한 개 고르기 (선택지 설명 있음)
    case question
    /// 여러 개 고르는 질문 (둘 고름)
    case questionMulti = "question-multi"
    /// 질문 두 개 (1/2 쪽, 첫 질문 답 고름)
    case questionPages = "question-pages"
    /// "기타" 에 직접 쓴 답
    case questionOther = "question-other"
    /// 계획 승인 (ExitPlanMode)
    case plan
    case done
    case failed
    case expanded
    case expandedUpdate = "expanded-update"
    /// `working-summary` 를 펼친 모습: 머리에 "세션 5" + 모든 세션 요약
    case expandedSummary = "expanded-summary"
    /// `working-background` 를 펼친 모습: 세션 줄에 배지, 상세 머리에 "⧉ 3 서브에이전트 2 · 셸 1"
    case expandedBackground = "expanded-background"
    /// `failed` 세션을 펼친 모습: 상세 머리 경과 시간이 흐르지 않고 "실패 · 소요 시간"
    case expandedFailed = "expanded-failed"
    case menubarWorking = "menubar-working"
    /// 제목이 긴 MCP 툴 실행 중 (수정 없음), 빈 곳이 화면 가운데에서 오른쪽으로 치우친 메뉴바 (가운데에 두면 좁아 빈 곳 안으로 밀어 놓음)
    case menubarWorkingLongTool = "menubar-working-long-tool"
    /// `menubar-working-long-tool` 을 빈 곳이 좁은 메뉴바에 (제목을 줄여서라도 넣음)
    case menubarWorkingTight = "menubar-working-tight"
    /// `working-background` 를 메뉴바 안 알약으로
    case menubarBackground = "menubar-background"
    case menubarDot = "menubar-dot"
    case menubarPermission = "menubar-permission"
    /// 메뉴바 알약 아래로 펼친 질문 카드
    case menubarQuestion = "menubar-question"
    /// 외부 모니터 "메뉴바 아래" 방식: 메뉴바 아래 알약 · 그 아래로 펼친 카드
    case menubarBelowWorking = "menubar-below-working"
    case menubarBelowPermission = "menubar-below-permission"
    case settings
    case settingsVersion = "settings-version"

    /// 메뉴바 안 알약 장면은 style 과 관계없이 노치 없는 화면으로 그린다
    var forcesMenuBar: Bool {
        switch self {
        case .menubarWorking, .menubarWorkingLongTool, .menubarWorkingTight, .menubarBackground, .menubarDot, .menubarPermission,
             .menubarQuestion, .menubarBelowWorking, .menubarBelowPermission: return true
        default: return false
        }
    }

    var isSettings: Bool { self == .settings || self == .settingsVersion }

    /// 노치 없는 화면 표시 방식 (메뉴바 아래 장면만 명시하고 나머지는 기본값: 메뉴바 안)
    var externalStyle: ExternalDisplayStyle {
        self == .menubarBelowWorking || self == .menubarBelowPermission ? .belowMenuBar : .inMenuBar
    }

    /// 노치 화면 표시 방식. 노치 아래 장면만 명시하고 나머지는 기본값(넓은 노치)
    var notchStyle: NotchStyle {
        switch self {
        case .workingBelowNotch, .workingBelowNotchLeft, .workingBelowNotchStrip, .workingBelowNotchNarrow, .workingMinimal, .workingSummaryStrip,
             .workingBackgroundStrip:
            return .belowNotch
        default: return .wings
        }
    }

    /// 메뉴바 배치 (메뉴 · 상태 아이콘이 차지하는 자리)
    var crowding: SnapshotMenuBar.Crowding {
        switch self {
        case .workingRightWing: return .leftBlocked
        case .workingBelowNotch, .workingMinimal, .workingSummaryStrip, .workingBackgroundStrip: return .bothBlocked
        case .idleWings, .workingWings, .workingWingsIcons, .workingWingsRetracted, .workingBelowNotchLeft: return .iconsToNotch
        case .workingWingsIconsStrip, .workingBelowNotchStrip: return .menusAndIconsToNotch
        case .workingWingsIconsNear: return .iconsNearNotch
        case .workingBelowNotchNarrow: return .narrowLeftRoom
        case .menubarDot: return .narrowGap
        case .menubarWorkingLongTool: return .offCenterGap
        case .menubarWorkingTight: return .tightGap
        default: return .roomy
        }
    }

    /// 손쉬운 사용으로 메뉴바 아이콘 위치를 잰 상태 (넓은 노치가 아이콘 구멍을 뚫음)
    var measuresMenuBarItems: Bool {
        self == .workingWingsIcons || self == .workingWingsIconsStrip || self == .workingWingsIconsNear
    }
}

// MARK: - 가짜 메뉴바

/// 스냅숏 배경 메뉴바: 화면 정보 · 측정값 · 그릴 메뉴/아이콘 위치가 서로 맞도록 한곳에서 만든다
struct SnapshotMenuBar {
    enum Crowding {
        /// 양옆이 넉넉함
        case roomy
        /// 앱 메뉴가 노치 왼쪽을 채움
        case leftBlocked
        /// 왼쪽은 앱 메뉴, 오른쪽은 상태 아이콘이 노치 바로 옆까지 (오른쪽 빈 곳 약 30pt)
        case bothBlocked
        /// 앱 메뉴는 짧고, 상태 아이콘이 노치 바로 옆부터 꽉 참 (넓은 노치가 아이콘을 덮는 모습)
        case iconsToNotch
        /// 앱 메뉴와 상태 아이콘이 모두 노치 바로 옆까지 (넓은 노치 내용이 노치 아래 띠로)
        case menusAndIconsToNotch
        /// 앱 메뉴는 짧고, 상태 아이콘이 노치 오른쪽 118pt 부터 (카드 목이 아이콘 앞에서 멈추는 폭)
        case iconsNearNotch
        /// 앱 메뉴가 노치 왼쪽 64pt(+ 여백 8) 앞까지, 상태 아이콘은 노치 바로 옆부터 (작은 내용만 왼쪽 날개에 들어감)
        case narrowLeftRoom
        /// 노치 없는 화면: 앱 메뉴와 상태 아이콘 사이가 좁음 (알약 대신 점)
        case narrowGap
        /// 노치 없는 화면: 앱 메뉴가 화면 가운데 가까이까지 길고 빈 곳(약 296pt)이 오른쪽으로 치우침.
        /// 화면 가운데에 두면 알약이 좁다 (손쉬운 사용 없이 외부 모니터에서 추정한 빈 곳과 같은 모양)
        case offCenterGap
        /// 노치 없는 화면: 빈 곳이 알약 하나 겨우 들어갈 만큼(약 140pt)
        case tightGap
    }

    struct MenuItem {
        var text: String
        var x: CGFloat
        var bold: Bool
    }

    static let menuFont = NSFont.systemFont(ofSize: 13)
    static let menuBoldFont = NSFont.boldSystemFont(ofSize: 13)
    static let clockText = "1월 15일 (목) 오전 10:44"
    static let iconSize = CGSize(width: 16, height: 14)
    static let iconStep: CGFloat = 28
    /// `narrowLeftRoom` 의 노치 왼쪽 빈 곳 (여백 제외)
    static let narrowLeftRoom: CGFloat = 64
    /// 아이콘 사각형(손쉬운 사용으로 읽히는 크기) 좌우 여백
    static let iconItemPadding: CGFloat = 6
    /// 가짜 상태 아이콘 (SF Symbols)
    static let iconSymbols = [
        "wifi", "battery.75percent", "magnifyingglass", "switch.2", "speaker.wave.2.fill",
        "moon.fill", "airplayaudio", "keyboard", "cloud.fill", "bell.fill",
    ]

    let geometry: NotchGeometry
    let space: MenuBarSpace
    let menuItems: [MenuItem]
    let statusIconXs: [CGFloat]
    let clockX: CGFloat
    /// 카드가 펼쳐질 자리까지 포함한 그림 높이
    let canvasHeight: CGFloat

    /// - iconShift: 상태 아이콘 전체를 옮긴다 (폭이 바뀌는 메뉴바 아이템 때문에 노치 옆 아이콘이 밀리는 상황 재현)
    @MainActor
    init(style: IslandSnapshotRenderer.Style, crowding: Crowding, measuresItems: Bool = false, iconShift: CGFloat = 0) {
        let hasNotch = style == .notch
        let width: CGFloat = hasNotch ? 1000 : 1100
        let menuBarHeight: CGFloat = hasNotch ? 33 : 24
        let notchSize = hasNotch ? CGSize(width: 185, height: 32) : .zero
        let height = menuBarHeight + 360
        geometry = NotchGeometry(
            screenID: 1,
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            hasNotch: hasNotch,
            notchSize: notchSize,
            isBuiltIn: hasNotch,
            menuBarHeight: menuBarHeight
        )
        canvasHeight = height

        let notchMinX = (width - notchSize.width) / 2
        let notchMaxX = notchMinX + notchSize.width

        // 앱 메뉴: 넉넉하면 짧게, 막힌 장면이면 노치(또는 지정 위치) 바로 앞까지
        let shortMenus = ["터미널", "셸", "편집", "보기"]
        let longMenus = ["Xcode", "파일", "편집", "보기", "찾기", "탐색", "편집기", "제품", "디버그", "소스 제어", "윈도우", "도움말"]
        let menus: [MenuItem]
        switch crowding {
        case .roomy, .iconsToNotch, .iconsNearNotch:
            menus = Self.layoutMenus(shortMenus, limit: .greatestFiniteMagnitude)
        case .leftBlocked, .bothBlocked, .menusAndIconsToNotch:
            menus = Self.layoutMenus(longMenus, limit: notchMinX - 6)
        case .narrowLeftRoom:
            menus = Self.layoutMenus(longMenus, limit: notchMinX - Self.narrowLeftRoom - IslandMetrics.menuBarMargin)
        case .narrowGap, .offCenterGap, .tightGap:
            menus = Self.layoutMenus(longMenus, limit: width * 0.46)
        }
        menuItems = menus
        var appMenuEnd = menus.last.map { $0.x + Self.textWidth($0.text, bold: $0.bold) } ?? 40
        // 손쉬운 사용이 재는 앱 메뉴 끝 (마지막 메뉴 뒤 여백까지): 노치 왼쪽 빈 곳이 정확히 `narrowLeftRoom`
        if crowding == .narrowLeftRoom { appMenuEnd = notchMinX - Self.narrowLeftRoom - IslandMetrics.menuBarMargin }

        // 상태 아이콘 시작 위치
        var statusStart: CGFloat
        switch crowding {
        case .roomy: statusStart = hasNotch ? 760 : 800
        case .leftBlocked: statusStart = notchMaxX + 210
        case .bothBlocked: statusStart = notchMaxX + 38
        case .iconsToNotch, .menusAndIconsToNotch, .narrowLeftRoom: statusStart = notchMaxX + 8
        case .iconsNearNotch: statusStart = notchMaxX + 118
        case .narrowGap: statusStart = appMenuEnd + 92
        case .offCenterGap: statusStart = appMenuEnd + 296
        case .tightGap: statusStart = appMenuEnd + 140
        }
        statusStart += iconShift
        clockX = width - 12 - Self.textWidth(Self.clockText, bold: false)
        var icons: [CGFloat] = []
        var x = statusStart
        while x + Self.iconSize.width <= clockX - 12 {
            icons.append(x)
            x += Self.iconStep
        }
        statusIconXs = icons

        // 손쉬운 사용이 돌려주는 아이템 사각형: 아이콘 좌우 여백 포함, 메뉴바 높이 전체
        let itemFrames = icons.map {
            CGRect(x: $0 - Self.iconItemPadding, y: 0, width: Self.iconSize.width + Self.iconItemPadding * 2, height: menuBarHeight)
        }
        space = MenuBarSpace(
            menuBarVisible: true,
            menuBarHeight: menuBarHeight,
            appMenuEnd: appMenuEnd,
            appMenuMeasured: true,
            statusStart: statusStart,
            statusMeasured: true,
            itemFrames: measuresItems ? itemFrames : [],
            itemsMeasured: measuresItems
        )
    }

    private static func layoutMenus(_ titles: [String], limit: CGFloat) -> [MenuItem] {
        var items: [MenuItem] = []
        var x: CGFloat = 14 + 16 + 18 // 왼쪽 여백 + 사과 로고 + 간격
        for (index, title) in titles.enumerated() {
            let bold = index == 0
            let width = textWidth(title, bold: bold)
            guard x + width <= limit else { break }
            items.append(MenuItem(text: title, x: x, bold: bold))
            x += width + 18
        }
        return items
    }

    static func textWidth(_ text: String, bold: Bool) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: bold ? menuBoldFont : menuFont]).width)
    }
}

/// 밝은 메뉴바 띠 (앱 메뉴 글자 · 회색 상태 아이콘 · 시계)
struct SnapshotMenuBarStrip: View {
    let bar: SnapshotMenuBar

    var body: some View {
        let height = bar.geometry.menuBarHeight
        let text = Color(hex: 0x1D1D1F)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color(hex: 0xF4F3EF))
                .frame(height: height)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.black.opacity(0.1)).frame(height: 0.5)
                }

            Image(systemName: "apple.logo")
                .font(.system(size: 14))
                .foregroundStyle(text)
                .frame(width: 16, height: height)
                .offset(x: 14)

            ForEach(Array(bar.menuItems.enumerated()), id: \.offset) { _, item in
                Text(item.text)
                    .font(.system(size: 13, weight: item.bold ? .bold : .regular))
                    .foregroundStyle(text)
                    .fixedSize()
                    .frame(height: height)
                    .offset(x: item.x)
            }

            ForEach(Array(bar.statusIconXs.enumerated()), id: \.offset) { index, x in
                let symbols = SnapshotMenuBar.iconSymbols
                Image(systemName: symbols[index % symbols.count])
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(text)
                    .frame(width: SnapshotMenuBar.iconSize.width, height: height)
                    .offset(x: x)
            }

            Text(SnapshotMenuBar.clockText)
                .font(.system(size: 13))
                .foregroundStyle(text)
                .fixedSize()
                .frame(height: height)
                .offset(x: bar.clockX)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// 메뉴바 + 아일랜드 + (노치) 를 한 장에 그린다. 아일랜드는 실제 패널과 같은 뷰(IslandRootView)를 쓴다.
private struct SnapshotIslandCanvas: View {
    let bar: SnapshotMenuBar
    let presentation: PresentationController

    var body: some View {
        let geometry = bar.geometry
        ZStack(alignment: .topLeading) {
            Color(hex: 0xDAD8D1)
            SnapshotMenuBarStrip(bar: bar)
            IslandRootView(screenID: geometry.screenID, presentation: presentation, viewState: IslandViewState())
            if geometry.hasNotch {
                // 하드웨어 노치 (카메라 자리) — 아일랜드 내용이 이 아래로 들어가지 않는지 확인용으로 맨 위에 그린다
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                    .fill(Palette.background)
                    .frame(width: geometry.notchSize.width, height: geometry.notchSize.height)
                    .offset(x: (geometry.frame.width - geometry.notchSize.width) / 2)
            }
        }
        .frame(width: geometry.frame.width, height: bar.canvasHeight, alignment: .topLeading)
    }
}

// MARK: - 렌더링

/// 장면 하나를 그릴 준비가 끝난 상태 (가짜 메뉴바 · 표시 상태 · 가짜 데이터)
@MainActor
struct SnapshotSetup {
    let bar: SnapshotMenuBar
    let presentation: PresentationController
    let world: SnapshotWorld

    var screenID: ScreenID { bar.geometry.screenID }
    var mode: IslandMode { presentation.mode(for: screenID) }
    var layout: IslandLayout { presentation.layout(for: screenID, mode: mode) }
}

@MainActor
enum SnapshotStage {
    static func render(_ scene: SnapshotScenario, style: IslandSnapshotRenderer.Style) throws -> CGImage {
        if scene.isSettings {
            var world = SnapshotWorld()
            world.startSessions()
            let preferences = try makePreferences(notchStyle: scene.notchStyle)
            let presentation = PresentationController(store: world.store, preferences: preferences, actions: SnapshotActions())
            return try renderSettings(scene, world: world, preferences: preferences, presentation: presentation)
        }
        let setup = try prepare(scene, style: style)
        // 정지 장면도 이음매 검사 (목 ↔ 몸통 끊김 · 물림 · 거의 겹친 이음매)
        let seam = SnapshotSeamCheck.check(layout: setup.layout)
        print("== \(scene.rawValue) (\(style.rawValue)): 이음매 검사: 위반 \(seam.count)"
            + seam.map { "\n   ✗ \($0)" }.joined())
        let canvas = SnapshotIslandCanvas(bar: setup.bar, presentation: setup.presentation)
            .environment(\.islandRenderContext, IslandRenderContext(isSnapshot: true, fixedNow: setup.world.clock.now))
            .environment(\.colorScheme, .light)
        return try image(of: canvas, size: CGSize(width: setup.bar.geometry.frame.width, height: setup.bar.canvasHeight))
    }

    private static func makePreferences(notchStyle: NotchStyle) throws -> AppPreferences {
        guard let defaults = MemoryDefaults() else {
            throw IslandSnapshotRenderer.RenderError.renderFailed("설정 저장소를 만들 수 없음")
        }
        let preferences = AppPreferences(defaults: defaults)
        preferences.notchStyle = notchStyle
        return preferences
    }

    /// 장면의 가짜 데이터 · 표시 상태를 만든다.
    /// - environment: 메뉴바 배치 · 노치 표시 방식을 가져올 장면 (전환 시트에서 두 상태가 같은 화면을 쓰게). nil 이면 `scene` 자신
    /// - iconShift: 상태 아이콘을 옮길 거리 (`SnapshotMenuBar`)
    static func prepare(
        _ scene: SnapshotScenario,
        style: IslandSnapshotRenderer.Style,
        environment: SnapshotScenario? = nil,
        iconShift: CGFloat = 0
    ) throws -> SnapshotSetup {
        let env = environment ?? scene
        var world = SnapshotWorld()
        world.startSessions()
        let preferences = try makePreferences(notchStyle: env.notchStyle)
        if env == .workingMinimal { preferences.compactOverlapStyle = .minimal }
        preferences.externalDisplayStyle = env.externalStyle
        let presentation = PresentationController(store: world.store, preferences: preferences, actions: SnapshotActions())

        let style: IslandSnapshotRenderer.Style = env.forcesMenuBar || scene.forcesMenuBar ? .menuBar : style
        let bar = SnapshotMenuBar(style: style, crowding: env.crowding, measuresItems: env.measuresMenuBarItems, iconShift: iconShift)
        let screenID = bar.geometry.screenID
        presentation.updateScreens([bar.geometry])
        presentation.setActiveScreen(screenID)
        presentation.setSpaces([screenID: bar.space])

        let api = SnapshotWorld.apiServer.id
        /// 카드를 열기 전 접힌 상태를 한 번 그린다 (실제 앱처럼 카드 띠 · 알약이 직전 접힌 모양을 이어받게)
        func showCompact() {
            _ = presentation.layout(for: screenID, mode: presentation.mode(for: screenID))
        }
        switch scene {
        case .idle, .idleWings:
            break
        case .idleSummary:
            world.startMoreSessions()
        case .workingSummary, .workingSummaryStrip, .expandedSummary:
            // api-server 작업 중 · web-app 권한 대기 · blog 입력 대기 · docs-site / mobile-app 쉬는 중.
            // 기다리는 세션이 있으면 늘 그 세션이 포커스라 접힌 상태는 web-app 을 보여주고(두 알림은 접어 둠), 나머지를 요약한다
            world.startMoreSessions()
            world.apiServerEdits()
            world.apiServerRunsTests()
            world.webAppAsksPermission()
            world.blogAsksQuestion()
            presentation.handleLatestSignal()
            if let request = world.store.pendingPermissions.first {
                presentation.minimize(request)
            }
            if case .needsInput = presentation.mode(for: screenID) {
                presentation.collapse(on: screenID)
            }
            if scene == .expandedSummary {
                showCompact()
                presentation.toggleExpanded(on: screenID)
            }
        case .working, .workingWings, .workingWingsIcons, .workingWingsIconsStrip, .workingWingsIconsNear, .workingRightWing, .workingBelowNotch,
             .workingBelowNotchLeft, .workingBelowNotchStrip, .workingBelowNotchNarrow, .menubarWorking, .menubarDot, .menubarBelowWorking:
            world.apiServerEdits()
            world.apiServerRunsTests()
        case .menubarWorkingLongTool, .menubarWorkingTight:
            world.apiServerUsesBrowser()
        case .workingBackground, .workingBackgroundStrip, .menubarBackground, .expandedBackground:
            world.apiServerEdits()
            world.apiServerStartsBackgroundWork()
            world.apiServerRunsTests()
            if scene == .expandedBackground {
                showCompact()
                presentation.toggleExpanded(on: screenID)
            }
        case .workingWingsRetracted:
            // 아이콘 위치를 모를 때: 마우스를 올린 오른쪽 날개가 노치 안으로 들어간 모습
            world.apiServerEdits()
            world.apiServerRunsTests()
            presentation.setRetractedWings(.right, on: screenID)
        case .workingMinimal:
            preferences.compactOverlapStyle = .minimal
            world.apiServerEdits()
            world.apiServerRunsTests()
        case .peek:
            let diff = world.apiServerEdits()
            showCompact()
            if let diff {
                presentation.setTransientForSnapshot(.peek(sessionID: api, diff: diff))
            }
        case .permission, .menubarPermission, .menubarBelowPermission:
            world.apiServerEdits()
            world.apiServerRunsTests()
            showCompact()
            world.webAppAsksPermission()
        case .permissionClipped:
            world.apiServerEdits()
            world.apiServerRunsTests()
            showCompact()
            world.webAppAsksClippedPermission()
        case .permissionScope:
            world.apiServerEdits()
            world.apiServerRunsTests()
            showCompact()
            world.webAppAsksScopedPermission()
        case .permissionCollapsed:
            world.apiServerEdits()
            world.apiServerRunsTests()
            world.webAppAsksPermission()
            if let request = world.store.pendingPermissions.first {
                presentation.minimize(request)
            }
        case .permissionHandoffDesktop:
            world.hostEnvironment[SnapshotWorld.webApp.id] = SnapshotWorld.desktopEnvironment
            world.apiServerEdits()
            world.apiServerRunsTests()
            showCompact()
            world.webAppAsksPermission()
            if let request = world.store.pendingPermissions.first {
                world.store.resolvePermission(id: request.id, decision: .passthrough)
            }
        case .needsInput, .needsInputDesktop:
            if scene == .needsInputDesktop {
                world.hostEnvironment[SnapshotWorld.blog.id] = SnapshotWorld.desktopEnvironment
            }
            world.apiServerEdits()
            world.apiServerRunsTests()
            showCompact()
            world.blogAsksQuestion()
            presentation.handleLatestSignal()
        case .question, .questionMulti, .questionPages, .questionOther, .menubarQuestion:
            world.apiServerEdits()
            world.apiServerRunsTests()
            showCompact()
            switch scene {
            case .questionMulti: world.blogAsksInNotch([SnapshotWorld.deployChecksQuestion])
            case .questionPages: world.blogAsksInNotch([SnapshotWorld.deployTargetQuestion, SnapshotWorld.deployNoticeQuestion])
            default: world.blogAsksInNotch([SnapshotWorld.deployImageQuestion])
            }
            presentation.handleLatestSignal()
            // 고르는 중인 답 (카드 상태만, 보내지 않는다)
            if let request = world.store.pendingPermissions.first, let draft = presentation.questionDraft(for: request) {
                switch scene {
                case .questionMulti:
                    draft.pick(0, question: 0)
                    draft.pick(2, question: 0)
                case .questionPages:
                    draft.pick(1, question: 0)
                case .questionOther:
                    draft.setOtherText("새 이미지만, 썸네일은 그대로", question: 0)
                default:
                    break
                }
            }
        case .plan:
            world.apiServerEdits()
            world.apiServerRunsTests()
            showCompact()
            world.blogAsksPlanApproval()
            presentation.handleLatestSignal()
        case .done:
            world.apiServerEdits()
            showCompact()
            world.apiServerCompletes()
            presentation.setTransientForSnapshot(.done(sessionID: api))
        case .failed:
            world.webAppFails()
            presentation.setTransientForSnapshot(.failed(sessionID: SnapshotWorld.webApp.id))
        case .expandedFailed:
            // 펼쳐 둔 동안 턴이 실패하고(실패 세션이 포커스) 10분이 흘러도 상세 머리는 턴 소요 시간 그대로.
            // (먼저 실패한 뒤 펼치면 펼칠 때 확인 처리돼 유휴가 된다)
            showCompact()
            presentation.toggleExpanded(on: screenID)
            world.webAppFails()
            world.clock.set(1302)
        case .expanded, .expandedUpdate:
            world.apiServerEdits()
            world.apiServerRunsTests()
            world.store.togglePin(sessionID: api)
            if scene == .expandedUpdate {
                presentation.updateProvider = SnapshotUpdateProvider(now: world.clock.now)
            }
            showCompact()
            presentation.toggleExpanded(on: screenID)
        case .settings, .settingsVersion:
            break
        }
        return SnapshotSetup(bar: bar, presentation: presentation, world: world)
    }

    private static func renderSettings(
        _ scene: SnapshotScenario,
        world: SnapshotWorld,
        preferences: AppPreferences,
        presentation: PresentationController
    ) throws -> CGImage {
        let now = world.clock.now
        let model = SettingsModel(provider: SnapshotSettingsProvider(), accessibilityCheck: { false }, now: { now })
        model.refresh()
        model.updateProvider = SnapshotUpdateProvider(now: now)
        if scene == .settings {
            model.selectedSection = .display
            presentation.setNotchConflicts([1: "NotchDemo"])
        } else {
            model.selectedSection = .version
        }
        let size = CGSize(width: 720, height: 700)
        let view = SettingsView(preferences: preferences, model: model, presentation: presentation)
            .frame(width: size.width, height: size.height)
            .environment(\.islandRenderContext, IslandRenderContext(isSnapshot: true, fixedNow: now))
            .environment(\.colorScheme, .light)
        return try image(of: view, size: size)
    }

    /// ImageRenderer(기본 2배율)로 그린다. 시스템 컨트롤도 늘 같은 모습이 되도록 밝은 모양새로 고정한다.
    static func image<Content: View>(of view: Content, size: CGSize, scale: CGFloat = 2) throws -> CGImage {
        var result: CGImage?
        let draw = {
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            renderer.proposedSize = ProposedViewSize(size)
            result = renderer.cgImage
        }
        if let appearance = NSAppearance(named: .aqua) {
            appearance.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }
        guard let result else {
            throw IslandSnapshotRenderer.RenderError.renderFailed("이미지를 만들지 못함")
        }
        return result
    }
}
