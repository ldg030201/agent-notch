import AppKit
import SwiftUI

// MARK: - 색상 (아일랜드는 라이트/다크 공통으로 항상 검정 배경)

enum Palette {
    /// 아일랜드 검은 모양. 하드웨어 노치(꺼진 픽셀)와 이음매 없이 이어지도록 순수 검정
    static let background = Color(hex: 0x000000)
    static let text = Color(hex: 0xF1EFE8)
    static let secondary = Color(hex: 0xB4B2A9)
    static let muted = Color(hex: 0x888780)
    static let green = Color(hex: 0x97C459)
    static let red = Color(hex: 0xF09595)
    static let amber = Color(hex: 0xEF9F27)
    /// 행 배경 / 버튼
    static let row = Color(hex: 0x2C2C2A)
    /// 허용 버튼 글자색 (초록 배경 위)
    static let allowText = Color(hex: 0x173404)
    static let addBackground = Color(.sRGB, red: 99 / 255, green: 153 / 255, blue: 34 / 255, opacity: 0.2)
    static let removeBackground = Color(.sRGB, red: 226 / 255, green: 75 / 255, blue: 74 / 255, opacity: 0.2)
    /// 새 버전 배지 (파랑)
    static let badgeBackground = Color(hex: 0x0C447C)
    static let badgeText = Color(hex: 0xB5D4F4)

    // CALayer 로 그리는 스피너·점용
    static let greenNS = NSColor(hex: 0x97C459)
    static let amberNS = NSColor(hex: 0xEF9F27)
    static let redNS = NSColor(hex: 0xF09595)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - 렌더링 환경

/// 오프스크린 렌더링(스냅숏) 여부와 고정 시각. 실제 패널에서는 기본값을 쓴다.
struct IslandRenderContext: Equatable, Sendable {
    /// true 면 AppKit 기반 뷰(CA 스피너 등) 대신 정지된 SwiftUI 도형을 그린다
    /// (ImageRenderer 는 NSViewRepresentable · ScrollView 를 그리지 못한다)
    var isSnapshot = false
    /// 경과 시간 등에 쓸 고정 시각 (nil 이면 실제 시각)
    var fixedNow: Date?
}

private struct IslandRenderContextKey: EnvironmentKey {
    static let defaultValue = IslandRenderContext()
}

extension EnvironmentValues {
    var islandRenderContext: IslandRenderContext {
        get { self[IslandRenderContextKey.self] }
        set { self[IslandRenderContextKey.self] = newValue }
    }
}

// MARK: - 글꼴

enum IslandFont {
    /// 기본 12pt
    static let body = Font.system(size: 12)
    static let bodyMedium = Font.system(size: 12, weight: .medium)
    /// 보조 11pt
    static let caption = Font.system(size: 11)
    /// 코드/diff 11pt 고정폭
    static let mono = Font.system(size: 11, design: .monospaced)
    /// 세션 상태 요약 숫자 11pt (숫자만 고정폭 — 개수가 바뀌어도 폭이 같게)
    static let summaryCount = Font.system(size: 11).monospacedDigit()

    // 레이아웃 계산(텍스트 줄 수 측정)용 AppKit 글꼴
    static let bodyNS = NSFont.systemFont(ofSize: 12)
    static let monoNS = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let summaryCountNS = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// 고정폭 11pt 한 글자 폭
    static let monoCharWidth: CGFloat = ceil(("M" as NSString).size(withAttributes: [.font: monoNS]).width)
}

// MARK: - 모션

enum IslandMotion {
    /// 모드 종류가 바뀔 때(접힘 ↔ 카드 등)의 모양 전환.
    /// 노치에 딱 맞춘 치수(접힌 높이 = 노치 높이, 카드 목 = 노치 폭)를 넘치지 않게 거의 오버슈트 없는 스프링 (최대 약 0.15%).
    /// 넘쳐도 `IslandShape` 가 노치는 늘 덮는다. 동작 줄이기 설정이면 오버슈트 없는 스프링
    static func resize(reduceMotion: Bool) -> Animation {
        reduceMotion ? adjustSpring : .spring(response: resizeResponse, dampingFraction: resizeDamping)
    }

    static let resizeResponse = 0.4
    static let resizeDamping = 0.9

    /// 같은 종류 안의 크기 변화(접힌 폭 · 비켜주기 · 피크 높이 등): 출렁이지 않게 임계 감쇠
    static func adjust(reduceMotion: Bool) -> Animation { adjustSpring }
    private static let adjustSpring = Animation.spring(response: adjustResponse, dampingFraction: 1.0)
    static let adjustResponse = 0.32

    /// 크기 변경 후 내용이 다시 나타나기까지의 지연 (모양이 약 90% 자리 잡은 시점)
    static let contentDelay: Duration = .milliseconds(220)
    /// 같은 모드 안에서 내용 구조만 바뀔 때(왼쪽 날개 ↔ 노치 아래 띠 등)의 지연.
    /// 프레임이 크게(200pt 가까이) 옮겨 가므로 모양이 99% 자리 잡은 뒤 나타나야 새 내용이 미끄러져 들어오지 않는다
    static let branchContentDelay: Duration = .milliseconds(340)
    /// 크기 · 위치가 바뀐 뒤 모양이 다 자리 잡았다고 보는 시간 (두 스프링 모두 99.8% 이상). 그 전엔 호버 확대를 시작하지 않는다
    static let settleDelay: Duration = .milliseconds(450)
    static let contentFadeIn = Animation.easeOut(duration: 0.18)
    static let contentFadeOut = Animation.easeOut(duration: 0.1)
    static let hover = Animation.easeOut(duration: 0.15)
}
