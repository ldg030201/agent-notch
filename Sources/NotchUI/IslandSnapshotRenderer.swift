import Foundation

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
    public static var scenarios: [String] { [] }

    /// 장면 하나를 PNG 로 저장한다. 배경은 메뉴바 일부를 흉내 낸 밝은 띠 위에 아일랜드를 올린 모양.
    @MainActor
    public static func renderPNG(scenario: String, style: Style, to url: URL) throws {
        // TODO: NotchUI 단계에서 구현
        throw RenderError.unknownScenario(scenario)
    }
}
