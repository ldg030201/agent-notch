import CoreGraphics
import SwiftUI

// 부분 1 검사: 카드 ↔ 접힌 상태 전환에서 위쪽 접힌 모양(부분 1)이 그대로인지 (전환 시트가 프레임 · 촘촘한 훑기로 돌린다).
// - 부분 1 = 접힌 상태의 모양. 펼치고 접는 동안 자리 · 폭 · 높이 · 위 반경 · 제 아래 모서리가 바뀌면 안 된다 (±0.5pt).
//   그린 부분 1 층(`IslandShape.part1Outline`)을 잰다. 부분 1 층이 없는 모양(예전 모델)은 목 + 목과 맞닿은 몸통을 부분 1 로 본다
// - 부분 2 를 그리는 주 외곽선의 목은 부분 1 위 조각과 같은 가로 자리여야 한다 (목이 부분 1 밖으로 나오면 부분 1 이 커져 보인다)
// - 카드 상단 행이 부분 1 안에 있으면 안 된다 (카드 내용은 모두 부분 2)
// - 부분 2(카드 몸통)가 부분 1 과 옆면이 맞닿은 채(1pt 미만) 부분 1 아래로 2pt 넘게 이어지는 순간이 한 프레임(16ms)보다 길면
//   부분 1 이 늘어난 것처럼 보인다 ("부분 1 이 부분 2 크기를 따라감")

@MainActor
enum SnapshotPart1Check {
    static let tolerance: CGFloat = 0.5
    /// 부분 1 아래로 이어진 몸통을 늘어난 부분 1 로 볼 높이 (pt)
    static let mergedDepth: CGFloat = 2
    /// 맞닿은 채 이어지는 순간이 이보다 길면 위반 (ms, 60fps 한 프레임)
    static let mergedMaxMs: Double = 16

    /// 부분 1 치수 (패널 기준). 아래 모서리는 드러나 있을 때만 (부분 2 가 덮으면 nil)
    struct Geometry {
        var minX: CGFloat
        var maxX: CGFloat
        var top: CGFloat
        var bottom: CGFloat
        var topRL: CGFloat
        var topRR: CGFloat
        var bottomRL: CGFloat?
        var bottomRR: CGFloat?
    }

    /// 전환 양 끝: 한쪽은 펼친 카드, 다른 쪽은 접힌 상태 (아니면 nil — 검사하지 않음).
    /// `cardToCard` 면 카드 → 카드 (열린 동안 접힌 내용이 바뀜): 전 카드의 부분 1 이 그대로여야 한다
    struct Ends {
        let card: IslandLayout
        /// 기준 모양 치수 (접힌 상태, 카드 → 카드면 전 카드)
        let reference: Geometry
        let cardToCard: Bool

        @MainActor init?(from: IslandLayout, to: IslandLayout, cardToCard: Bool = false) {
            let fromCard = from.compact == nil && from.cardWidth > 0
            let toCard = to.compact == nil && to.cardWidth > 0
            if cardToCard {
                guard fromCard, toCard, from.shape.part1.width > 1 else { return nil }
                card = to
                self.cardToCard = true
                reference = SnapshotPart1Check.geometry(from)
                return
            }
            guard fromCard != toCard else { return nil }
            let compact = fromCard ? to : from
            card = fromCard ? from : to
            self.cardToCard = false
            guard compact.compact != nil else { return nil }
            reference = SnapshotPart1Check.geometry(compact)
        }
    }

    /// 그린 모양에서 부분 1 치수.
    /// 목(위쪽 조각)이 부분 1 이고, 몸통이 양옆 모두 목과 맞닿아(0.5pt 미만) 한 덩어리면 그 몸통까지 부분 1 로 본다
    static func geometry(_ layout: IslandLayout) -> Geometry {
        let x = layout.origin.x
        let y = layout.origin.y
        if let p = IslandShape.part1Outline(layout.shapeSpec, in: CGRect(origin: .zero, size: layout.size)), !p.isEmpty {
            return Geometry(
                minX: x + p.nx0, maxX: x + p.nx1, top: y + p.top, bottom: y + p.bottom,
                topRL: p.topRL, topRR: p.topRR, bottomRL: p.bottomR, bottomRR: p.bottomR
            )
        }
        let o = SnapshotShapeCheck.outline(layout)
        var g = Geometry(
            minX: x + o.nx0, maxX: x + o.nx1, top: y + o.top, bottom: y + o.neckBottom,
            topRL: o.topRL, topRR: o.topRR
        )
        if abs(o.widenL) < tolerance, abs(o.widenR) < tolerance {
            g.bottom = y + o.bottom
            g.bottomRL = o.bottomR
            g.bottomRR = o.bottomR
        } else {
            g.bottomRL = o.widenL < 0 ? o.shoulderL : nil
            g.bottomRR = o.widenR < 0 ? o.shoulderR : nil
        }
        return g
    }

    /// 프레임 하나: 기준(접힌 상태) 부분 1 과 다른 치수
    static func issues(_ layout: IslandLayout, ends: Ends) -> [String] {
        let g = geometry(layout)
        let r = ends.reference
        var issues: [String] = []
        func compare(_ name: String, _ value: CGFloat?, _ expected: CGFloat?) {
            guard let value, let expected, abs(value - expected) > tolerance else { return }
            issues.append(String(format: "%@ %.1f (접힌 상태 %.1f)", name, value, expected))
        }
        compare("왼쪽", g.minX, r.minX)
        compare("폭", g.maxX - g.minX, r.maxX - r.minX)
        compare("위", g.top, r.top)
        compare("높이", g.bottom - g.top, r.bottom - r.top)
        compare("위반경L", g.topRL, r.topRL)
        compare("위반경R", g.topRR, r.topRR)
        compare("아래반경L", g.bottomRL, r.bottomRL)
        compare("아래반경R", g.bottomRR, r.bottomRR)
        // 부분 1 과 합쳐 그리는 주 외곽선의 목: 부분 1 위 조각과 같은 가로 자리 · 같은 위
        if case let .union(main, part1) = IslandShape.drawn(layout.shapeSpec, in: CGRect(origin: .zero, size: layout.size)) {
            if abs(main.nx0 - part1.nx0) > tolerance || abs(main.nx1 - part1.nx1) > tolerance || abs(main.top - part1.top) > tolerance {
                issues.append(String(
                    format: "목 %.1f…%.1f 이 부분 1 위 조각 %.1f…%.1f 와 어긋남",
                    layout.origin.x + main.nx0, layout.origin.x + main.nx1, layout.origin.x + part1.nx0, layout.origin.x + part1.nx1
                ))
            }
        }
        return issues.isEmpty ? [] : ["부분 1 " + issues.joined(separator: ", ")]
    }

    /// 카드 상단 행이 부분 1 안에 있는지 (카드 쪽 정지 모양)
    static func headerIssues(ends: Ends) -> [String] {
        let card = ends.card
        let headerTop = card.origin.y + card.header.top
        guard card.header.height > 0, headerTop < ends.reference.bottom - tolerance else { return [] }
        return [String(format: "부분 1 상단 행이 부분 1 안 (상단 행 y %.1f, 부분 1 아래 %.1f)", headerTop, ends.reference.bottom)]
    }

    /// 부분 2 가 부분 1 과 옆면이 맞닿은 채 부분 1 아래로 이어지는지 (쪽 이름, 이어진 깊이)
    static func merged(_ layout: IslandLayout, ends: Ends) -> (side: String, depth: CGFloat)? {
        // 카드 → 카드는 몸통이 늘 부분 1 아래에 있다 (늘어나 보이는 순간 없음)
        guard !ends.cardToCard else { return nil }
        let o = SnapshotShapeCheck.outline(layout)
        let depth = layout.origin.y + o.bottom - ends.reference.bottom
        guard depth > mergedDepth else { return nil }
        if abs(o.widenL) < 1 { return ("L", depth) }
        if abs(o.widenR) < 1 { return ("R", depth) }
        return nil
    }

    /// 스프링 값 0 → 최대값을 촘촘히 훑어 부분 1 이 바뀌는 구간 · 맞닿아 늘어나 보이는 구간 (이어진 구간 하나로 보고)
    static func dense(ends: Ends, from: IslandLayout, to: IslandLayout, maxValue: Double, timeline: SnapshotTimeline) -> (reports: [String], mergedRanges: [ClosedRange<Double>]) {
        let step = 0.0005
        var reports: [String] = []
        var mergedRanges: [ClosedRange<Double>] = []
        var shapeRun: (start: Double, last: Double, text: String)?
        var mergedRun: (start: Double, last: Double, text: String)?
        func ms(_ v: Double) -> Double { v <= 1 ? timeline.time(forValue: v) : timeline.spring.peak.time * 1000 }
        func closeShape() {
            guard let run = shapeRun else { return }
            reports.append(String(format: "v %.4f…%.4f (≈%.0f…%.0fms) ", run.start, run.last, ms(run.start), ms(run.last)) + run.text)
            shapeRun = nil
        }
        func closeMerged() {
            guard let run = mergedRun else { return }
            let duration = ms(run.last) - ms(run.start)
            if duration > mergedMaxMs {
                reports.append(String(format: "v %.4f…%.4f (≈%.0f…%.0fms, %.0fms) ", run.start, run.last, ms(run.start), ms(run.last), duration) + run.text)
                mergedRanges.append(run.start...run.last)
            }
            mergedRun = nil
        }
        var v = 0.0
        while v <= maxValue + step / 2 {
            let layout = SnapshotInterpolation.mix(from, to, v)
            let found = issues(layout, ends: ends)
            if let text = found.first {
                if shapeRun == nil { shapeRun = (v, v, text) } else { shapeRun?.last = v }
            } else {
                closeShape()
            }
            if let hit = merged(layout, ends: ends) {
                let text = String(format: "부분 1 늘어나 보임 %@ (부분 2 가 옆면을 맞댄 채 %.1fpt 아래까지)", hit.side, hit.depth)
                if mergedRun == nil { mergedRun = (v, v, text) } else { mergedRun?.last = v }
            } else {
                closeMerged()
            }
            v += step
        }
        closeShape()
        closeMerged()
        return (reports, mergedRanges)
    }
}
