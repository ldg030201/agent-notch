import AppKit
import SwiftUI

// MARK: - 색상 (아일랜드는 라이트/다크 공통으로 항상 검정 배경)

enum Palette {
    static let background = Color(hex: 0x0B0B0B)
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

    // 레이아웃 계산(텍스트 줄 수 측정)용 AppKit 글꼴
    static let bodyNS = NSFont.systemFont(ofSize: 12)
    static let monoNS = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
}

// MARK: - 모션

enum IslandMotion {
    /// 크기 전환. 동작 줄이기 설정이면 오버슈트 없는 스프링
    static func resize(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .spring(response: 0.42, dampingFraction: 1.0)
            : .spring(response: 0.42, dampingFraction: 0.82)
    }

    /// 크기 변경 후 내용이 다시 나타나기까지의 지연
    static let contentDelay: Duration = .milliseconds(160)
    static let contentFadeIn = Animation.easeOut(duration: 0.18)
    static let contentFadeOut = Animation.easeOut(duration: 0.1)
    static let hover = Animation.easeOut(duration: 0.15)
}
