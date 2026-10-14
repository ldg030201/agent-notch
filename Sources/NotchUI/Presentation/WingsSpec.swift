import CoreGraphics

// 넓은 노치(날개) 모양과 날개 비켜주기 값.
// 날개는 메뉴바 아이콘을 덮고, 마우스를 올린 쪽 날개가 노치 안으로 들어가 비켜준다 (`WingSides` 로 표시).

/// 날개 쪽
struct WingSides: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let left = WingSides(rawValue: 1 << 0)
    static let right = WingSides(rawValue: 1 << 1)
}

/// 날개 안 내용 배치
enum WingArrangement: Hashable, Sendable {
    /// 왼쪽 = 상태 (+ 프로젝트), 오른쪽 = (툴 +) `+N −M`
    case split
    /// 왼쪽 날개 하나에 모음 (노치 쪽으로 붙임)
    case left
    /// 오른쪽 날개 하나에 모음 (노치 쪽으로 붙임)
    case right
    /// 날개 없이 그린 접힌 상태 (노치 아래 띠 · 선 · 알약). 배치 이력(`WingsSpec.withoutWings`)에만 쓴다
    case strip
}

/// 넓은 노치 날개의 모양과 내용 자리
struct WingsSpec: Equatable, Sendable {
    /// 검은 날개 폭 (노치 가장자리부터 바깥쪽, 귀 제외). 비켜준 쪽도 원래 폭을 둔다 (`hidden` 참고).
    /// 내용은 날개 폭 그대로 둔다 (폭 0 인 쪽은 내용 없음)
    var left: CGFloat
    var right: CGFloat
    var items: CompactItems
    var arrangement: WingArrangement
    /// 마우스를 올려 비켜준 쪽 (폭 0 으로 그리고 내용은 숨김)
    var hidden: WingSides = []

    var visibleLeft: CGFloat { hidden.contains(.left) ? 0 : left }
    var visibleRight: CGFloat { hidden.contains(.right) ? 0 : right }

    /// 날개 없이 그린 접힌 상태 (노치 아래 띠 · 선 · 알약). 배치 이력(`IslandLayoutEngine.previousWings`)용
    static let withoutWings = WingsSpec(left: 0, right: 0, items: [], arrangement: .strip)

    /// 날개 폭에 맞춰 배치를 정한다 (양쪽 · 왼쪽 하나 · 오른쪽 하나)
    static func plain(left: CGFloat, right: CGFloat, items: CompactItems, hidden: WingSides = []) -> WingsSpec {
        let arrangement: WingArrangement = left > 0 && right > 0 ? .split : (left > 0 ? .left : .right)
        return WingsSpec(left: left, right: right, items: items, arrangement: arrangement, hidden: hidden)
    }
}

/// 마우스를 올리면 비켜줄 날개 자리 (패널 기준, 귀 포함 · 메뉴바 높이)
struct WingBands: Equatable, Sendable {
    var left: CGRect?
    var right: CGRect?

    static let none = WingBands()
    var isEmpty: Bool { left == nil && right == nil }
}
