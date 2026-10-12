import Foundation
import Testing
@testable import NotchServices

private let feedURL = URL(string: "https://example.com/changelog.json")!

private func entry(_ version: String, _ date: String?, _ text: String = "내용") -> ChangelogEntry {
    ChangelogEntry(version: version, date: date, groups: [
        ChangelogGroup(title: "묶음", notes: [.fix(text)]),
    ])
}

/// 네트워크 대신 쓰는 가짜 응답. 몇 번 불렸는지 센다.
private final class FetchStub: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _lastRequest: URLRequest?
    var status = 200
    var body = Data()
    var error: Error?

    var count: Int { lock.withLock { _count } }
    var lastRequest: URLRequest? { lock.withLock { _lastRequest } }

    func feed(_ entries: [ChangelogEntry]) throws {
        body = try ChangelogFeed(entries: entries).jsonData()
    }

    var fetch: UpdateChecker.Fetch {
        { [self] request in
            lock.withLock {
                _count += 1
                _lastRequest = request
            }
            if let error { throw error }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }
}

/// 시각을 직접 움직이는 시계 (테스트는 메인 액터에서만 만진다)
private final class TestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_760_000_000)
    func advance(_ seconds: TimeInterval) { date += seconds }
}

@Suite("AppVersion")
struct AppVersionTests {
    @Test func parsesVersions() {
        #expect(AppVersion("1.2.3")?.parts == [1, 2, 3])
        #expect(AppVersion("v0.1.0")?.parts == [0, 1, 0])
        #expect(AppVersion("1.2.3.4")?.parts == [1, 2, 3, 4])
        #expect(AppVersion("2")?.parts == [2])
        #expect(AppVersion("1.2.3")?.description == "1.2.3")
        for invalid in ["", "v", "1..2", "1.x", "1.2.3-beta", "1.-2", ".1"] {
            #expect(AppVersion(invalid) == nil, "\(invalid)")
        }
    }

    @Test func comparesIncludingHotfixDigit() throws {
        func v(_ text: String) throws -> AppVersion { try #require(AppVersion(text)) }
        #expect(try v("0.1.0") < v("0.1.0.1"))
        #expect(try v("0.1.0.1") < v("0.1.1"))
        #expect(try v("0.9.0") < v("0.10.0"))
        #expect(try v("1.0") < v("1.0.1"))
        #expect(try v("1.2.3") == v("1.2.3.0"))
        #expect(try v("v1.2.3") == v("1.2.3"))
        #expect(try !(v("1.2.3") < v("1.2.3.0")))
        #expect(try v("2.0.0") > v("1.99.99.99"))
    }
}

@MainActor
@Suite("UpdateChecker")
struct UpdateCheckerTests {
    private func makeChecker(
        current: String = "0.1.0",
        embedded: [ChangelogEntry] = [entry("0.1.0", "2026-10-01")],
        stub: FetchStub = FetchStub(),
        clock: TestClock = TestClock(),
        isTestBuild: Bool = false
    ) -> UpdateChecker {
        UpdateChecker(
            currentVersion: current,
            embeddedEntries: embedded,
            feedURL: feedURL,
            isTestBuild: isTestBuild,
            fetch: stub.fetch,
            now: { clock.date }
        )
    }

    @Test func latestSkipsUndatedEntries() {
        let entries = [entry("0.3.0", nil), entry("0.2.0", "2026-10-10"), entry("0.1.0", "2026-10-01")]
        #expect(UpdateChecker.latest(in: entries)?.description == "0.2.0")
        #expect(UpdateChecker.latest(in: [entry("0.1.0", nil)]) == nil)
    }

    @Test func mergeKeepsEmbeddedAndPrefersRemote() {
        let embedded = [entry("0.2.0", nil, "앱에 박힌 내용"), entry("0.1.0", "2026-10-01")]
        let remote = [entry("0.1.0.1", "2026-10-02"), entry("0.1.0", "2026-10-01", "원격 내용")]
        let merged = UpdateChecker.merged(embedded: embedded, remote: remote)
        #expect(merged.map(\.version) == ["0.2.0", "0.1.0.1", "0.1.0"])
        #expect(merged.last?.notes == ["[묶음] 원격 내용"])
        // 원격이 아직 모르는 (방금 올린) 버전도 화면에 남는다
        #expect(merged.first?.notes == ["[묶음] 앱에 박힌 내용"])
    }

    @Test func hasUpdateOnlyWhenRemoteIsNewer() async throws {
        let stub = FetchStub()
        try stub.feed([entry("0.2.0", "2026-10-10"), entry("0.1.0", "2026-10-01")])

        let older = makeChecker(current: "0.1.0", stub: stub)
        await older.check()?.value
        #expect(older.hasUpdate)
        #expect(older.latestVersion == "0.2.0")

        // 직접 빌드한 더 높은 버전이면 알리지 않는다
        let newer = makeChecker(current: "0.3.0", stub: stub)
        await newer.check()?.value
        #expect(!newer.hasUpdate)

        let same = makeChecker(current: "0.2.0", stub: stub)
        await same.check()?.value
        #expect(!same.hasUpdate)

        // 날짜 없는(준비 중) 항목은 새 버전으로 세지 않는다
        try stub.feed([entry("0.5.0", nil), entry("0.1.0", "2026-10-01")])
        let unreleased = makeChecker(current: "0.1.0", stub: stub)
        await unreleased.check()?.value
        #expect(!unreleased.hasUpdate)
        #expect(unreleased.entries.first?.version == "0.5.0")
    }

    @Test func successfulCheckMergesFeedAndSetsRequestHeaders() async throws {
        let stub = FetchStub()
        try stub.feed([entry("0.1.1", "2026-10-05")])
        let checker = makeChecker(stub: stub)
        #expect(checker.lastCheckedAt == nil)

        let task = try #require(checker.check())
        #expect(checker.isChecking)
        await task.value

        #expect(!checker.isChecking)
        #expect(checker.errorText == nil)
        #expect(checker.lastCheckedAt != nil)
        #expect(checker.entries.map(\.version) == ["0.1.1", "0.1.0"])
        let request = try #require(stub.lastRequest)
        #expect(request.url == feedURL)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "agent-notch/0.1.0")
        #expect(request.timeoutInterval == 15)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func failuresKeepEmbeddedEntriesAndReportKoreanErrors() async throws {
        let stub = FetchStub()
        let clock = TestClock()
        let checker = makeChecker(stub: stub, clock: clock)

        stub.status = 404
        await checker.check()?.value
        #expect(checker.errorText == "서버 응답 HTTP 404")
        #expect(checker.entries.map(\.version) == ["0.1.0"])

        clock.advance(11)
        stub.status = 200
        stub.body = Data("{ not json".utf8)
        await checker.check()?.value
        #expect(checker.errorText == "변경 내역 형식을 읽지 못했어요")

        clock.advance(11)
        try stub.feed([])
        await checker.check()?.value
        #expect(checker.errorText == "변경 내역이 비어 있어요")

        clock.advance(11)
        stub.error = URLError(.notConnectedToInternet)
        await checker.check()?.value
        #expect(checker.errorText == "인터넷에 연결되어 있지 않아요")

        // 다시 성공하면 오류가 지워진다
        clock.advance(11)
        stub.error = nil
        try stub.feed([entry("0.1.0", "2026-10-01")])
        await checker.check()?.value
        #expect(checker.errorText == nil)
    }

    @Test func checksAreThrottledAndNotDoubled() async throws {
        let stub = FetchStub()
        try stub.feed([entry("0.1.0", "2026-10-01")])
        let clock = TestClock()
        let checker = makeChecker(stub: stub, clock: clock)

        let first = try #require(checker.check())
        // 진행 중에는 새로 나가지 않는다
        #expect(checker.check() == nil)
        await first.value
        #expect(stub.count == 1)

        // 10초 안에는 다시 나가지 않는다
        clock.advance(5)
        #expect(checker.check() == nil)
        #expect(stub.count == 1)

        clock.advance(6)
        await checker.check()?.value
        #expect(stub.count == 2)
    }

    @Test func testBuildNeverChecks() async {
        let stub = FetchStub()
        let checker = makeChecker(stub: stub, isTestBuild: true)
        checker.start()
        #expect(!checker.isRunning)
        #expect(checker.check() == nil)
        #expect(checker.errorText != nil)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(stub.count == 0)
    }

    @Test func startChecksImmediatelyOnceAndStops() async throws {
        let stub = FetchStub()
        try stub.feed([entry("0.1.0", "2026-10-01")])
        let checker = makeChecker(stub: stub)
        checker.start()
        checker.start()
        #expect(checker.isRunning)
        let finished = await waitUntil { !checker.isChecking && stub.count == 1 }
        #expect(finished)
        #expect(stub.count == 1)
        checker.stop()
        #expect(!checker.isRunning)
    }
}

@Suite("ChangelogFeed")
struct ChangelogFeedTests {
    @Test func derivesFlatNotesAndRoundTrips() throws {
        let original = ChangelogEntry(version: "0.2.0", date: "2026-10-12", groups: [
            ChangelogGroup(title: "업데이트", tab: "version", isNew: true, notes: [.new("새 버전 확인 (하루 1회)")]),
            ChangelogGroup(title: "표시", notes: [.fix("알약이 잘리던 문제 수정"), .improve("간격 개선")]),
        ])
        #expect(original.notes == ["[업데이트] 새 버전 확인 (하루 1회)", "[표시] 알약이 잘리던 문제 수정", "[표시] 간격 개선"])

        let data = try ChangelogFeed(entries: [original]).jsonData()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("}\n"))
        // 슬래시 · 한글을 이스케이프하지 않는다
        #expect(text.contains("(하루 1회)"))
        let decoded = try JSONDecoder().decode(ChangelogFeed.self, from: data)
        #expect(decoded.entries == [original])
        // 같은 입력이면 항상 같은 바이트 (CI 의 diff 검사)
        #expect(try ChangelogFeed(entries: [original]).jsonData() == data)
    }

    @Test func decodesTolerantly() throws {
        let json = """
        {
          "entries": [
            {
              "version": "0.3.0",
              "groups": [
                { "title": "새 기능", "notes": [ { "kind": "someday", "text": "모르는 갈래" } ] }
              ]
            },
            { "version": "0.2.0", "date": "2026-10-10", "notes": ["평평한 옛 형식"] }
          ]
        }
        """
        let feed = try JSONDecoder().decode(ChangelogFeed.self, from: Data(json.utf8))
        #expect(feed.entries.count == 2)
        let first = feed.entries[0]
        #expect(first.date == nil)
        #expect(first.groups?.first?.isNew == false)
        #expect(first.groups?.first?.tab == nil)
        #expect(first.groups?.first?.notes.first?.kind == .change)
        #expect(first.notes == ["[새 기능] 모르는 갈래"])
        #expect(feed.entries[1].groups == nil)
        #expect(feed.entries[1].notes == ["평평한 옛 형식"])
    }
}
