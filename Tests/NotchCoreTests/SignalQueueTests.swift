import Foundation
import Testing
@testable import NotchCore
import NotchShared

/// UI 일시 반응 신호는 한 칸에 덮어쓰지 않고 최근 것을 순서대로 남긴다 (`SessionStore.recentSignals`).
/// UI 가 처리하기 전에 이벤트가 연달아 와도 앞 세션의 완료 알림을 잃지 않는다
@MainActor
@Suite struct SignalQueueTests {
    let clock = TestClock()

    @Test func signalsAreKeptInOrderUntilProcessed() {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", session: "a", #"{"prompt":"go"}"#))
        store.ingest(hook("UserPromptSubmit", session: "b", #"{"prompt":"go"}"#))
        let before = store.latestSignal?.seq ?? 0

        store.ingest(hook("Stop", session: "a"))
        store.ingest(hook("Stop", session: "b"))

        let fresh = store.recentSignals.filter { $0.seq > before }
        #expect(fresh.map(\.signal) == [.completed(sessionID: "a"), .completed(sessionID: "b")])
        #expect(store.latestSignal == fresh.last)
    }

    @Test func recentSignalsAreBounded() {
        let store = makeStore(clock)
        for index in 0..<(SessionStore.maxRecentSignals + 8) {
            store.ingest(hook("UserPromptSubmit", session: "s\(index)", #"{"prompt":"go"}"#))
            store.ingest(hook("Stop", session: "s\(index)"))
        }
        #expect(store.recentSignals.count == SessionStore.maxRecentSignals)
        // 오래된 것부터 빠지고 순서 번호는 이어진다
        let seqs = store.recentSignals.map(\.seq)
        #expect(seqs == Array((seqs.first ?? 0)...(seqs.last ?? 0)))
        #expect(store.latestSignal?.signal == .completed(sessionID: "s\(SessionStore.maxRecentSignals + 7)"))
    }
}
