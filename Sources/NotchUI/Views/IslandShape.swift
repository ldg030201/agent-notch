import SwiftUI

/// 아일랜드 외곽선 치수. 모든 값은 프레임 기준(pt)이고 애니메이션된다.
///
/// 모양은 위쪽 "목"(메뉴바 높이 구간)과 아래쪽 "몸통"으로 나뉜다.
/// - 목: 메뉴바 아이템을 가리지 않도록 좁게 (노치 + 허용된 날개, 또는 메뉴바 안 알약).
/// - 몸통: 메뉴바 아래에서만 넓어진다. 목과 만나는 곳은 오목하게 이어진다.
///   넓은 노치에서 내용만 노치 아래 띠로 내릴 때는 몸통이 목보다 좁다 (목 아래 모서리가 볼록, 만나는 곳이 오목).
/// - 목 높이가 프레임 높이 이상이면 목만 있는 모양 (접힌 상태).
/// - 노치 화면은 목 위쪽 모서리에 바깥으로 휘는 "귀"를 둬서 하드웨어 노치와 자연스럽게 잇는다.
struct IslandShapeSpec: Equatable {
    /// 프레임 왼쪽/오른쪽 끝에서 목 옆면까지 거리
    var neckLeft: CGFloat = 0
    var neckRight: CGFloat = 0
    /// 목 높이
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
}

extension IslandShapeSpec: VectorArithmetic {
    private static let fields: [WritableKeyPath<IslandShapeSpec, CGFloat>] = [
        \.neckLeft, \.neckRight, \.neckHeight, \.bodyLeft, \.bodyRight,
        \.leftEar, \.rightEar, \.topRadius, \.bodyTopRadius, \.shoulderRadius, \.bottomRadius,
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

struct IslandShape: Shape {
    var spec: IslandShapeSpec

    var animatableData: IslandShapeSpec {
        get { spec }
        set { spec = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 1, rect.height > 1 else { return Path() }
        let eps: CGFloat = 0.5
        let top = rect.minY
        let bottom = rect.maxY

        // 목
        let nx0 = rect.minX + max(0, spec.neckLeft)
        let nx1 = rect.maxX - max(0, spec.neckRight)
        let neckWidth = nx1 - nx0
        guard neckWidth > 1 else { return Path() }
        let neckHeight = min(max(0, spec.neckHeight), rect.height)
        let hasBody = neckHeight < rect.height - eps

        // 몸통 (목보다 넓거나 좁을 수 있다)
        var bx0 = hasBody ? rect.minX + max(0, spec.bodyLeft) : nx0
        var bx1 = hasBody ? rect.maxX - max(0, spec.bodyRight) : nx1
        if bx1 - bx0 < 2 {
            bx0 = nx0
            bx1 = nx1
        }
        let neckBottom = top + (hasBody ? neckHeight : rect.height)

        // 귀와 위쪽 모서리
        let earLimit = min(neckHeight / 2, neckWidth / 4)
        let earL = clamp(spec.leftEar, 0, min(nx0 - rect.minX, earLimit))
        let earR = clamp(spec.rightEar, 0, min(rect.maxX - nx1, earLimit))
        let topLimit = min(neckWidth / 2, (hasBody ? neckHeight : rect.height) / 2)
        let topRL = earL > eps ? 0 : clamp(spec.topRadius, 0, topLimit)
        let topRR = earR > eps ? 0 : clamp(spec.topRadius, 0, topLimit)

        // 아래 모서리
        let bodyWidth = bx1 - bx0
        let bodyHeight = hasBody ? rect.height - neckHeight : rect.height - max(earL, earR, topRL, topRR)
        let bottomR = clamp(spec.bottomRadius, 0, min(bodyWidth / 2, bodyHeight))

        // 어깨 (목 → 몸통). 몸통이 좁으면 넓어지는 폭이 음수
        let widenL = abs(nx0 - bx0)
        let widenR = abs(bx1 - nx1)
        let shoulderLimit = max(0, neckHeight - max(earL, topRL, earR, topRR))
        let shoulderL = clamp(spec.shoulderRadius, 0, min(widenL / 2, shoulderLimit))
        let shoulderR = clamp(spec.shoulderRadius, 0, min(widenR / 2, shoulderLimit))
        let bodyTopLimit = max(0, rect.height - neckHeight - bottomR)
        let bodyTopL = clamp(spec.bodyTopRadius, 0, min(widenL - shoulderL, bodyTopLimit))
        let bodyTopR = clamp(spec.bodyTopRadius, 0, min(widenR - shoulderR, bodyTopLimit))

        var path = Path()

        // 위쪽 변 (왼쪽 → 오른쪽)
        if earL > eps {
            path.move(to: CGPoint(x: nx0 - earL, y: top))
        } else if topRL > eps {
            path.move(to: CGPoint(x: nx0, y: top + topRL))
            path.addArc(tangent1End: CGPoint(x: nx0, y: top), tangent2End: CGPoint(x: nx0 + topRL, y: top), radius: topRL)
        } else {
            path.move(to: CGPoint(x: nx0, y: top))
        }
        if earR > eps {
            path.addLine(to: CGPoint(x: nx1 + earR, y: top))
            path.addQuadCurve(to: CGPoint(x: nx1, y: top + earR), control: CGPoint(x: nx1, y: top))
        } else if topRR > eps {
            path.addLine(to: CGPoint(x: nx1 - topRR, y: top))
            path.addArc(tangent1End: CGPoint(x: nx1, y: top), tangent2End: CGPoint(x: nx1, y: top + topRR), radius: topRR)
        } else {
            path.addLine(to: CGPoint(x: nx1, y: top))
        }

        // 오른쪽 변 (위 → 아래)
        if hasBody, widenR > eps {
            corner(&path, CGPoint(x: nx1, y: neckBottom), CGPoint(x: bx1, y: neckBottom), shoulderR)
            corner(&path, CGPoint(x: bx1, y: neckBottom), CGPoint(x: bx1, y: bottom), bodyTopR)
        }
        corner(&path, CGPoint(x: bx1, y: bottom), CGPoint(x: bx0, y: bottom), bottomR)

        // 왼쪽 변 (아래 → 위)
        corner(&path, CGPoint(x: bx0, y: bottom), CGPoint(x: bx0, y: top), bottomR)
        if hasBody, widenL > eps {
            corner(&path, CGPoint(x: bx0, y: neckBottom), CGPoint(x: nx0, y: neckBottom), bodyTopL)
            corner(&path, CGPoint(x: nx0, y: neckBottom), CGPoint(x: nx0, y: top), shoulderL)
        }
        if earL > eps {
            path.addLine(to: CGPoint(x: nx0, y: top + earL))
            path.addQuadCurve(to: CGPoint(x: nx0 - earL, y: top), control: CGPoint(x: nx0, y: top))
        }
        path.closeSubpath()
        return path
    }

    /// 꼭짓점 `vertex` 를 반경 `radius` 로 둥글게 돌아 `next` 방향으로 이어간다 (오목/볼록 모두).
    private func corner(_ path: inout Path, _ vertex: CGPoint, _ next: CGPoint, _ radius: CGFloat) {
        if radius > 0.5 {
            path.addArc(tangent1End: vertex, tangent2End: next, radius: radius)
        } else {
            path.addLine(to: vertex)
        }
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}
