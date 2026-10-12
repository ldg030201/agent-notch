import CoreGraphics

// 넓은 노치(날개) 모드에서 메뉴바 아이콘을 다루는 순수 계산.
// - 아이콘 위치를 알면(손쉬운 사용) 검은 날개에 둥근 구멍을 뚫어 진짜 아이콘이 날개 위에 보이게 한다.
// - 모르면 마우스를 올린 쪽 날개가 노치 안으로 들어가 비켜준다 (`WingSides` 로 표시).

/// 날개 쪽
struct WingSides: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let left = WingSides(rawValue: 1 << 0)
    static let right = WingSides(rawValue: 1 << 1)
}

/// 날개 안 내용 배치
enum WingArrangement: Equatable, Sendable {
    /// 왼쪽 = 상태 (+ 프로젝트), 오른쪽 = (툴 +) `+N −M`
    case split
    /// 왼쪽 날개 하나에 모음 (노치 쪽으로 붙임)
    case left
    /// 오른쪽 날개 하나에 모음 (노치 쪽으로 붙임)
    case right
    /// 날개는 검게 두고 내용은 노치 아래 띠에
    case strip
}

/// 넓은 노치 · 노치 옆 날개의 모양과 내용 자리
struct WingsSpec: Equatable, Sendable {
    /// 검은 날개 폭 (노치 가장자리부터 바깥쪽, 귀 제외). 비켜준 쪽도 원래 폭을 둔다 (`hidden` 참고)
    var left: CGFloat
    var right: CGFloat
    var items: CompactItems
    var arrangement: WingArrangement
    /// 내용 자리 폭 (노치 가장자리부터 바깥쪽, 여백 포함). 아이콘 구멍이 있으면 첫 구멍 앞까지. 0 이면 그쪽 내용 없음
    var leftSpan: CGFloat
    var rightSpan: CGFloat
    /// 내용 자리 바깥쪽 여백 (날개 끝이면 넓게, 아이콘 구멍 앞이면 좁게)
    var leftOuterPad: CGFloat
    var rightOuterPad: CGFloat
    /// 아이콘이 비쳐 보이게 뚫을 구멍 (패널 기준: x 는 화면 왼쪽부터, y 는 화면 위부터)
    var holes: [CGRect] = []
    /// 마우스를 올려 비켜준 쪽 (폭 0 으로 그리고 내용은 숨김)
    var hidden: WingSides = []

    var visibleLeft: CGFloat { hidden.contains(.left) ? 0 : left }
    var visibleRight: CGFloat { hidden.contains(.right) ? 0 : right }

    /// 아이콘 구멍 없이 날개 폭 그대로 내용을 두는 기본형
    static func plain(left: CGFloat, right: CGFloat, items: CompactItems, hidden: WingSides = []) -> WingsSpec {
        let arrangement: WingArrangement = left > 0 && right > 0 ? .split : (left > 0 ? .left : .right)
        return WingsSpec(
            left: left,
            right: right,
            items: items,
            arrangement: arrangement,
            leftSpan: arrangement == .right ? 0 : left,
            rightSpan: arrangement == .left ? 0 : right,
            leftOuterPad: IslandMetrics.wingPadding,
            rightOuterPad: IslandMetrics.wingPadding,
            hidden: hidden
        )
    }
}

/// 마우스를 올리면 비켜줄 날개 자리 (패널 기준, 귀 포함 · 메뉴바 높이)
struct WingBands: Equatable, Sendable {
    var left: CGRect?
    var right: CGRect?

    static let none = WingBands()
    var isEmpty: Bool { left == nil && right == nil }
}

/// 메뉴바 아이템 사각형 → 날개 구멍 · 날개 끝 · 내용 자리 계산
enum WingCutouts {
    enum Side { case left, right }

    /// 아이콘 하나 (노치 가장자리부터 바깥쪽으로 잰 구간)
    struct Item: Equatable {
        var start: CGFloat
        var end: CGFloat
        /// 패널 기준 사각형 (노치 쪽은 노치 가장자리까지 자름)
        var frame: CGRect
    }

    /// 구멍 = 아이템 사각형을 좌우 3pt, 위아래 2pt 넓힌 것
    static let marginX: CGFloat = 3
    static let marginY: CGFloat = 2
    static let cornerRadius: CGFloat = 6
    /// 구멍 위아래로 남길 검정 테두리 (아이템이 메뉴바 높이 전체여도 날개 안 창처럼 보이게)
    static let minBorder: CGFloat = 4
    /// 아이콘을 품은 날개 끝에서 구멍 뒤로 남길 검정 폭
    static let edgePad: CGFloat = 6
    /// 날개 끝이 아이템 안쪽으로 이 정도까지 걸치는 건 자른 것으로 보지 않는다 (아이템 사각형 여백)
    static let tolerance: CGFloat = 2
    /// 이보다 좁은 날개는 없애는 편이 낫다
    static let minWing: CGFloat = 12

    /// 노치 한쪽의 아이템 구간 (노치 뒤에 완전히 숨은 것은 제외, 노치에서 가까운 순)
    static func items(_ frames: [CGRect], side: Side, notchMinX: CGFloat, notchMaxX: CGFloat) -> [Item] {
        var result: [Item] = []
        for frame in frames where frame.width >= 1 {
            switch side {
            case .right:
                guard frame.maxX > notchMaxX + 1 else { continue }
                let clipped = CGRect(x: max(frame.minX, notchMaxX), y: frame.minY, width: frame.maxX - max(frame.minX, notchMaxX), height: frame.height)
                result.append(Item(start: clipped.minX - notchMaxX, end: clipped.maxX - notchMaxX, frame: clipped))
            case .left:
                guard frame.minX < notchMinX - 1 else { continue }
                let maxX = min(frame.maxX, notchMinX)
                let clipped = CGRect(x: frame.minX, y: frame.minY, width: maxX - frame.minX, height: frame.height)
                result.append(Item(start: notchMinX - clipped.maxX, end: notchMinX - clipped.minX, frame: clipped))
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// 노치 가장자리 ~ 첫 구멍 앞까지 폭 (아이템이 없으면 무한대)
    static func room(_ items: [Item]) -> CGFloat {
        guard let first = items.first else { return .greatestFiniteMagnitude }
        return max(0, first.start - marginX)
    }

    /// 날개 끝이 아이콘을 반으로 자르지 않게 맞춘다.
    /// 자르는 아이콘이 있으면 그 아이콘을 품도록 늘리고(이어진 아이콘이면 계속), `cap` 을 넘으면 처음 자른 아이콘 앞에서 끝낸다.
    static func fitEdge(_ width: CGFloat, items: [Item], cap: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        func cutting(_ edge: CGFloat) -> Item? {
            items.first { $0.start + tolerance < edge && edge < $0.end - tolerance }
        }
        guard let firstCut = cutting(width) else { return width }
        var edge = width
        var steps = 0
        while let item = cutting(edge), steps < 64 {
            steps += 1
            let extended = item.end + edgePad
            guard extended <= cap else {
                // 늘릴 수 없으면 처음 자른 아이콘 앞으로 줄인다 (겹친 아이템이 있으면 그 앞까지)
                var shrunk = firstCut.start
                while let overlapped = cutting(shrunk), overlapped.start < shrunk { shrunk = overlapped.start }
                return shrunk < minWing ? 0 : shrunk
            }
            edge = extended
        }
        return edge
    }

    /// 날개 안에 든 아이템의 구멍 (패널 기준, 겹치는 구멍은 합침).
    /// 노치 쪽은 노치 가장자리, 바깥쪽은 날개 끝에서 3pt 안쪽까지, 위아래는 `minBorder` 를 남긴다.
    static func holes(
        _ items: [Item],
        side: Side,
        wing: CGFloat,
        bandHeight: CGFloat,
        notchMinX: CGFloat,
        notchMaxX: CGFloat
    ) -> [CGRect] {
        guard wing > 0 else { return [] }
        var rects: [CGRect] = []
        for item in items where item.start < wing - tolerance && item.end <= wing + tolerance {
            var hole = item.frame.insetBy(dx: -marginX, dy: -marginY)
            let top = max(hole.minY, minBorder)
            let bottom = min(hole.maxY, bandHeight - minBorder)
            guard bottom - top >= 8 else { continue }
            var minX = hole.minX
            var maxX = hole.maxX
            switch side {
            case .right:
                minX = max(minX, notchMaxX)
                maxX = min(maxX, notchMaxX + wing - marginX)
            case .left:
                maxX = min(maxX, notchMinX)
                minX = max(minX, notchMinX - wing + marginX)
            }
            guard maxX - minX >= 4 else { continue }
            hole = CGRect(x: minX, y: top, width: maxX - minX, height: bottom - top)
            rects.append(hole)
        }
        return merge(rects)
    }

    /// 가로로 겹치거나 맞닿은 구멍을 하나로 (even-odd 로 그려도 겹친 곳이 다시 칠해지지 않게)
    static func merge(_ rects: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for rect in rects.sorted(by: { $0.minX < $1.minX }) {
            if let last = result.last, rect.minX <= last.maxX + 0.5 {
                result[result.count - 1] = last.union(rect)
            } else {
                result.append(rect)
            }
        }
        return result
    }

    /// 구멍 위 마우스를 아래 메뉴바 아이템으로 통과시킬 영역 (구멍 폭 × 날개 높이 전체)
    static func passThrough(_ holes: [CGRect], bandHeight: CGFloat) -> [CGRect] {
        holes.map { CGRect(x: $0.minX, y: 0, width: $0.width, height: bandHeight) }
    }
}

/// 손쉬운 사용으로 읽은 메뉴바 아이템 사각형 정리
enum MenuBarItemFrames {
    /// - 메뉴바 띠 안(세로 가운데가 띠 안)에 있는 4pt 이상 항목만, 메뉴바 전체 같은 큰 요소는 제외
    /// - 같은 자리에 쌓인 항목(macOS 27 에서 « 버튼 뒤로 접힌 아이콘 등)은 하나로 합치고, 다음 항목과 겹치지 않게 자른다
    /// - 입력 · 결과 모두 패널 기준 (x 는 화면 왼쪽부터, y 는 화면 위부터)
    static func normalize(_ frames: [CGRect], screenWidth: CGFloat, bandHeight: CGFloat) -> [CGRect] {
        let maxWidth = max(160, screenWidth * 0.3)
        let valid = frames
            .filter { frame in
                frame.width >= 4 && frame.height >= 4 && frame.width <= maxWidth
                    && frame.midY >= -2 && frame.midY <= bandHeight + 2
                    && frame.maxX > 0 && frame.minX < screenWidth
            }
            .sorted { ($0.minX, $0.width) < ($1.minX, $1.width) }

        var groups: [[CGRect]] = []
        for frame in valid {
            if let anchor = groups.last?.first, abs(frame.minX - anchor.minX) <= 2 {
                groups[groups.count - 1].append(frame)
            } else {
                groups.append([frame])
            }
        }

        var result: [CGRect] = []
        for (index, group) in groups.enumerated() {
            var merged = group.dropFirst().reduce(group[0]) { $0.union($1) }
            if group.count > 1, index + 1 < groups.count {
                let nextMinX = groups[index + 1][0].minX
                if merged.maxX > nextMinX { merged.size.width = max(4, nextMinX - merged.minX) }
            }
            result.append(merged)
        }
        return result
    }
}
