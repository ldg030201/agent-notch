import AppKit
import SwiftUI
import NotchCore
import NotchShared

// 세션 앞에 붙는 에이전트 아이콘.
// - Claude Code: Clawd (Claude Code CLI 시작 화면의 캐릭터). CLI 가 블록 글자 3줄로 그리는 모양을 그대로 픽셀로 옮겼다
// - Codex: Codex 앱 아이콘의 구름 (앱 아이콘에서 구름만 잘라 64px PNG 로 넣었다)
// 두 그림의 저작권 · 상표권은 각각 Anthropic · OpenAI 에 있다 (README "아이콘 저작권").

/// 에이전트 아이콘 (가로 16 × 세로 14 단위). `unit` 1 이면 16×14pt: Clawd 는 1pt 픽셀(16×10), Codex 는 14pt 정사각형
struct AgentIcon: View {
    let agent: AgentKind
    /// 1 이면 16×14pt. 접힌 띠 · 목록 · 카드 모두 1 (Clawd 픽셀이 화면 픽셀에 맞아 또렷하다)
    var unit: CGFloat = 1

    /// 아이콘 칸 크기 (레이아웃 폭 계산 `IslandMetrics.agentIconWidth` 와 같다)
    static func size(unit: CGFloat = 1) -> CGSize {
        CGSize(width: 16 * unit, height: 14 * unit)
    }

    var body: some View {
        let size = Self.size(unit: unit)
        Group {
            switch agent {
            case .claude:
                ClawdIcon(unit: unit)
            case .codex:
                CodexIcon()
                    .frame(width: 14 * unit, height: 14 * unit)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityLabel(agent.displayName)
        .help(agent.displayName)
    }
}

/// Clawd 픽셀 그림. Claude Code CLI 의 블록 글자
/// ```
///  ▐▛███▜▌
/// ▝▜█████▛▘
///   ▘▘ ▝▝
/// ```
/// 를 사분면 블록 하나 = 가로 1 · 세로 2 픽셀로 옮겼다 (글자 칸은 세로가 가로의 두 배). 눈은 칠하지 않은 칸이라 노치의 검정이 보인다
struct ClawdIcon: View {
    var unit: CGFloat = 1

    /// Claude Code 가 Clawd 에 쓰는 주황
    static let color = Color(hex: 0xD77757)
    static let columns = 16
    /// 줄마다 칠하는 열 범위 (위에서부터: 머리 · 눈 · 팔 · 몸 · 다리)
    static let rows: [[ClosedRange<Int>]] = [
        [2...13],
        [2...3, 5...10, 12...13],
        [0...15],
        [2...13],
        [3...3, 5...5, 10...10, 12...12],
    ]

    var body: some View {
        Canvas { context, size in
            let pixel = CGSize(width: unit, height: unit * 2)
            let height = pixel.height * CGFloat(Self.rows.count)
            let origin = CGPoint(
                x: ((size.width - pixel.width * CGFloat(Self.columns)) / 2).rounded(),
                y: ((size.height - height) / 2).rounded()
            )
            var path = Path()
            for (row, runs) in Self.rows.enumerated() {
                for run in runs {
                    path.addRect(CGRect(
                        x: origin.x + CGFloat(run.lowerBound) * pixel.width,
                        y: origin.y + CGFloat(row) * pixel.height,
                        width: CGFloat(run.count) * pixel.width,
                        height: pixel.height
                    ))
                }
            }
            context.fill(path, with: .color(Self.color))
        }
        .frame(width: 16 * unit, height: 14 * unit)
    }
}

/// Codex 구름 (그림 데이터는 `codexMarkPNG`)
struct CodexIcon: View {
    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
        } else {
            // 그림을 못 읽으면(그럴 일은 없다) 같은 색 동그라미
            Circle().fill(Color(hex: 0x5A6CF0))
        }
    }

    @MainActor static let image: NSImage? = Data(base64Encoded: codexMarkPNG.joined()).flatMap(NSImage.init(data:))

    /// Codex 앱 아이콘(icon-codex-light.png)에서 구름만 잘라 투명 배경 64×64 PNG 로 줄인 것 (base64)
    static let codexMarkPNG: [String] = [
        "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",
    ]
}

/// 메뉴바 메뉴 · AppKit 화면에 쓰는 에이전트 아이콘 그림 (16×14pt, 2배율로 한 번 그려 기억한다)
public enum AgentIconImage {
    @MainActor private static var cache: [AgentKind: NSImage] = [:]

    @MainActor
    public static func image(for agent: AgentKind) -> NSImage? {
        if let cached = cache[agent] { return cached }
        let size = AgentIcon.size()
        let renderer = ImageRenderer(content: AgentIcon(agent: agent).frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: size)
        image.accessibilityDescription = agent.displayName
        cache[agent] = image
        return image
    }
}
