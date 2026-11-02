// 앱 아이콘 그림. scripts/make-icon.sh 가 이 파일을 컴파일해 크기별 PNG 를 뽑고 .icns 로 묶는다.
//
//   swiftc -o /tmp/app-icon scripts/AppIcon.swift && /tmp/app-icon <폴더>
//   → <폴더>/16.png … 1024.png
//
// 1024 캔버스 좌표로 그리고 ImageRenderer 배율로 줄인다 (작은 크기도 확대 · 축소가 아니라 그 크기로 새로 그린다).
// macOS 아이콘 규격대로 캔버스의 82.4% 만 본체(둥근 판)로 쓴다. 여백이 없으면 Dock · Finder 에서 다른 앱보다 커 보인다.
//
// 그림: 파란 판 위 맥북, 화면 위쪽 노치에서 검은 아일랜드가 내려와 있다.
// 16 · 32px 에서는 판 · 밝은 화면 · 검은 아일랜드 덩어리만 남는다. 아일랜드 안 막대들은 큰 크기에서만 보이는 장식이다.
import AppKit
import SwiftUI

private let canvas: CGFloat = 1024

private extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

private extension View {
    /// 1024 캔버스의 (x, y) 에 w × h 로 놓는다 (왼쪽 위 기준)
    func place(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> some View {
        frame(width: width, height: height).position(x: x + width / 2, y: y + height / 2)
    }
}

private struct AppIconArt: View {
    // 앱 테마(Theme.swift)와 같은 색
    private let green = Color(hex: 0x97C459)
    private let red = Color(hex: 0xF09595)
    private let cream = Color(hex: 0xF1EFE8)

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 판
            RoundedRectangle(cornerRadius: 824 * 0.2237, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x185FA5), Color(hex: 0x0C447C)], startPoint: .top, endPoint: .bottom))
                .place(100, 100, 824, 824)

            // 화면 테두리
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(Color(hex: 0x0A0A0A))
                .place(190, 230, 644, 480)

            // 화면: 배경화면 + 메뉴바 띠
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(hex: 0xD6E8FA), Color(hex: 0x9EC6EF)], startPoint: .top, endPoint: .bottom)
                Color(hex: 0xEEF5FD).frame(height: 44)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .place(216, 256, 592, 428)

            // 노치에서 내려온 아일랜드
            UnevenRoundedRectangle(bottomLeadingRadius: 48, bottomTrailingRadius: 48, style: .continuous)
                .fill(Color.black)
                .place(332, 256, 360, 148)
            Circle().fill(green).place(362, 296, 44, 44)
            Capsule().fill(cream).place(424, 305, 216, 26)
            Capsule().fill(green).place(424, 352, 96, 20)
            Capsule().fill(red).place(532, 352, 60, 20)

            // 본체 아래판과 여는 홈
            Capsule()
                .fill(LinearGradient(colors: [Color(hex: 0xA9CDF2), Color(hex: 0x78ABE0)], startPoint: .top, endPoint: .bottom))
                .place(140, 706, 744, 44)
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)
                .fill(Color(hex: 0x5E93CF))
                .place(452, 706, 120, 16)
        }
        .frame(width: canvas, height: canvas)
    }
}

@MainActor
private func writePNG(side: Int, to url: URL) -> Bool {
    let renderer = ImageRenderer(content: AppIconArt())
    renderer.proposedSize = ProposedViewSize(width: canvas, height: canvas)
    renderer.scale = CGFloat(side) / canvas
    guard let image = renderer.cgImage,
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { return false }
    return (try? data.write(to: url)) != nil
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("사용법: app-icon <폴더>\n".utf8))
    exit(64)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let ok = MainActor.assumeIsolated {
    [16, 32, 64, 128, 256, 512, 1024].allSatisfy { side in
        writePNG(side: side, to: directory.appendingPathComponent("\(side).png"))
    }
}
exit(ok ? 0 : 1)
