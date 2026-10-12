// swift-tools-version: 6.0
import PackageDescription

// 모든 타깃은 Swift 5 언어 모드로 빌드한다 (AppKit 상호운용 시 엄격한 동시성 검사로 인한 마찰 최소화).
let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "AgentNotch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentNotch", targets: ["AgentNotch"]),
        .executable(name: "notch-hook", targets: ["notch-hook"]),
    ],
    targets: [
        // 훅 헬퍼와 앱이 공유하는 와이어 프로토콜, JSON 타입
        .target(name: "NotchShared", swiftSettings: swiftSettings),
        // Claude Code 훅이 실행하는 초경량 헬퍼 (stdin → Unix 소켓 → 앱)
        .executableTarget(name: "notch-hook", dependencies: ["NotchShared"], swiftSettings: swiftSettings),
        // 세션 상태, 이벤트 파싱, 포커스 엔진, diff 계산 (UI 비의존)
        .target(name: "NotchCore", dependencies: ["NotchShared"], swiftSettings: swiftSettings),
        // 소켓 서버, 훅 설치기, 터미널 점프, 사운드 등 시스템 연동
        .target(name: "NotchServices", dependencies: ["NotchShared", "NotchCore"], swiftSettings: swiftSettings),
        // 노치 패널, 다이나믹 아일랜드 SwiftUI 뷰
        .target(name: "NotchUI", dependencies: ["NotchCore"], swiftSettings: swiftSettings),
        // 앱 진입점 (메뉴바 앱, 모듈 조립)
        .executableTarget(
            name: "AgentNotch",
            dependencies: ["NotchShared", "NotchCore", "NotchServices", "NotchUI"],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore", "NotchShared"], swiftSettings: swiftSettings),
        .testTarget(
            name: "NotchServicesTests",
            dependencies: ["NotchServices", "NotchCore", "NotchShared"],
            swiftSettings: swiftSettings
        ),
    ]
)
