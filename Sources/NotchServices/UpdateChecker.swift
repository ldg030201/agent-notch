import Foundation
import Observation

/// 정식판 / 테스트판 구분. 테스트판은 번들 ID 가 `-test` 로 끝난다 (`VARIANT=test scripts/build.sh`).
public enum BuildVariant {
    public static func isTest(bundleIdentifier: String?) -> Bool {
        bundleIdentifier?.hasSuffix("-test") ?? false
    }
}

/// `1.2.3` 또는 `1.2.3.4` 형태의 버전. 앞의 `v` 는 떼고, 빠진 자리는 0 으로 본다 (`1.2.3` == `1.2.3.0`).
/// 네 번째 자리는 이미 나간 버전을 급히 고칠 때만 쓴다.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") { trimmed.removeFirst() }
        let pieces = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !pieces.isEmpty, pieces.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        parts = pieces.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    private static func compare(_ lhs: AppVersion, _ rhs: AppVersion) -> Int {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool { compare(lhs, rhs) < 0 }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { compare(lhs, rhs) == 0 }
}

/// 새 버전 확인. 하루 한 번 GitHub 의 `docs/changelog.json` (raw) 을 받아 앱에 박힌 내역과 합친다.
///
/// - 앱의 유일한 네트워크 통신이다. 받은 내역은 메모리에만 두고 디스크에 쓰지 않는다.
/// - 날짜가 있는 항목만 "나간 버전" 으로 센다 (날짜는 `scripts/release.sh` 가 채운다).
/// - 테스트판은 확인하지 않는다.
@MainActor
@Observable
public final class UpdateChecker {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// 자동 확인 주기 (하루). 정확히 맞출 이유가 없어 여유(1시간)를 크게 준다.
    public nonisolated static let interval: TimeInterval = 24 * 60 * 60
    public nonisolated static let timerTolerance: TimeInterval = 60 * 60
    /// 확인 사이 최소 간격. 버튼을 잇달아 눌러도 요청이 그만큼 나가지 않게 한다.
    public nonisolated static let minCheckInterval: TimeInterval = 10
    public nonisolated static let requestTimeout: TimeInterval = 15

    /// 화면에 보여줄 내역 (원격 + 앱에 박힌 것, 버전 내림차순)
    public private(set) var entries: [ChangelogEntry]
    public private(set) var isChecking = false
    public private(set) var lastCheckedAt: Date?
    /// 마지막 확인 실패 이유 (성공하면 nil)
    public private(set) var errorText: String?

    public let currentVersion: String
    public let feedURL: URL
    /// 테스트판이면 true — 확인하지 않는다
    public let isTestBuild: Bool

    @ObservationIgnored private let embeddedEntries: [ChangelogEntry]
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var lastAttemptAt: Date?

    public init(
        currentVersion: String,
        embeddedEntries: [ChangelogEntry],
        feedURL: URL,
        isTestBuild: Bool,
        fetch: Fetch? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.currentVersion = currentVersion
        self.embeddedEntries = embeddedEntries
        self.feedURL = feedURL
        self.isTestBuild = isTestBuild
        self.fetch = fetch ?? Self.defaultFetch
        self.now = now
        entries = Self.merged(embedded: embeddedEntries, remote: [])
    }

    // MARK: - 버전 계산

    /// 나간 것 중 가장 높은 버전. 날짜가 없는 항목은 아직 안 나간 것이라 뺀다.
    public var latest: AppVersion? {
        Self.latest(in: entries)
    }

    public var latestVersion: String? { latest?.description }

    /// 지금 버전보다 새 버전이 나와 있는지. 지금 버전이 더 높으면(직접 빌드, 원격 캐시 지연) 알리지 않는다.
    public var hasUpdate: Bool {
        guard let latest, let current = AppVersion(currentVersion) else { return false }
        return current < latest
    }

    public nonisolated static func latest(in entries: [ChangelogEntry]) -> AppVersion? {
        entries
            .compactMap { entry in entry.date == nil ? nil : AppVersion(entry.version) }
            .max()
    }

    /// 앱에 박힌 내역과 원격 내역을 합친다. 같은 버전은 원격 쪽을 쓰고 버전 내림차순으로 세운다.
    ///
    /// 원격만 쓰면 안 된다 — raw.githubusercontent.com 은 몇 분간 캐시되어서, 방금 올린 버전을 쓰는 앱이
    /// 자기보다 뒤처진 목록을 받으면 자기 버전 항목이 화면에서 사라진다.
    public nonisolated static func merged(embedded: [ChangelogEntry], remote: [ChangelogEntry]) -> [ChangelogEntry] {
        var byVersion: [String: ChangelogEntry] = [:]
        for entry in embedded { byVersion[entry.version] = entry }
        for entry in remote { byVersion[entry.version] = entry }
        return byVersion.values.sorted { left, right in
            switch (AppVersion(left.version), AppVersion(right.version)) {
            case let (leftVersion?, rightVersion?) where leftVersion != rightVersion:
                return leftVersion > rightVersion
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                return left.version > right.version
            }
        }
    }

    // MARK: - 확인 주기

    public var isRunning: Bool { timer != nil }

    /// 바로 한 번 확인하고 하루마다 다시 확인한다. 이미 돌고 있으면 아무것도 안 한다.
    public func start() {
        guard !isTestBuild, timer == nil else { return }
        check()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.check() }
        }
        timer.tolerance = Self.timerTolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 지금 확인한다. 진행 중이거나 마지막 시도 후 10초가 안 지났으면 무시하고 nil.
    /// 테스트 코드는 돌려받은 Task 를 기다린다.
    @discardableResult
    public func check() -> Task<Void, Never>? {
        guard !isTestBuild else {
            errorText = "테스트판은 새 버전을 확인하지 않아요"
            return nil
        }
        guard !inFlight else { return nil }
        let startedAt = now()
        if let lastAttemptAt, startedAt.timeIntervalSince(lastAttemptAt) < Self.minCheckInterval {
            return nil
        }
        lastAttemptAt = startedAt
        inFlight = true
        isChecking = true

        let request = makeRequest()
        let fetch = fetch
        return Task { [weak self] in
            let outcome = await Self.load(request, fetch: fetch)
            guard let self else { return }
            self.inFlight = false
            self.isChecking = false
            self.lastCheckedAt = self.now()
            switch outcome {
            case .success(let remote):
                self.errorText = nil
                self.entries = Self.merged(embedded: self.embeddedEntries, remote: remote)
            case .failure(let message):
                self.errorText = message
            }
        }
    }

    // MARK: - 받기

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = Self.requestTimeout
        // 방금 올린 내역이 로컬 캐시에 가려지지 않게 한다
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("agent-notch/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    enum Outcome: Equatable {
        case success([ChangelogEntry])
        case failure(String)
    }

    nonisolated static func load(_ request: URLRequest, fetch: Fetch) async -> Outcome {
        do {
            let (data, response) = try await fetch(request)
            guard let http = response as? HTTPURLResponse else { return .failure("응답이 없어요") }
            guard http.statusCode == 200 else { return .failure("서버 응답 HTTP \(http.statusCode)") }
            let feed = try JSONDecoder().decode(ChangelogFeed.self, from: data)
            guard !feed.entries.isEmpty else { return .failure("변경 내역이 비어 있어요") }
            return .success(feed.entries)
        } catch is DecodingError {
            return .failure("변경 내역 형식을 읽지 못했어요")
        } catch let error as URLError where error.code == .notConnectedToInternet {
            return .failure("인터넷에 연결되어 있지 않아요")
        } catch let error as URLError where error.code == .timedOut {
            return .failure("응답이 늦어 중단했어요")
        } catch {
            return .failure("네트워크 오류: \(error.localizedDescription)")
        }
    }

    /// 디스크 캐시·쿠키를 남기지 않는 세션
    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    private nonisolated static let defaultFetch: Fetch = { request in
        try await session.data(for: request)
    }
}
