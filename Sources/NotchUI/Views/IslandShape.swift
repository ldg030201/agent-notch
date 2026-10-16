import SwiftUI

/// 아일랜드 외곽선 치수. 목 · 몸통 · 반경은 프레임 기준(pt), 원점 · 노치 · 부분 1 자리는 패널 기준이고 모두 함께 애니메이션된다.
///
/// 아일랜드는 "부분 1"(접힌 모양)과 "부분 2"(펼친 카드 몸통)로 그린다.
/// - 부분 1 (`part1`): 접힌 상태 모양 그대로. 카드를 펼치고 접는 동안 자리 · 크기 · 반경이 바뀌지 않는다 (양 끝 값이 같아 보간해도 그대로).
/// - 주 외곽선 = 목 + 몸통. 목은 부분 1 의 위쪽 조각(띠 · 알약 · 점)과 같은 자리, 몸통이 부분 2 다.
///   - 몸통은 메뉴바 아래에서만 목보다 넓어진다 (`menuBarBottom`, 전환 중간 프레임 포함). 만나는 곳은 오목하게 이어진다.
///   - 몸통이 낮을 때(펼치기 시작 · 접히기 끝)는 부분 1 아래 모서리 안쪽에서 나오고 그리로 들어간다 (`capRadius`):
///     몸통이 목과 옆면을 맞댄 채 늘어나 부분 1 이 커져 보이지 않게.
///   - 접힌 상태는 몸통 높이 0 (부분 1 만 그린다).
/// - 노치 화면은 목 위쪽 모서리에 바깥으로 휘는 "귀"를 둬서 하드웨어 노치와 자연스럽게 잇는다.
/// - 노치 화면은 어떤 중간 프레임에서도 하드웨어 노치를 다 덮는다 (`notchMinX` · `notchWidth` · `notchHeight`).
struct IslandShapeSpec: Equatable {
    /// 프레임 왼쪽/오른쪽 끝에서 목 옆면까지 거리
    var neckLeft: CGFloat = 0
    var neckRight: CGFloat = 0
    /// 목 높이 (몸통 높이 = 프레임 높이 − 목 높이)
    var neckHeight: CGFloat = 0
    /// 프레임 왼쪽/오른쪽 끝에서 몸통 옆면까지 거리 (목보다 넓거나 좁을 수 있음)
    var bodyLeft: CGFloat = 0
    var bodyRight: CGFloat = 0
    /// 목 위쪽 바깥으로 휘는 귀 반경 (노치 화면)
    var leftEar: CGFloat = 0
    var rightEar: CGFloat = 0
    /// 목 위쪽 모서리 반경 (귀가 없는 쪽, 알약)
    var topRadius: CGFloat = 0
    /// 몸통이 목보다 넓을 때 몸통 위쪽 바깥 모서리 반경 (좁을 때는 목과 만나는 오목한 모서리)
    var bodyTopRadius: CGFloat = 0
    /// 목과 몸통이 만나는 오목한 모서리 반경 (몸통이 좁을 때는 목 아래 볼록한 모서리)
    var shoulderRadius: CGFloat = 0
    var bottomRadius: CGFloat = 0
    /// 프레임 왼쪽 위의 패널 기준 위치 (`IslandLayout.origin` 과 같은 값 · 같은 곡선으로 움직인다)
    var originX: CGFloat = 0
    var originY: CGFloat = 0
    /// 하드웨어 노치 (패널 기준). 폭 0 이면 노치 없음
    var notchMinX: CGFloat = 0
    var notchWidth: CGFloat = 0
    var notchHeight: CGFloat = 0
    /// 메뉴바 아래끝 (패널 기준, 노치 화면). 0 이면 제한 없음.
    /// 몸통이 목보다 넓은 쪽은 이 아래에서만 넓어진다 — 펼치고 접히는 중간에 몸통이 메뉴바 아이콘 · 메뉴를 덮지 않게
    var menuBarBottom: CGFloat = 0
    /// 몸통이 목보다 좁거나 없을 때 목 아래 볼록 모서리 = 부분 1 의 아래 모서리. 0 이면 부분 2 를 쓰지 않는 모양
    var capRadius: CGFloat = 0
    /// 부분 1 (접힌 모양). 폭 0 이면 없음
    var part1 = IslandPart1Spec()
    /// 프레임 크기 (`IslandLayout.size`). 패널 기준으로 그리는 `IslandPanelShape` 만 쓴다
    var frameWidth: CGFloat = 0
    var frameHeight: CGFloat = 0
}

extension IslandShapeSpec {
    /// 주 외곽선이 부분 1 과 같은 모양인지 (접힌 상태, 접힌 상태끼리 바뀌는 중)
    func isSameShape(as p: IslandPart1Spec, frame rect: CGRect) -> Bool {
        let pairs: [(CGFloat, CGFloat)] = [
            (p.minX, originX), (p.minY, originY), (p.width, rect.width), (p.height, rect.height),
            (p.neckLeft, neckLeft), (p.neckRight, neckRight), (p.neckHeight, neckHeight),
            (p.bodyLeft, bodyLeft), (p.bodyRight, bodyRight), (p.leftEar, leftEar), (p.rightEar, rightEar),
            (p.topRadius, topRadius), (p.bodyTopRadius, bodyTopRadius), (p.shoulderRadius, shoulderRadius),
            (p.bottomRadius, bottomRadius),
        ]
        return pairs.allSatisfy { abs($0 - $1) < 0.01 }
    }
}

/// 부분 1: 접힌 상태 모양 그대로 (자리는 패널 기준, 모양 치수는 그 사각형 기준 — `IslandShapeSpec` 의 같은 이름 값과 같은 뜻).
/// 아래 조각이 위 조각보다 좁은 두 조각 모양도 그릴 수 있다 (지금 접힌 모양 · 띠 · 알약 · 점은 모두 한 조각)
struct IslandPart1Spec: Equatable {
    var minX: CGFloat = 0
    var minY: CGFloat = 0
    var width: CGFloat = 0
    var height: CGFloat = 0
    var neckLeft: CGFloat = 0
    var neckRight: CGFloat = 0
    var neckHeight: CGFloat = 0
    var bodyLeft: CGFloat = 0
    var bodyRight: CGFloat = 0
    var leftEar: CGFloat = 0
    var rightEar: CGFloat = 0
    var topRadius: CGFloat = 0
    var bodyTopRadius: CGFloat = 0
    var shoulderRadius: CGFloat = 0
    var bottomRadius: CGFloat = 0

    /// 패널 기준 사각형
    var rect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }

    /// 아래 조각(노치 아래 띠)이 위 조각보다 좁은 두 조각 모양인지
    var isTwoPiece: Bool { bodyLeft - neckLeft > 0.5 || bodyRight - neckRight > 0.5 }

    /// 접힌 모양 치수 (사각형 기준)로 만든다
    init() {}

    init(rect: CGRect, shape: IslandShapeSpec) {
        minX = rect.minX
        minY = rect.minY
        width = rect.width
        height = rect.height
        neckLeft = shape.neckLeft
        neckRight = shape.neckRight
        neckHeight = shape.neckHeight
        bodyLeft = shape.bodyLeft
        bodyRight = shape.bodyRight
        leftEar = shape.leftEar
        rightEar = shape.rightEar
        topRadius = shape.topRadius
        bodyTopRadius = shape.bodyTopRadius
        shoulderRadius = shape.shoulderRadius
        bottomRadius = shape.bottomRadius
    }

    /// 외곽선 계산용 치수 (노치 보호 · 메뉴바 아래끝은 전체 모양 값을 따른다)
    func shapeSpec(in parent: IslandShapeSpec) -> IslandShapeSpec {
        var spec = IslandShapeSpec(
            neckLeft: neckLeft, neckRight: neckRight, neckHeight: neckHeight,
            bodyLeft: bodyLeft, bodyRight: bodyRight, leftEar: leftEar, rightEar: rightEar,
            topRadius: topRadius, bodyTopRadius: bodyTopRadius, shoulderRadius: shoulderRadius, bottomRadius: bottomRadius
        )
        spec.originX = minX
        spec.originY = minY
        spec.notchMinX = parent.notchMinX
        spec.notchWidth = parent.notchWidth
        spec.notchHeight = parent.notchHeight
        spec.menuBarBottom = parent.menuBarBottom
        return spec
    }
}

extension IslandShapeSpec: VectorArithmetic {
    private static let fields: [WritableKeyPath<IslandShapeSpec, CGFloat>] = [
        \.neckLeft, \.neckRight, \.neckHeight, \.bodyLeft, \.bodyRight,
        \.leftEar, \.rightEar, \.topRadius, \.bodyTopRadius, \.shoulderRadius, \.bottomRadius,
        \.originX, \.originY, \.notchMinX, \.notchWidth, \.notchHeight, \.menuBarBottom, \.capRadius,
        \.part1.minX, \.part1.minY, \.part1.width, \.part1.height, \.part1.neckLeft, \.part1.neckRight, \.part1.neckHeight,
        \.part1.bodyLeft, \.part1.bodyRight, \.part1.leftEar, \.part1.rightEar, \.part1.topRadius,
        \.part1.bodyTopRadius, \.part1.shoulderRadius, \.part1.bottomRadius,
        \.frameWidth, \.frameHeight,
    ]

    static var zero: IslandShapeSpec { IslandShapeSpec() }

    static func + (lhs: IslandShapeSpec, rhs: IslandShapeSpec) -> IslandShapeSpec {
        var result = lhs
        for field in fields { result[keyPath: field] += rhs[keyPath: field] }
        return result
    }

    static func - (lhs: IslandShapeSpec, rhs: IslandShapeSpec) -> IslandShapeSpec {
        var result = lhs
        for field in fields { result[keyPath: field] -= rhs[keyPath: field] }
        return result
    }

    mutating func scale(by rhs: Double) {
        for field in Self.fields { self[keyPath: field] *= CGFloat(rhs) }
    }

    var magnitudeSquared: Double {
        Self.fields.reduce(0) { $0 + Double(self[keyPath: $1] * self[keyPath: $1]) }
    }
}

/// 패널 전체를 받아 스펙의 원점 · 크기 자리에 아일랜드를 그리는 모양.
/// 자리 · 크기 · 모양이 모두 스펙(`animatableData`) 한 곳에서 보간된다. 프레임 크기 · 오프셋 애니메이션과 따로 움직이지 않아서
/// 빠르게 다시 누르거나(스프링 재조준) 프레임이 밀려도 부분 1 이 옆으로 밀리거나 넓어져 보이지 않는다
struct IslandPanelShape: Shape {
    var spec: IslandShapeSpec

    var animatableData: IslandShapeSpec {
        get { spec }
        set { spec = newValue }
    }

    func path(in rect: CGRect) -> Path {
        IslandShape(spec: spec).path(in: IslandShape.frame(spec, in: rect))
    }
}

/// 실제로 그려지는 외곽선 치수 (반경 · 폭 제한을 적용한 값, 프레임 기준).
/// 모든 값이 스펙에 대해 연속이라 스펙을 보간하면 모양도 끊김 없이 바뀐다.
struct IslandOutline: Equatable {
    var isEmpty = false
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    /// 목 옆면 · 목 아래끝
    var nx0: CGFloat = 0
    var nx1: CGFloat = 0
    var neckBottom: CGFloat = 0
    /// 쪽마다 목 → 몸통 계단 y (몸통이 넓은 쪽은 메뉴바 아래까지 내려간다, 좁은 쪽은 목 아래끝)
    var stepL: CGFloat = 0
    var stepR: CGFloat = 0
    /// 몸통 옆면
    var bx0: CGFloat = 0
    var bx1: CGFloat = 0
    var earL: CGFloat = 0
    var earR: CGFloat = 0
    var topRL: CGFloat = 0
    var topRR: CGFloat = 0
    var bottomR: CGFloat = 0
    var shoulderL: CGFloat = 0
    var shoulderR: CGFloat = 0
    var bodyTopL: CGFloat = 0
    var bodyTopR: CGFloat = 0

    /// 몸통이 목보다 바깥으로 나온 폭 (음수면 안쪽으로 좁음)
    var widenL: CGFloat { nx0 - bx0 }
    var widenR: CGFloat { bx1 - nx1 }

    /// 경로 가로 범위 (귀는 목 밖으로 나간다)
    var minX: CGFloat { min(nx0 - earL, bx0) }
    var maxX: CGFloat { max(nx1 + earR, bx1) }
}

/// 아일랜드 검은 모양
struct IslandShape: Shape {
    var spec: IslandShapeSpec

    var animatableData: IslandShapeSpec {
        get { spec }
        set { spec = newValue }
    }

    /// 반경 0.5 이하는 직선 모서리로 그린다
    static let minRadius: CGFloat = 0.5

    func path(in rect: CGRect) -> Path {
        Self.filledPath(spec, in: rect)
    }

    /// 무엇을 그리는지: 부분 1 만 (접힌 상태) · 주 외곽선만 (부분 1 없음) · 둘을 함께 (펼친 카드 · 펼치고 접는 중)
    enum Drawn {
        case part1(IslandOutline)
        case main(IslandOutline)
        case union(main: IslandOutline, part1: IslandOutline)

        var outlines: [IslandOutline] {
            switch self {
            case let .part1(o), let .main(o): return [o]
            case let .union(main, part1): return [main, part1]
            }
        }
    }

    static func drawn(_ spec: IslandShapeSpec, in rect: CGRect) -> Drawn {
        let main = outline(spec, in: rect)
        guard let part1 = part1Outline(spec, in: rect), !part1.isEmpty else { return .main(main) }
        // 접힌 상태 (주 외곽선 = 부분 1, 접힌 상태끼리 바뀌는 중 포함): 부분 1 만
        if main.isEmpty || spec.isSameShape(as: spec.part1, frame: rect) { return .part1(part1) }
        // 부분 1 은 그대로 그리고, 주 외곽선(목 + 부분 2)을 함께 그린다
        return .union(main: main, part1: part1)
    }

    /// 프레임 사각형 (패널 기준 원점 · 크기를 스펙에서). `IslandPanelShape` 가 이 사각형에 그린다
    static func frame(_ spec: IslandShapeSpec, in panel: CGRect) -> CGRect {
        CGRect(x: panel.minX + spec.originX, y: panel.minY + spec.originY, width: spec.frameWidth, height: spec.frameHeight)
    }

    /// 칠할 모양.
    /// 주 외곽선과 부분 1 은 같은 방향으로 도는 닫힌 경로라, 한 경로에 하위 경로 둘로 넣고 기본(nonzero) 규칙으로 칠하면
    /// 겹친 곳도 한 번만 칠해져 합집합과 같다 (불리언 연산 없음 · 이음매 없음). 부분 2 가 폭 0 으로 숨은 순간(점 같은 부분 1 아래의
    /// 넓이 0 인 바늘)이나 부분 1 안에 들어간 목 · 오목 모서리는 칠할 넓이가 없어 아무것도 그리지 않는다.
    /// 주 외곽선은 부분 1 과 겹치는 목 위끝 곡선(귀 · 둥근 위 모서리)을 빼고 그린다 (`path(_:underPart1:)`: 같은 곡선을 두 번 칠하지 않게)
    static func filledPath(_ spec: IslandShapeSpec, in rect: CGRect) -> Path {
        switch drawn(spec, in: rect) {
        case let .part1(o), let .main(o):
            return o.isEmpty ? Path() : path(o)
        case let .union(main, part1):
            // `drawn` 은 주 외곽선이 비면 `.part1` 을 돌려주므로 여기선 늘 둘 다 있다
            var filled = path(main, underPart1: true)
            filled.addPath(path(part1))
            return filled
        }
    }

    /// 부분 1 외곽선 (지금 프레임 기준). 부분 1 이 없으면 nil
    static func part1Outline(_ spec: IslandShapeSpec, in rect: CGRect) -> IslandOutline? {
        let p = spec.part1
        guard p.width > 1, p.height > 1 else { return nil }
        let local = CGRect(x: rect.minX + p.minX - spec.originX, y: rect.minY + p.minY - spec.originY, width: p.width, height: p.height)
        return outline(p.shapeSpec(in: spec), in: local, isPart1: true)
    }

    /// 스펙 → 실제 그릴 치수.
    /// - isPart1: 부분 1 (접힌 모양) 외곽선. 몸통이 좁을 때 목 아래 볼록 모서리는 어깨 반경, 몸통 높이에 따른 폭 제한 없음
    static func outline(_ spec: IslandShapeSpec, in rect: CGRect, isPart1: Bool = false) -> IslandOutline {
        var o = IslandOutline()
        guard rect.width > 1, rect.height > 1 else {
            o.isEmpty = true
            return o
        }
        let eps = minRadius
        o.top = rect.minY
        o.bottom = rect.maxY
        o.nx0 = rect.minX + max(0, spec.neckLeft)
        o.nx1 = rect.maxX - max(0, spec.neckRight)
        o.bx0 = rect.minX + max(0, spec.bodyLeft)
        o.bx1 = rect.maxX - max(0, spec.bodyRight)

        // 하드웨어 노치는 늘 덮는다 (스프링이 목표를 지나치거나 다시 겨냥할 때도)
        if spec.notchWidth > 1 {
            let n0 = rect.minX + spec.notchMinX - spec.originX
            let n1 = n0 + spec.notchWidth
            o.nx0 = min(o.nx0, n0)
            o.nx1 = max(o.nx1, n1)
            o.bx0 = min(o.bx0, n0)
            o.bx1 = max(o.bx1, n1)
            o.bottom = max(o.bottom, o.top + spec.notchHeight)
        }
        let neckWidth = o.nx1 - o.nx0
        guard neckWidth > 1 else {
            o.isEmpty = true
            return o
        }
        // 부분 2 를 쓰는 주 외곽선인지 (부분 1 아래 모서리가 있음)
        let capSpec = isPart1 ? 0 : max(0, spec.capRadius)
        if o.bx1 - o.bx0 < 2, capSpec <= eps {
            o.bx0 = o.nx0
            o.bx1 = o.nx1
        }
        let height = o.bottom - o.top
        let neckHeight = min(max(0, spec.neckHeight), height)
        o.neckBottom = o.top + neckHeight
        let bodyHeight = height - neckHeight

        // 몸통 폭 제한:
        // - 몸통이 목보다 넓은 쪽은 메뉴바 아래에서만 넓어진다. 메뉴바 아래 몸통 높이(아래 반경 제외)가 모자라면 넓어지는 폭을 줄인다
        //   (`widenAllowance`): 펼치기 시작 · 접히기 끝에 몸통이 먼저 아래로 내려온 뒤 옆으로 넓어지고, 이음매는 늘 S 곡선으로 끝까지 그려진다
        // - 부분 2 (`capRadius`): 몸통이 낮으면 부분 1 아래 모서리 안쪽으로 좁아진다 (`emergeLimit`).
        //   몸통 높이 0 에서는 부분 1 아래 모서리를 다 드러내고, 낮은 동안 목과 옆면을 맞댄 채 늘어나지 않는다
        // - 계단 y 는 넓어진 폭이 0 → 6pt 일 동안 목 아래끝 → 메뉴바 아래끝으로 이어서 옮긴다 (폭 0 이면 어느 y 든 같은 모양)
        let bottomRadius = clamp(spec.bottomRadius, 0, bodyHeight)
        let shoulderSpec = max(0, spec.shoulderRadius)
        let bodyTopSpec = max(0, spec.bodyTopRadius)
        var barBottom = o.neckBottom
        var limit = CGFloat.infinity
        if spec.menuBarBottom > 0 {
            barBottom = max(o.neckBottom, rect.minY + spec.menuBarBottom - spec.originY)
            limit = widenAllowance(
                room: max(0, o.bottom - bottomRadius - barBottom), shoulder: shoulderSpec, bodyTop: bodyTopSpec
            )
        }
        if capSpec > eps {
            // 부분 2 는 부분 1 아래끝에서 나온다 (두 조각이면 노치 아래 띠 아래끝. 그 위에서는 부분 1 이 덮는다)
            let part1 = spec.part1
            var emergeTop = o.neckBottom
            if part1.width > 1 {
                emergeTop = max(o.neckBottom, rect.minY + part1.minY + part1.height - spec.originY)
            }
            let narrow = min(capSpec + bodyTopSpec, neckWidth / 2)
            let start = max(0, barBottom - emergeTop) + capSpec + 1
            limit = min(limit, emergeLimit(bodyHeight: o.bottom - emergeTop, narrow: narrow, start: start))
            // 넓어지는 쪽은 처음부터 `bodySnap` 만큼(프레임 안에서) 넓게 둔다: 펼친 카드 쪽 값이 작을 때 접히기 끝에
            // 몸통이 목과 옆면을 맞댄 채 늘어나 부분 1 이 커져 보이지 않게. 메뉴바 아래 자리 · 높이 제한(`limit`)은 그대로 따른다
            let snap = IslandLayoutEngine.bodySnap
            if o.widenL > 0 { o.bx0 = o.nx0 - max(o.widenL, min(o.widenL * 4, snap, o.nx0 - rect.minX)) }
            if o.widenR > 0 { o.bx1 = o.nx1 + max(o.widenR, min(o.widenR * 4, snap, rect.maxX - o.nx1)) }
        }
        if o.widenL > limit { o.bx0 = o.nx0 - limit }
        if o.widenR > limit { o.bx1 = o.nx1 + limit }
        if o.bx1 < o.bx0 {
            let mid = (o.bx0 + o.bx1) / 2
            o.bx0 = mid
            o.bx1 = mid
        }
        // 1pt 미만 차이는 곧은 옆면 (모서리 없음). 1 → 2pt 사이에서 이어서 벌어진다
        o.bx0 = o.nx0 - settledWiden(o.widenL)
        o.bx1 = o.nx1 + settledWiden(o.widenR)
        func step(_ widen: CGFloat) -> CGFloat {
            widen > 0 ? o.neckBottom + clamp(widen / 6, 0, 1) * (barBottom - o.neckBottom) : o.neckBottom
        }
        o.stepL = step(o.widenL)
        o.stepR = step(o.widenR)

        // 귀와 위쪽 모서리 (목 안)
        let earLimit = min(neckHeight / 2, neckWidth / 4)
        o.earL = clamp(spec.leftEar, 0, min(o.nx0 - rect.minX, earLimit))
        o.earR = clamp(spec.rightEar, 0, min(rect.maxX - o.nx1, earLimit))
        let topLimit = min(neckWidth / 2, neckHeight)
        o.topRL = o.earL > eps ? 0 : clamp(spec.topRadius, 0, topLimit)
        o.topRR = o.earR > eps ? 0 : clamp(spec.topRadius, 0, topLimit)

        // 아래 모서리 (몸통 안)
        o.bottomR = clamp(spec.bottomRadius, 0, min((o.bx1 - o.bx0) / 2, bodyHeight))

        // 목 → 몸통 계단: 목 쪽 모서리(몸통이 넓으면 오목, 좁으면 볼록) + 몸통 쪽 모서리(그 반대)가 차이를 함께 채운다.
        // 두 반경의 합은 차이를 넘지 않고(비율대로 나눔), 차이가 반경 합보다 작으면 합 = 차이라 하나의 S 곡선이 된다.
        // 목 아래 볼록 모서리와 몸통 위 볼록 모서리는 한쪽에 함께 생기지 않는다 (맞물려 물린 모양 없음).
        // 몸통이 좁을 때 목 쪽 볼록 모서리는 부분 1 아래 모서리(`capRadius`)를 넘지 않는다 (부분 1 이 둥글게 드러난 채)
        func joint(_ widen: CGFloat, step: CGFloat, ear: CGFloat, topR: CGFloat) -> (shoulder: CGFloat, bodyTop: CGFloat) {
            let gap = abs(widen)
            let neckSpec = widen > 0 || capSpec <= eps ? shoulderSpec : capSpec
            let total = neckSpec + bodyTopSpec
            guard gap > eps, total > eps else { return (0, 0) }
            let scale = min(1, gap / total)
            let above = max(0, step - o.top - max(ear, topR))
            let below = max(0, o.bottom - step - o.bottomR)
            var shoulder = min(neckSpec * scale, above)
            var bodyTop = min(bodyTopSpec * scale, below)
            // 한쪽이 높이가 모자라 줄었으면 다른 쪽이 메워 턱이 남지 않게 (각자 원래 반경까지).
            // 부분 1 아래 볼록 모서리는 제 반경까지만 (그 너머는 부분 1 아래 변이 그대로 드러난다)
            let missing = min(gap, total) - shoulder - bodyTop
            if missing > 0.01 {
                let shoulderCap = widen < 0 && capSpec > eps ? capSpec : max(shoulderSpec, bodyTopSpec)
                let extraShoulder = min(missing, max(0, min(above, shoulderCap) - shoulder))
                shoulder += extraShoulder
                bodyTop += min(missing - extraShoulder, max(0, min(below, max(shoulderSpec, bodyTopSpec)) - bodyTop))
            }
            return (shoulder, bodyTop)
        }
        (o.shoulderL, o.bodyTopL) = joint(o.widenL, step: o.stepL, ear: o.earL, topR: o.topRL)
        (o.shoulderR, o.bodyTopR) = joint(o.widenR, step: o.stepR, ear: o.earR, topR: o.topRR)
        return o
    }

    /// 외곽선 경로 (시계 방향: 위 변 왼쪽 → 오른쪽, 오른쪽 변, 아래 변, 왼쪽 변).
    /// - underPart1: 부분 1 과 함께 그리는 주 외곽선. 목 위끝 모서리는 부분 1 위 조각과 같은 자리 · 같은(또는 작은) 곡선이라
    ///   곡선을 그리지 않는다: 귀는 빼고(목 옆면 바깥 → 부분 1 귀 안), 둥근 위 모서리는 현으로 깎는다(부분 1 의 같은 모서리 안).
    ///   같은 곡선을 하위 경로 둘로 겹쳐 칠하면 SwiftUI 래스터가 가장자리 덮임을 더해 곡선 가장자리가 진해진다
    ///   (합집합 모양은 같다: 뺀 귀 · 깎은 모서리는 부분 1 안)
    static func path(_ o: IslandOutline, underPart1: Bool = false) -> Path {
        let eps = minRadius
        let top = o.top
        var path = Path()

        // 위쪽 변 (왼쪽 → 오른쪽)
        if underPart1 {
            let chamferL = o.earL > eps || o.topRL <= eps ? 0 : o.topRL
            let chamferR = o.earR > eps || o.topRR <= eps ? 0 : o.topRR
            path.move(to: CGPoint(x: o.nx0, y: top + chamferL))
            if chamferL > 0 { path.addLine(to: CGPoint(x: o.nx0 + chamferL, y: top)) }
            path.addLine(to: CGPoint(x: o.nx1 - chamferR, y: top))
            if chamferR > 0 { path.addLine(to: CGPoint(x: o.nx1, y: top + chamferR)) }
        } else if o.earL > eps {
            path.move(to: CGPoint(x: o.nx0 - o.earL, y: top))
        } else if o.topRL > eps {
            path.move(to: CGPoint(x: o.nx0, y: top + o.topRL))
            path.addArc(tangent1End: CGPoint(x: o.nx0, y: top), tangent2End: CGPoint(x: o.nx0 + o.topRL, y: top), radius: o.topRL)
        } else {
            path.move(to: CGPoint(x: o.nx0, y: top))
        }
        if underPart1 {
            // 위에서 이미 오른쪽 목 옆면 위끝까지 왔다
        } else if o.earR > eps {
            path.addLine(to: CGPoint(x: o.nx1 + o.earR, y: top))
            path.addQuadCurve(to: CGPoint(x: o.nx1, y: top + o.earR), control: CGPoint(x: o.nx1, y: top))
        } else if o.topRR > eps {
            path.addLine(to: CGPoint(x: o.nx1 - o.topRR, y: top))
            path.addArc(tangent1End: CGPoint(x: o.nx1, y: top), tangent2End: CGPoint(x: o.nx1, y: top + o.topRR), radius: o.topRR)
        } else {
            path.addLine(to: CGPoint(x: o.nx1, y: top))
        }

        // 오른쪽 변 (위 → 아래). 계단은 폭이 0 이어도 그린다 (옆면이 비스듬해져 모서리 호와 겹치지 않게)
        corner(&path, CGPoint(x: o.nx1, y: o.stepR), CGPoint(x: o.bx1, y: o.stepR), o.shoulderR)
        corner(&path, CGPoint(x: o.bx1, y: o.stepR), CGPoint(x: o.bx1, y: o.bottom), o.bodyTopR)
        corner(&path, CGPoint(x: o.bx1, y: o.bottom), CGPoint(x: o.bx0, y: o.bottom), o.bottomR)

        // 왼쪽 변 (아래 → 위)
        corner(&path, CGPoint(x: o.bx0, y: o.bottom), CGPoint(x: o.bx0, y: top), o.bottomR)
        corner(&path, CGPoint(x: o.bx0, y: o.stepL), CGPoint(x: o.nx0, y: o.stepL), o.bodyTopL)
        corner(&path, CGPoint(x: o.nx0, y: o.stepL), CGPoint(x: o.nx0, y: top), o.shoulderL)
        if !underPart1, o.earL > eps {
            path.addLine(to: CGPoint(x: o.nx0, y: top + o.earL))
            path.addQuadCurve(to: CGPoint(x: o.nx0 - o.earL, y: top), control: CGPoint(x: o.nx0, y: top))
        }
        path.closeSubpath()
        return path
    }

    /// 꼭짓점 `vertex` 를 반경 `radius` 로 둥글게 돌아 `next` 방향으로 이어간다 (오목/볼록 모두).
    private static func corner(_ path: inout Path, _ vertex: CGPoint, _ next: CGPoint, _ radius: CGFloat) {
        if radius > minRadius {
            path.addArc(tangent1End: vertex, tangent2End: next, radius: radius)
        } else {
            path.addLine(to: vertex)
        }
    }

    /// 메뉴바 아래 몸통 높이(아래 반경 제외) `room` 으로 넓어질 수 있는 폭.
    /// 높이가 몸통 위 반경 + 2pt 가 될 때까지는 이음매 S 곡선(오목 + 볼록)이 옆면 안에 다 들어갈 만큼만,
    /// 그 뒤로는 높이의 8배씩 넓어진다 (몸통이 혀처럼 옆으로 튀어나오지 않게. 짧은 카드도 정한 폭까지는 넓어지게)
    static func widenAllowance(room: CGFloat, shoulder: CGFloat, bodyTop: CGFloat) -> CGFloat {
        let knee = bodyTop + 2
        let atKnee = max(shoulder + bodyTop, knee)
        if room <= knee { return room / knee * atKnee }
        return atKnee + (room - knee) * 8
    }

    /// 부분 2 가 부분 1 아래로 나온 높이로 목보다 넓어질 수 있는 폭 (음수면 그만큼 목보다 좁게).
    /// 낮을 때는 `narrow` 만큼 좁아 부분 1 아래 모서리 안쪽에 숨고, `start` 높이 가까이에서 높이의 3배씩 넓어져 목 폭을 지나고,
    /// 그 뒤로는 높이의 6배씩. 목 폭을 지날 때는 메뉴바 아래 넓어질 자리(`widenAllowance`)가 막 생기는 높이라
    /// 맞닿은 채 늘어나는 구간이 없다
    static func emergeLimit(bodyHeight: CGFloat, narrow: CGFloat, start: CGFloat) -> CGFloat {
        guard start > 0 else { return .infinity }
        let height = max(0, bodyHeight)
        if height < start { return max(-narrow, (height - start) * 3) }
        return (height - start) * 6
    }

    /// 목 ↔ 몸통 차이: 1pt 미만은 0 (곧은 옆면), 1 → 2pt 에서 0 → 2pt 로 이어진다
    private static func settledWiden(_ widen: CGFloat) -> CGFloat {
        let gap = abs(widen)
        let value = gap < 1 ? 0 : (gap < 2 ? (gap - 1) * 2 : gap)
        return widen < 0 ? -value : value
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}
