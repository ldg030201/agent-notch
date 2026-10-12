import SwiftUI

/// 아일랜드 외곽선 치수. 목 · 몸통 · 반경은 프레임 기준(pt), 원점 · 노치는 패널 기준이고 모두 함께 애니메이션된다.
///
/// 모양은 위쪽 "목"(메뉴바 높이 구간)과 아래쪽 "몸통"으로 나뉜다.
/// - 목: 메뉴바 아이템을 가리지 않도록 좁게 (노치 + 허용된 날개, 또는 메뉴바 안 알약).
/// - 몸통: 메뉴바 아래에서만 넓어진다 (`menuBarBottom`, 전환 중간 프레임 포함). 목과 만나는 곳은 오목하게 이어진다.
///   넓은 노치에서 내용만 노치 아래 띠로 내릴 때는 몸통이 목보다 좁다 (목 아래 모서리가 볼록, 만나는 곳이 오목).
/// - 접힌 상태도 목 + (목과 같은 폭의) 몸통으로 둔다. 몸통이 생기고 없어지는 순간이 없어야 전환 중 모양이 튀지 않는다.
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
}

extension IslandShapeSpec: VectorArithmetic {
    private static let fields: [WritableKeyPath<IslandShapeSpec, CGFloat>] = [
        \.neckLeft, \.neckRight, \.neckHeight, \.bodyLeft, \.bodyRight,
        \.leftEar, \.rightEar, \.topRadius, \.bodyTopRadius, \.shoulderRadius, \.bottomRadius,
        \.originX, \.originY, \.notchMinX, \.notchWidth, \.notchHeight, \.menuBarBottom,
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

struct IslandShape: Shape {
    var spec: IslandShapeSpec
    /// 검은 배경에 뚫을 메뉴바 아이콘 구멍 (패널 기준). 애니메이션하지 않고 늘 진짜 아이콘 자리에 둔다
    var holes: [CGRect] = []

    var animatableData: IslandShapeSpec {
        get { spec }
        set { spec = newValue }
    }

    /// 반경 0.5 이하는 직선 모서리로 그린다
    static let minRadius: CGFloat = 0.5

    func path(in rect: CGRect) -> Path {
        let outline = Self.outline(spec, in: rect)
        guard !outline.isEmpty else { return Path() }
        let path = Self.path(outline)
        guard !holes.isEmpty else { return path }
        // 구멍은 패널 기준 → 지금(애니메이션 중간값) 프레임 위치만큼 옮겨 뺀다
        var cutouts = Path()
        for hole in holes {
            let local = hole.offsetBy(dx: rect.minX - spec.originX, dy: rect.minY - spec.originY)
            cutouts.addRoundedRect(
                in: local,
                cornerSize: CGSize(width: WingCutouts.cornerRadius, height: WingCutouts.cornerRadius),
                style: .continuous
            )
        }
        return path.subtracting(cutouts)
    }

    /// 스펙 → 실제 그릴 치수
    static func outline(_ spec: IslandShapeSpec, in rect: CGRect) -> IslandOutline {
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
        if o.bx1 - o.bx0 < 2 {
            o.bx0 = o.nx0
            o.bx1 = o.nx1
        }
        let height = o.bottom - o.top
        let neckHeight = min(max(0, spec.neckHeight), height)
        o.neckBottom = o.top + neckHeight
        let bodyHeight = height - neckHeight

        // 몸통이 목보다 넓은 쪽은 메뉴바 아래에서만 넓어진다.
        // - 계단 y 는 넓어진 폭이 0 → 6pt 일 동안 목 아래끝 → 메뉴바 아래끝으로 이어서 옮긴다 (폭 0 이면 어느 y 든 같은 모양)
        // - 메뉴바 아래 몸통 높이(아래 반경 제외)가 모자라면 넓어지는 폭을 그 높이의 4배까지로 줄인다
        //   (펼치기 시작 · 접히기 끝: 몸통이 먼저 아래로 내려온 뒤 옆으로 넓어진다)
        o.stepL = o.neckBottom
        o.stepR = o.neckBottom
        if spec.menuBarBottom > 0 {
            let barBottom = max(o.neckBottom, rect.minY + spec.menuBarBottom - spec.originY)
            let radius = clamp(spec.bottomRadius, 0, bodyHeight)
            let allowed = max(0, o.bottom - radius - barBottom) * 4
            func step(_ widen: CGFloat) -> CGFloat {
                o.neckBottom + clamp(widen / 6, 0, 1) * (barBottom - o.neckBottom)
            }
            // 줄인 폭으로 계단 y 를 정한다 (폭이 0 이면 계단도 목 아래끝 → 아래 모서리와 겹치지 않음)
            if o.widenL > 0 {
                o.bx0 = o.nx0 - min(o.widenL, allowed)
                o.stepL = step(o.widenL)
            }
            if o.widenR > 0 {
                o.bx1 = o.nx1 + min(o.widenR, allowed)
                o.stepR = step(o.widenR)
            }
        }

        // 귀와 위쪽 모서리 (목 안)
        let earLimit = min(neckHeight / 2, neckWidth / 4)
        o.earL = clamp(spec.leftEar, 0, min(o.nx0 - rect.minX, earLimit))
        o.earR = clamp(spec.rightEar, 0, min(rect.maxX - o.nx1, earLimit))
        let topLimit = min(neckWidth / 2, neckHeight)
        o.topRL = o.earL > eps ? 0 : clamp(spec.topRadius, 0, topLimit)
        o.topRR = o.earR > eps ? 0 : clamp(spec.topRadius, 0, topLimit)

        // 아래 모서리 (몸통 안)
        o.bottomR = clamp(spec.bottomRadius, 0, min((o.bx1 - o.bx0) / 2, bodyHeight))

        // 목 → 몸통 계단. 폭이 0 에 가까우면 반경도 0 으로 줄어 이어진다
        let stepWidthL = abs(o.widenL)
        let stepWidthR = abs(o.widenR)
        o.shoulderL = clamp(spec.shoulderRadius, 0, min(stepWidthL / 2, max(0, o.stepL - o.top - max(o.earL, o.topRL))))
        o.shoulderR = clamp(spec.shoulderRadius, 0, min(stepWidthR / 2, max(0, o.stepR - o.top - max(o.earR, o.topRR))))
        o.bodyTopL = clamp(spec.bodyTopRadius, 0, min(stepWidthL - o.shoulderL, max(0, o.bottom - o.stepL - o.bottomR)))
        o.bodyTopR = clamp(spec.bodyTopRadius, 0, min(stepWidthR - o.shoulderR, max(0, o.bottom - o.stepR - o.bottomR)))
        return o
    }

    static func path(_ o: IslandOutline) -> Path {
        let eps = minRadius
        let top = o.top
        var path = Path()

        // 위쪽 변 (왼쪽 → 오른쪽)
        if o.earL > eps {
            path.move(to: CGPoint(x: o.nx0 - o.earL, y: top))
        } else if o.topRL > eps {
            path.move(to: CGPoint(x: o.nx0, y: top + o.topRL))
            path.addArc(tangent1End: CGPoint(x: o.nx0, y: top), tangent2End: CGPoint(x: o.nx0 + o.topRL, y: top), radius: o.topRL)
        } else {
            path.move(to: CGPoint(x: o.nx0, y: top))
        }
        if o.earR > eps {
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
        if o.earL > eps {
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

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}
