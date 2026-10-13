import CoreGraphics
import SwiftUI

// 이음매 검사: 목(메뉴바 띠)과 몸통이 이어지는 곳이 끊기거나 물리는지 (전환 시트 · 정지 장면이 함께 돌린다).
// - 래스터: 모양(구멍 · 내용 없이, 실제와 같은 IslandShape 경로)을 2배로 칠해
//   열마다 띠 ↔ 몸통 사이 틈, 쪽마다 바깥 윤곽이 안으로 물린 곳(위아래보다 안쪽)을 찾는다.
// - 치수: 목 끝과 몸통 끝이 1–6pt 로 거의 겹친 이음매
//   · 두 모서리가 하나의 S 곡선으로 이어지지 않음 (사이에 턱이 남거나 볼록 · 볼록이 맞물림)
//   · 카드를 펼치고 접는 중에 목(노치 화면의 띠 · 메뉴바 알약) 끝이 움직이며 몸통 끝과 맞닿음
//     (띠가 날개처럼 펼쳐지는 순간 바깥 끝이 잘렸다 붙어 보임. 접힌 띠 ↔ 접힌 띠는 몸통 = 띠라 보지 않음)
//   시트 프레임 사이도 스프링 값을 촘촘히 훑는다.
// 아이콘 구멍은 일부러 뚫은 창이라 빼고 칠한다. 귀(목 위 바깥으로 휘는 모서리)는 화면 위 끝에 붙은 모양이라 틈으로 보지 않는다.

@MainActor
enum SnapshotSeamCheck {
    /// 래스터 배율 (스냅숏과 같은 2배)
    static let scale: CGFloat = 2
    /// 목 끝 · 몸통 끝이 이 범위로 가까우면 "거의 겹친 이음매"로 본다 (pt)
    static let nearJoint: ClosedRange<CGFloat> = 1...6
    /// 목 끝이 양 끝 상태 값에서 이보다 멀면 움직이는 중으로 본다 (pt)
    static let movingNeck: CGFloat = 1

    /// 전환 양 끝의 목(띠) 끝 (패널 기준 x). 카드 ↔ 접힌 상태 전환에서 노치 화면 띠, 노치 없는 화면은 메뉴바 알약 목만 (아니면 nil)
    struct Ends {
        var left: (CGFloat, CGFloat)
        var right: (CGFloat, CGFloat)

        init?(from: IslandLayout, to: IslandLayout) {
            // 한쪽은 펼친 카드(카드 폭 있음), 다른 쪽은 접힌 상태
            guard (from.cardWidth > 0) != (to.cardWidth > 0), from.compact != nil || to.compact != nil else { return nil }
            let notch = from.shape.notchWidth > 1 && to.shape.notchWidth > 1
            // 노치 없는 화면: 알약 ↔ 알약을 목으로 쓰는 카드 (메뉴바 아래 알약 · 점에서 펼친 카드는 목이 몸통과 같은 폭이거나 점이라 뺀다)
            let card = from.cardWidth > 0 ? from : to
            let compact = from.cardWidth > 0 ? to : from
            var pillNeck = false
            if case .pill = compact.compact, card.shape.neckLeft + card.shape.neckRight > 0.5 { pillNeck = true }
            guard notch || pillNeck else { return nil }
            let a = SnapshotShapeCheck.outline(from)
            let b = SnapshotShapeCheck.outline(to)
            left = (from.origin.x + a.nx0, to.origin.x + b.nx0)
            right = (from.origin.x + a.nx1, to.origin.x + b.nx1)
        }
    }

    /// 프레임 하나: 래스터 틈 · 물림 + 이음매 치수
    static func check(layout: IslandLayout, ends: Ends? = nil) -> [String] {
        let outline = SnapshotShapeCheck.outline(layout)
        guard !outline.isEmpty else { return [] }
        return rasterIssues(layout, outline: outline) + jointIssues(layout, outline: outline, ends: ends).map(\.text)
    }

    // MARK: 래스터

    /// 칠한 모양 (1바이트 = 1픽셀, 128 이상이면 검정)
    struct Raster {
        let width: Int
        let height: Int
        let pixels: [UInt8]
        /// 프레임 바깥 여백 (pt). 노치 보호로 경로가 프레임 밖으로 0.5pt 까지 나갈 수 있다
        let pad: CGFloat
        let scale: CGFloat

        func filled(_ col: Int, _ row: Int) -> Bool { pixels[row * width + col] >= 128 }
        /// 픽셀 가운데 → 프레임 기준 pt
        func x(_ col: Int) -> CGFloat { (CGFloat(col) + 0.5) / scale - pad }
        func y(_ row: Int) -> CGFloat { (CGFloat(row) + 0.5) / scale - pad }
        func row(_ y: CGFloat) -> Int { Int(((y + pad) * scale).rounded(.down)) }
    }

    /// 레이아웃의 모양 (구멍 없이)
    static func rasterize(_ layout: IslandLayout) -> Raster? {
        rasterize(IslandShape(spec: layout.shapeSpec).path(in: CGRect(origin: .zero, size: layout.size)), size: layout.size)
    }

    static func rasterize(_ path: Path, size: CGSize) -> Raster? {
        let pad: CGFloat = 2
        let width = Int(((size.width + pad * 2) * scale).rounded(.up))
        let height = Int(((size.height + pad * 2) * scale).rounded(.up))
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                  space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // 위쪽이 0 인 SwiftUI 좌표로 칠한다 (메모리 첫 줄 = 맨 위)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: pad, y: pad)
        context.addPath(path.cgPath)
        context.setFillColor(gray: 1, alpha: 1)
        context.fillPath()
        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: width * height)
        return Raster(width: width, height: height, pixels: Array(UnsafeBufferPointer(start: buffer, count: width * height)), pad: pad, scale: scale)
    }

    static func rasterIssues(_ layout: IslandLayout, outline o: IslandOutline) -> [String] {
        guard let raster = rasterize(layout) else { return ["이음매 래스터를 만들지 못함"] }
        return rasterIssues(raster, outline: o, originX: layout.origin.x)
    }

    /// - originX: 보고에 쓸 프레임 왼쪽의 패널 기준 x
    static func rasterIssues(_ raster: Raster, outline o: IslandOutline, originX: CGFloat) -> [String] {
        var issues: [String] = []
        let ear = max(o.earL, o.earR)
        let earRowEnd = raster.row(o.top + ear + 0.75)
        let topRow = raster.row(o.top + 0.5)

        // 1) 열마다 검은 구간이 둘 이상이면 띠 ↔ 몸통 사이가 끊긴 것 (귀 아래는 제외)
        var gaps: [(col: Int, from: CGFloat, to: CGFloat)] = []
        for col in 0..<raster.width {
            var runs: [(start: Int, end: Int)] = []
            var start: Int?
            for row in 0..<raster.height {
                if raster.filled(col, row) {
                    if start == nil { start = row }
                } else if let s = start {
                    runs.append((s, row - 1))
                    start = nil
                }
            }
            if let s = start { runs.append((s, raster.height - 1)) }
            guard runs.count >= 2 else { continue }
            let x = raster.x(col)
            // 귀: 목 옆면 바깥, 화면 위 끝에서 시작해 귀 반경 안에서 끝나는 구간
            if (x < o.nx0 || x > o.nx1), runs[0].start <= topRow + 1, runs[0].end <= earRowEnd {
                runs.removeFirst()
            }
            guard runs.count >= 2 else { continue }
            gaps.append((col, raster.y(runs[0].end) + 0.25, raster.y(runs[1].start) - 0.25))
        }
        for group in groups(gaps.map(\.col)) {
            let members = gaps.filter { group.contains($0.col) }
            let from = members.map(\.from).min() ?? 0
            let to = members.map(\.to).max() ?? 0
            issues.append(String(
                format: "이음매 끊김 x %.1f…%.1f (y %.1f…%.1f 비어 있음)",
                originX + raster.x(group.lowerBound), originX + raster.x(group.upperBound), from, to
            ))
        }

        // 2) 쪽마다 바깥 윤곽: 귀 아래에서 위 · 아래 줄보다 안쪽으로 들어간 줄이 있으면 물림
        let firstRow = max(0, earRowEnd + 1)
        var left: [Int?] = Array(repeating: nil, count: raster.height)
        var right: [Int?] = Array(repeating: nil, count: raster.height)
        for row in firstRow..<raster.height {
            var minCol: Int?
            var maxCol: Int?
            for col in 0..<raster.width where raster.filled(col, row) {
                if minCol == nil { minCol = col }
                maxCol = col
            }
            left[row] = minCol
            right[row] = maxCol
        }
        // 바깥쪽 정도 (클수록 바깥): 왼쪽은 −열, 오른쪽은 +열
        for (side, outward) in [("L", left.map { $0.map { -$0 } }), ("R", right)] {
            let rows = outward.indices.filter { outward[$0] != nil }
            guard rows.count > 2 else { continue }
            var prefix: [Int] = []
            var best = Int.min
            for row in rows {
                prefix.append(best)
                best = max(best, outward[row]!)
            }
            var suffix: [Int] = Array(repeating: Int.min, count: rows.count)
            best = Int.min
            for index in rows.indices.reversed() {
                suffix[index] = best
                best = max(best, outward[rows[index]]!)
            }
            // 1pt(2px) 넘게 안으로 물린 줄
            var bitten: [Int] = []
            for (index, row) in rows.enumerated() {
                guard prefix[index] != Int.min, suffix[index] != Int.min else { continue }
                if min(prefix[index], suffix[index]) - outward[row]! >= 2 { bitten.append(row) }
            }
            for group in groups(bitten) {
                issues.append(String(
                    format: "이음매 물림 %@ y %.1f…%.1f (위 · 아래보다 안쪽)", side, raster.y(group.lowerBound), raster.y(group.upperBound)
                ))
            }
        }
        return issues
    }

    /// 래스터 검사 자체 점검: 일부러 끊고 물린 모양을 찾아내는지 (못 찾으면 문제 목록)
    static func selfTest() -> [String] {
        var problems: [String] = []
        var o = IslandOutline()
        o.top = 0
        o.nx0 = 40
        o.nx1 = 160
        o.bx0 = 20
        o.bx1 = 180
        let size = CGSize(width: 200, height: 80)
        // 띠(0…33)와 몸통(35…80) 사이 2pt 틈
        var gap = Path()
        gap.addRect(CGRect(x: 40, y: 0, width: 120, height: 33))
        gap.addRect(CGRect(x: 20, y: 35, width: 160, height: 45))
        if let raster = rasterize(gap, size: size), !rasterIssues(raster, outline: o, originX: 0).contains(where: { $0.contains("끊김") }) {
            problems.append("띠 ↔ 몸통 틈을 못 찾음")
        }
        // 목 아래 볼록 모서리와 몸통 위 볼록 모서리가 맞물려 안으로 물린 모양
        var bite = Path()
        bite.addRoundedRect(in: CGRect(x: 20, y: 0, width: 160, height: 36), cornerSize: CGSize(width: 6, height: 6))
        bite.addRoundedRect(in: CGRect(x: 20, y: 35, width: 160, height: 45), cornerSize: CGSize(width: 6, height: 6))
        if let raster = rasterize(bite, size: size), !rasterIssues(raster, outline: o, originX: 0).contains(where: { $0.contains("물림") }) {
            problems.append("볼록 · 볼록 물림을 못 찾음")
        }
        // 이어진 모양은 문제 없음
        var whole = Path()
        whole.addRoundedRect(in: CGRect(x: 20, y: 0, width: 160, height: 80), cornerSize: CGSize(width: 12, height: 12))
        if let raster = rasterize(whole, size: size), !rasterIssues(raster, outline: o, originX: 0).isEmpty {
            problems.append("이어진 모양을 문제로 봄")
        }
        return problems
    }

    /// 이어진 정수끼리 묶는다
    private static func groups(_ values: [Int]) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for value in values.sorted() {
            if let last = result.last, value <= last.upperBound + 1 {
                result[result.count - 1] = last.lowerBound...value
            } else {
                result.append(value...value)
            }
        }
        return result
    }

    // MARK: 이음매 치수

    struct JointIssue {
        let side: String
        let text: String
    }

    /// 목 끝 · 몸통 끝이 1–6pt 로 거의 겹친 이음매.
    /// - 몸통이 넓은 쪽은 목 쪽 오목 + 몸통 위 볼록, 좁은 쪽은 목 아래 볼록 + 몸통 쪽 오목이 차이를 다 채워 하나의 S 곡선이어야 한다
    /// - 목(띠) 끝이 움직이는 중이면 안 된다 (`ends`: 전환 양 끝의 목 끝)
    static func jointIssues(_ layout: IslandLayout, outline o: IslandOutline, ends: Ends?) -> [JointIssue] {
        guard !o.isEmpty else { return [] }
        var issues: [JointIssue] = []
        let sides: [(String, CGFloat, CGFloat, CGFloat, CGFloat, (CGFloat, CGFloat)?)] = [
            ("L", o.widenL, o.shoulderL, o.bodyTopL, layout.origin.x + o.nx0, ends?.left),
            ("R", o.widenR, o.shoulderR, o.bodyTopR, layout.origin.x + o.nx1, ends?.right),
        ]
        for (side, widen, shoulder, bodyTop, neckEnd, neckEnds) in sides {
            let gap = abs(widen)
            guard nearJoint.contains(gap) else { continue }
            let concave = widen > 0 ? shoulder : bodyTop
            let convex = widen > 0 ? bodyTop : shoulder
            let ledge = gap - concave - convex
            if ledge > 0.5 {
                issues.append(JointIssue(side: side, text: String(
                    format: "이음매 %@ 목 끝 · 몸통 끝 %.1fpt 차이에 턱 %.1fpt (오목 %.1f · 볼록 %.1f)",
                    side, widen, ledge, concave, convex
                )))
            } else if let (a, b) = neckEnds, abs(neckEnd - a) > movingNeck, abs(neckEnd - b) > movingNeck {
                issues.append(JointIssue(side: side, text: String(
                    format: "이음매 %@ 띠 끝이 움직이는 중(%.0f → %.0f, 지금 %.1f) 몸통 끝과 %.1fpt",
                    side, a, b, neckEnd, widen
                )))
            }
        }
        return issues
    }

    /// 스프링 값 0 → 최대값을 촘촘히 훑어 시트 프레임 사이의 이음매 문제를 찾는다 (쪽마다 이어진 구간 하나로 보고)
    static func denseJointIssues(from: IslandLayout, to: IslandLayout, maxValue: Double, timeline: SnapshotTimeline) -> [String] {
        let step = 0.001
        let ends = Ends(from: from, to: to)
        var reports: [String] = []
        var open: [String: (start: Double, last: Double, text: String)] = [:]
        func close(_ side: String) {
            guard let run = open.removeValue(forKey: side) else { return }
            let ms0 = timeline.time(forValue: min(run.start, 1))
            let ms1 = timeline.time(forValue: min(run.last, 1))
            reports.append(String(format: "v %.3f…%.3f (≈%.0f…%.0fms) ", run.start, run.last, ms0, ms1) + run.text)
        }
        var v = 0.0
        while v <= maxValue + step / 2 {
            let layout = SnapshotInterpolation.mix(from, to, v)
            let found = jointIssues(layout, outline: SnapshotShapeCheck.outline(layout), ends: ends)
            let sides = Set(found.map(\.side))
            for side in ["L", "R"] where !sides.contains(side) { close(side) }
            for issue in found {
                if var run = open[issue.side] {
                    run.last = v
                    open[issue.side] = run
                } else {
                    open[issue.side] = (v, v, issue.text)
                }
            }
            v += step
        }
        close("L")
        close("R")
        return reports
    }
}
