import Foundation

/// 접힌 상태 폭 안정화.
///
/// 짧은 툴 이름 · `+N −M` · 백그라운드 배지 · 다른 세션 요약 폭은 훅 이벤트마다(PreToolUse → PostToolUse 가 0.5초 간격) 바뀌어서
/// 그대로 레이아웃에 넣으면 접힌 날개가 계속 늘었다 줄었다 한다.
/// - 같은 세션 · 같은 문구 종류(작업 중 / 승인 필요 등) 안에서는 필드마다 지금까지의 최댓값을 쓴다 (늘어날 땐 바로).
/// - 필드 값이 `holdDuration` 동안 한 번도 그만큼 필요하지 않았을 때만 지금 값으로 줄인다.
/// - 세션이나 문구 종류가 바뀌면 처음부터 다시 잰다.
struct CompactMetricsHold {
    static let holdDuration: TimeInterval = 4

    private static let fields: [WritableKeyPath<CompactMetrics, CGFloat>] = [
        \.project, \.tool, \.trailing, \.badge, \.summary,
    ]

    private var key: String?
    private var held: CompactMetrics?
    /// 필드별로 붙잡은 값이 마지막으로 필요했던 시각
    private var lastNeeded: [TimeInterval] = []

    init() {}

    /// 다음에 줄일 수 있는 시각 (붙잡은 값이 지금 값보다 클 때만)
    private(set) var releaseAt: TimeInterval?

    /// 지금 붙잡은 상태로 `measured` 를 안정화한 값. 상태는 바꾸지 않는다 (레이아웃 계산용 — 상태는 커밋에서 `stabilize` 로 옮긴다)
    func value(for measured: CompactMetrics, key: String, now: TimeInterval) -> CompactMetrics {
        var next = self
        return next.stabilize(measured, key: key, now: now)
    }

    /// `value(for:key:now:)` 와 같은 값을 계산하고 붙잡은 상태를 그 값으로 옮긴다
    @discardableResult
    mutating func stabilize(_ measured: CompactMetrics, key: String, now: TimeInterval) -> CompactMetrics {
        guard let held, self.key == key, held.isAttention == measured.isAttention else {
            self.key = key
            self.held = measured
            lastNeeded = Array(repeating: now, count: Self.fields.count)
            releaseAt = nil
            return measured
        }
        var next = held
        var release: TimeInterval?
        for (index, field) in Self.fields.enumerated() {
            let want = measured[keyPath: field]
            let have = held[keyPath: field]
            if want >= have - 0.5 {
                next[keyPath: field] = max(want, have)
                lastNeeded[index] = now
            } else if now - lastNeeded[index] >= Self.holdDuration {
                next[keyPath: field] = want
                lastNeeded[index] = now
            } else {
                let at = lastNeeded[index] + Self.holdDuration
                release = min(release ?? at, at)
            }
        }
        self.held = next
        releaseAt = release
        return next
    }
}
