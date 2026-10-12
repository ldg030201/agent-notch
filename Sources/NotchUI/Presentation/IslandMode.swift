import AppKit
import NotchCore

/// 화면 하나의 아일랜드 표시 모드.
/// 우선순위: permission > needsInput > expanded(사용자가 연 경우) > done/failed > peek > working > idle
enum IslandMode: Equatable {
    /// 표시하지 않음 (세션 없음, 정책상 숨김, 풀스크린 숨김)
    case hidden
    /// 작업 중인 세션 없음 → 오른쪽 날개에 세션 점
    case idle
    /// 접힌 상태로 포커스 세션 표시 (작업 중 / 주의 필요 / 미확인 완료)
    case working
    /// 파일 수정 미니 diff 잠깐 펼치기
    case peek(sessionID: String, diff: DiffSnippet)
    /// 권한 요청 (해결될 때까지 유지)
    case permission(PermissionRequestInfo, queueCount: Int)
    /// 질문/입력 대기. `isPermissionPrompt` 면 훅 대기 없이 터미널에서 승인을 기다리는 경우
    case needsInput(sessionID: String, message: String, isPermissionPrompt: Bool)
    /// 턴 완료 요약
    case done(sessionID: String)
    /// 턴 실패 요약
    case failed(sessionID: String)
    /// 사용자가 연 전체 펼침
    case expanded

    enum Kind: Equatable {
        case hidden, idle, working, peek, permission, needsInput, done, failed, expanded
    }

    var kind: Kind {
        switch self {
        case .hidden: return .hidden
        case .idle: return .idle
        case .working: return .working
        case .peek: return .peek
        case .permission: return .permission
        case .needsInput: return .needsInput
        case .done: return .done
        case .failed: return .failed
        case .expanded: return .expanded
        }
    }

    /// 키 윈도우가 될 수 있는 모드 (단축키 사용)
    var wantsKey: Bool {
        switch self {
        case .permission, .needsInput, .expanded: return true
        default: return false
        }
    }

    /// 노치 아래로 펼쳐진 모드인지
    var isOpen: Bool {
        switch self {
        case .hidden, .idle, .working: return false
        default: return true
        }
    }

    /// 사용자 주의가 필요한 알림 모드인지 (풀스크린 "알림만" 에서도 표시)
    var isAlert: Bool {
        switch self {
        case .permission, .needsInput: return true
        default: return false
        }
    }
}

// MARK: - 레이아웃 상수

enum IslandMetrics {
    /// 바깥 좌우 여백 (상단 행)
    static let wingPadding: CGFloat = 14
    /// 펼친 내용 좌우 여백
    static let bodyPadding: CGFloat = 16
    static let bodyTop: CGFloat = 4
    static let bodyBottom: CGFloat = 12

    /// 접힌 working 상태에서 노치 양옆 날개 폭
    static let workingWing: CGFloat = 108
    static let idleDotSize: CGFloat = 5
    static let idleDotSpacing: CGFloat = 3
    static let maxIdleDots = 5

    static let lineHeight: CGFloat = 18
    static let diffRowHeight: CGFloat = 17
    static let diffRowSpacing: CGFloat = 2
    static let maxDiffRows = 3
    static let buttonHeight: CGFloat = 26

    static let pillWorkingWidth: CGFloat = 380
    static let peekWidth: CGFloat = 460
    static let permissionWidth: CGFloat = 480
    static let needsInputWidth: CGFloat = 440
    static let doneWidth: CGFloat = 430
    static let expandedSize = CGSize(width: 620, height: 300)
    /// 펼침 본문 높이 (상단 행 제외)
    static let expandedBodyHeight: CGFloat = 268
    /// 노치 없는 화면에서 카드 최대 폭 (전체 펼침 제외)
    static let externalCardMaxWidth: CGFloat = 460

    /// 메뉴바 아이템과 띄울 여백
    static let menuBarMargin: CGFloat = 8
    /// 접힌 날개: 양쪽 날개 최대/최소 폭
    static let minBothWing: CGFloat = 72
    /// 접힌 날개 하나만 쓸 때 최대 폭
    static let maxSingleWing: CGFloat = 240
    /// 노치 아래 띠
    static let stripHeight: CGFloat = 22
    static let stripExtraWidth: CGFloat = 80
    /// 노치 아래 선
    static let lineThickness: CGFloat = 3
    /// 메뉴바 안 점
    static let menuBarDotSize: CGFloat = 12
    /// 메뉴바 안 알약 최소 폭 (이보다 좁으면 점)
    static let minMenuBarPill: CGFloat = 80
    /// 카드 상단 행을 목 안(날개)에 두려면 필요한 날개 폭
    static let headerWingMin: CGFloat = 96
    /// 목 아래에 따로 두는 상단 행 높이
    static let headerRowHeight: CGFloat = 28
    /// 메뉴바 알약 안에 카드 상단 행을 둘 최소 폭
    static let pillHeaderMin: CGFloat = 220

    /// 권한 요청 상세(고정폭) 최대 줄 수
    static let maxDetailLines = 4
    static let detailHorizontalPadding: CGFloat = 10
    static let detailVerticalPadding: CGFloat = 6

    /// 고정폭 11pt 한 줄 높이
    static let monoLineHeight: CGFloat = fontLineHeight(IslandFont.monoNS)
    /// 본문 12pt 한 줄 높이
    static let bodyLineHeight: CGFloat = fontLineHeight(IslandFont.bodyNS)

    /// SwiftUI Text 의 줄 높이와 맞춘 값 (올림한 ascender + 올림한 descender + leading)
    static func fontLineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender) + ceil(-font.descender) + ceil(font.leading)
    }

    static func idleDotsWidth(count: Int) -> CGFloat {
        let n = CGFloat(min(max(count, 1), maxIdleDots))
        return n * idleDotSize + (n - 1) * idleDotSpacing
    }

    static func diffRowsHeight(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * diffRowHeight + CGFloat(count - 1) * diffRowSpacing
    }
}

/// 텍스트 줄 수 측정 (레이아웃 높이 계산용)
enum TextMeasure {
    static func lineCount(_ text: String, font: NSFont, lineHeight: CGFloat, width: CGFloat, maxLines: Int) -> Int {
        guard !text.isEmpty, width > 0, lineHeight > 0 else { return 1 }
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        // 반올림 오차로 한 줄이 두 줄로 세어지지 않게 약간 여유를 둔다
        let lines = Int(((rect.height - 1) / lineHeight).rounded(.up))
        return min(max(lines, 1), maxLines)
    }
}
