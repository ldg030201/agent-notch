import SwiftUI

/// 아일랜드 외곽선.
/// - 노치 화면: 위쪽 모서리에 바깥으로 휘는 오목한 "귀"를 둬서 하드웨어 노치와 자연스럽게 이어진다.
/// - 노치 없는 화면: 위아래 모두 둥근 알약.
/// 아래 모서리 반경은 크기에 따라 커진다 (접힘 ~12, 피크/권한 ~22, 펼침 ~26).
struct IslandShape: Shape {
    var earRadius: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(earRadius, AnimatablePair(topRadius, bottomRadius)) }
        set {
            earRadius = newValue.first
            topRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }

        let ear = max(0, min(earRadius, rect.width / 4, rect.height / 2))
        let left = rect.minX + ear
        let right = rect.maxX - ear
        let top = rect.minY
        let bottom = rect.maxY
        let bodyWidth = right - left
        let hasEars = ear > 0.01

        let topR = hasEars ? 0 : max(0, min(topRadius, bodyWidth / 2, rect.height / 2))
        let bottomR = max(0, min(bottomRadius, bodyWidth / 2, rect.height - max(topR, ear)))

        var path = Path()
        if hasEars {
            path.move(to: CGPoint(x: rect.minX, y: top))
            path.addQuadCurve(to: CGPoint(x: left, y: top + ear), control: CGPoint(x: left, y: top))
        } else {
            path.move(to: CGPoint(x: left, y: top + topR))
            corner(&path, CGPoint(x: left, y: top), CGPoint(x: left + topR, y: top), topR)
            path.addLine(to: CGPoint(x: right - topR, y: top))
            corner(&path, CGPoint(x: right, y: top), CGPoint(x: right, y: top + topR), topR)
        }

        if hasEars {
            path.addLine(to: CGPoint(x: left, y: bottom - bottomR))
            corner(&path, CGPoint(x: left, y: bottom), CGPoint(x: left + bottomR, y: bottom), bottomR)
            path.addLine(to: CGPoint(x: right - bottomR, y: bottom))
            corner(&path, CGPoint(x: right, y: bottom), CGPoint(x: right, y: bottom - bottomR), bottomR)
            path.addLine(to: CGPoint(x: right, y: top + ear))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: top), control: CGPoint(x: right, y: top))
        } else {
            path.addLine(to: CGPoint(x: right, y: bottom - bottomR))
            corner(&path, CGPoint(x: right, y: bottom), CGPoint(x: right - bottomR, y: bottom), bottomR)
            path.addLine(to: CGPoint(x: left + bottomR, y: bottom))
            corner(&path, CGPoint(x: left, y: bottom), CGPoint(x: left, y: bottom - bottomR), bottomR)
        }
        path.closeSubpath()
        return path
    }

    /// 꼭짓점 `vertex` 를 반경 `radius` 로 둥글게 돌아 `next` 방향으로 이어간다.
    private func corner(_ path: inout Path, _ vertex: CGPoint, _ next: CGPoint, _ radius: CGFloat) {
        if radius > 0.5 {
            path.addArc(tangent1End: vertex, tangent2End: next, radius: radius)
        } else {
            path.addLine(to: vertex)
        }
    }
}
