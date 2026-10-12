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
    @MainActor
    public static var scenarios: [String] { SnapshotScenario.allCases.map(\.rawValue) }

    /// 장면 하나를 PNG 로 저장한다. 배경은 메뉴바 일부를 흉내 낸 밝은 띠 위에 아일랜드를 올린 모양.
    @MainActor
    public static func renderPNG(scenario: String, style: Style, to url: URL) throws {
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
    case working
    case workingWings = "working-wings"
    case workingWingsIcons = "working-wings-icons"
    case workingWingsRetracted = "working-wings-retracted"
    case workingWingsIconsStrip = "working-wings-icons-strip"
    case workingRightWing = "working-right-wing"
    case workingBelowNotch = "working-below-notch"
    case workingMinimal = "working-minimal"
    case peek
    case permission
    case permissionClipped = "permission-clipped"
    case permissionScope = "permission-scope"
    case permissionCollapsed = "permission-collapsed"
    case needsInput = "needs-input"
    case done
    case failed
    case expanded
    case expandedUpdate = "expanded-update"
    case menubarWorking = "menubar-working"
    case menubarDot = "menubar-dot"
    case menubarPermission = "menubar-permission"
    case settings
    case settingsVersion = "settings-version"

    /// 메뉴바 안 알약 장면은 style 과 관계없이 노치 없는 화면으로 그린다
    var forcesMenuBar: Bool {
        switch self {
        case .menubarWorking, .menubarDot, .menubarPermission: return true
        default: return false
        }
    }

    var isSettings: Bool { self == .settings || self == .settingsVersion }

    /// 노치 화면 표시 방식. 노치 아래 장면만 명시하고 나머지는 기본값(넓은 노치)
    var notchStyle: NotchStyle {
        switch self {
        case .workingBelowNotch, .workingMinimal: return .belowNotch
        default: return .wings
        }
    }

    /// 메뉴바 배치 (메뉴 · 상태 아이콘이 차지하는 자리)
    var crowding: SnapshotMenuBar.Crowding {
        switch self {
        case .workingRightWing: return .leftBlocked
        case .workingBelowNotch, .workingMinimal: return .bothBlocked
        case .idleWings, .workingWings, .workingWingsIcons, .workingWingsRetracted: return .iconsToNotch
        case .workingWingsIconsStrip: return .menusAndIconsToNotch
        case .menubarDot: return .narrowGap
        default: return .roomy
        }
    }

    /// 손쉬운 사용으로 메뉴바 아이콘 위치를 잰 상태 (넓은 노치가 아이콘 구멍을 뚫음)
    var measuresMenuBarItems: Bool { self == .workingWingsIcons || self == .workingWingsIconsStrip }
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
        /// 노치 없는 화면: 앱 메뉴와 상태 아이콘 사이가 좁음
        case narrowGap
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

    @MainActor
    init(style: IslandSnapshotRenderer.Style, crowding: Crowding, measuresItems: Bool = false) {
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
        case .roomy, .iconsToNotch:
            menus = Self.layoutMenus(shortMenus, limit: .greatestFiniteMagnitude)
        case .leftBlocked, .bothBlocked, .menusAndIconsToNotch:
            menus = Self.layoutMenus(longMenus, limit: notchMinX - 6)
        case .narrowGap:
            menus = Self.layoutMenus(longMenus, limit: width * 0.46)
        }
        menuItems = menus
        let appMenuEnd = menus.last.map { $0.x + Self.textWidth($0.text, bold: $0.bold) } ?? 40

        // 상태 아이콘 시작 위치
        let statusStart: CGFloat
        switch crowding {
        case .roomy: statusStart = hasNotch ? 760 : 800
        case .leftBlocked: statusStart = notchMaxX + 210
        case .bothBlocked: statusStart = notchMaxX + 38
        case .iconsToNotch, .menusAndIconsToNotch: statusStart = notchMaxX + 8
        case .narrowGap: statusStart = appMenuEnd + 92
        }
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
private struct SnapshotMenuBarStrip: View {
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

@MainActor
enum SnapshotStage {
    static func render(_ scene: SnapshotScenario, style: IslandSnapshotRenderer.Style) throws -> CGImage {
        var world = SnapshotWorld()
        world.startSessions()
        guard let defaults = MemoryDefaults() else {
            throw IslandSnapshotRenderer.RenderError.renderFailed("설정 저장소를 만들 수 없음")
        }
        let preferences = AppPreferences(defaults: defaults)
        preferences.notchStyle = scene.notchStyle
        let presentation = PresentationController(store: world.store, preferences: preferences, actions: SnapshotActions())

        if scene.isSettings {
            return try renderSettings(scene, world: world, preferences: preferences, presentation: presentation)
        }

        let style: IslandSnapshotRenderer.Style = scene.forcesMenuBar ? .menuBar : style
        let bar = SnapshotMenuBar(style: style, crowding: scene.crowding, measuresItems: scene.measuresMenuBarItems)
        let screenID = bar.geometry.screenID
        presentation.updateScreens([bar.geometry])
        presentation.setActiveScreen(screenID)
        presentation.setSpaces([screenID: bar.space])

        let api = SnapshotWorld.apiServer.id
        switch scene {
        case .idle, .idleWings:
            break
        case .working, .workingWings, .workingWingsIcons, .workingWingsIconsStrip, .workingRightWing, .workingBelowNotch, .menubarWorking, .menubarDot:
            world.apiServerEdits()
            world.apiServerRunsTests()
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
            if let diff = world.apiServerEdits() {
                presentation.setTransientForSnapshot(.peek(sessionID: api, diff: diff))
            }
        case .permission, .menubarPermission:
            world.apiServerEdits()
            world.apiServerRunsTests()
            world.webAppAsksPermission()
        case .permissionClipped:
            world.apiServerEdits()
            world.apiServerRunsTests()
            world.webAppAsksClippedPermission()
        case .permissionScope:
            world.apiServerEdits()
            world.apiServerRunsTests()
            world.webAppAsksScopedPermission()
        case .permissionCollapsed:
            world.apiServerEdits()
            world.apiServerRunsTests()
            world.webAppAsksPermission()
            if let request = world.store.pendingPermissions.first {
                presentation.minimize(request)
            }
        case .needsInput:
            world.apiServerEdits()
            world.apiServerRunsTests()
            world.blogAsksQuestion()
            presentation.handleLatestSignal()
        case .done:
            world.apiServerEdits()
            world.apiServerCompletes()
            presentation.setTransientForSnapshot(.done(sessionID: api))
        case .failed:
            world.webAppFails()
            presentation.setTransientForSnapshot(.failed(sessionID: SnapshotWorld.webApp.id))
        case .expanded, .expandedUpdate:
            world.apiServerEdits()
            world.apiServerRunsTests()
            world.store.togglePin(sessionID: api)
            if scene == .expandedUpdate {
                presentation.updateProvider = SnapshotUpdateProvider(now: world.clock.now)
            }
            presentation.toggleExpanded(on: screenID)
        case .settings, .settingsVersion:
            break
        }

        let canvas = SnapshotIslandCanvas(bar: bar, presentation: presentation)
            .environment(\.islandRenderContext, IslandRenderContext(isSnapshot: true, fixedNow: world.clock.now))
            .environment(\.colorScheme, .light)
        return try image(of: canvas, size: CGSize(width: bar.geometry.frame.width, height: bar.canvasHeight))
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

    /// ImageRenderer(2배율)로 그린다. 시스템 컨트롤도 늘 같은 모습이 되도록 밝은 모양새로 고정한다.
    private static func image<Content: View>(of view: Content, size: CGSize) throws -> CGImage {
        var result: CGImage?
        let draw = {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
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
