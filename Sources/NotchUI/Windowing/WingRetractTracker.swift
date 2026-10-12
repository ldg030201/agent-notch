import AppKit

/// 넓은 노치 날개 비켜주기 (손쉬운 사용 권한이 없거나 메뉴바 아이콘 위치를 모를 때).
///
/// - 접힌 아일랜드를 왼쪽 날개 · 노치(카메라) · 오른쪽 날개로 나눈다.
/// - 마우스가 날개 자리에 약 120ms 머물면 그쪽 날개가 노치 안으로 들어가고(폭 0), 그 자리는 클릭이 아래 메뉴바 아이템으로 간다.
/// - 마우스가 그 날개의 메뉴바 띠를 떠나 약 0.6초 지나면 다시 나온다.
/// - 노치 가운데는 늘 클릭(펼치기)을 받는다. 카드(피크 · 권한 · 펼침)는 대상이 아니다.
@MainActor
final class WingRetractTracker {
    /// 비켜줄 날개 자리 (Cocoa 전역, 원래 날개 폭 × 메뉴바 높이)
    struct Bands: Equatable {
        var left: CGRect?
        var right: CGRect?

        func rect(_ side: WingSides) -> CGRect? {
            side == .left ? left : right
        }
    }

    private struct Key: Hashable {
        var screen: ScreenID
        var side: Int
    }

    static let enterDelay: Duration = .milliseconds(120)
    static let restoreDelay: Duration = .milliseconds(600)

    /// 화면의 비켜준 날개가 바뀌면 호출
    var onChange: ((ScreenID, WingSides) -> Void)?

    private var bands: [ScreenID: Bands] = [:]
    private var retracted: [ScreenID: WingSides] = [:]
    private var enterTasks: [Key: Task<Void, Never>] = [:]
    private var restoreTasks: [Key: Task<Void, Never>] = [:]

    /// 비켜줄 수 있는 화면과 자리. 빠진 화면(카드가 펼쳐짐, 아이콘 구멍 사용 등)은 날개를 원래대로 돌린다.
    func setBands(_ next: [ScreenID: Bands]) {
        let removed = Set(bands.keys).union(retracted.keys).subtracting(next.keys)
        bands = next
        for id in removed { clear(id) }
        // 자리가 없어진 쪽은 원래대로
        for (id, sides) in retracted {
            guard let band = next[id] else { continue }
            var kept = sides
            if band.left == nil { kept.remove(.left) }
            if band.right == nil { kept.remove(.right) }
            if kept != sides { set(kept, on: id) }
        }
    }

    /// 마우스가 비켜줄 날개 자리 안인지 (호버 효과 제외용)
    func isInBand(_ location: CGPoint, screen id: ScreenID) -> Bool {
        guard let band = bands[id] else { return false }
        return [band.left, band.right].contains { $0.map { Self.contains($0, location) } ?? false }
    }

    func update(location: CGPoint, activeScreen: ScreenID?) {
        for (id, band) in bands {
            for side in [WingSides.left, .right] {
                guard let rect = band.rect(side) else { continue }
                let inside = id == activeScreen && Self.contains(rect, location)
                let key = Key(screen: id, side: side.rawValue)
                if retracted[id, default: []].contains(side) {
                    if inside {
                        restoreTasks.removeValue(forKey: key)?.cancel()
                    } else if restoreTasks[key] == nil {
                        restoreTasks[key] = schedule(Self.restoreDelay) { [weak self] in
                            self?.restoreTasks[key] = nil
                            self?.finishRestore(side, on: id)
                        }
                    }
                } else {
                    if inside {
                        if enterTasks[key] == nil {
                            enterTasks[key] = schedule(Self.enterDelay) { [weak self] in
                                self?.enterTasks[key] = nil
                                self?.finishEnter(side, on: id)
                            }
                        }
                    } else {
                        enterTasks.removeValue(forKey: key)?.cancel()
                    }
                }
            }
        }
    }

    func reset() {
        for task in enterTasks.values { task.cancel() }
        for task in restoreTasks.values { task.cancel() }
        enterTasks.removeAll()
        restoreTasks.removeAll()
        for id in Array(retracted.keys) { set([], on: id) }
        bands.removeAll()
    }

    // MARK: - 내부

    /// 머문 시간이 지났을 때 아직 날개 위면 비켜준다
    private func finishEnter(_ side: WingSides, on id: ScreenID) {
        guard let rect = bands[id]?.rect(side), Self.contains(rect, NSEvent.mouseLocation) else { return }
        set(retracted[id, default: []].union(side), on: id)
    }

    /// 떠난 지 시간이 지났을 때 아직 밖이면 되돌린다
    private func finishRestore(_ side: WingSides, on id: ScreenID) {
        if let rect = bands[id]?.rect(side), Self.contains(rect, NSEvent.mouseLocation) { return }
        set(retracted[id, default: []].subtracting(side), on: id)
    }

    private func clear(_ id: ScreenID) {
        for side in [WingSides.left, .right] {
            let key = Key(screen: id, side: side.rawValue)
            enterTasks.removeValue(forKey: key)?.cancel()
            restoreTasks.removeValue(forKey: key)?.cancel()
        }
        if retracted[id] != nil { set([], on: id) }
    }

    private func set(_ sides: WingSides, on id: ScreenID) {
        let current = retracted[id] ?? []
        guard current != sides else { return }
        retracted[id] = sides.isEmpty ? nil : sides
        onChange?(id, sides)
    }

    private func schedule(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    /// 화면 맨 위 픽셀(y == maxY)도 포함
    private static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }
}
