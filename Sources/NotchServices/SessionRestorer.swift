import Foundation
import NotchCore

/// 앱을 새로 띄웠을 때 최근 대화 기록의 끝부분을 읽어 세션을 되살린다.
/// - Claude Code: `~/.claude/projects/<프로젝트>/<세션>.jsonl` (`TranscriptTail`)
/// - Codex: `~/.codex/sessions/<연>/<월>/<일>/rollout-….jsonl` (`CodexRolloutTail`, 첫 줄의 세션 정보 + 끝부분)
///
/// - 읽기만 하고 아무것도 쓰지 않는다. 내용은 메모리에서 상태(툴 실행 중 · 응답 중 · 끝남)를 고르는 데만 쓴다.
/// - 서브에이전트 기록은 보지 않는다 (Claude Code 는 `<세션>/subagents/` 를 건너뛰고, Codex 는 첫 줄이 서브에이전트 스레드면 버린다).
/// - 돌고 있던 세션은 `activeWindow` 안에 기록이 바뀐 것만, 끝난 세션은 `finishedWindow` 안에 끝난 것만 되살린다
///   (닫힌 세션이 유령처럼 남지 않게. 긴 Bash 처럼 툴이 도는 동안은 기록이 안 바뀌어서 돌던 세션 창을 더 길게 둔다).
public struct SessionRestorer: Sendable {
    public var projectsDirectory: URL
    /// Codex 기록 폴더 (nil 이면 Codex 는 보지 않는다)
    public var codexSessionsDirectory: URL?
    public var activeWindow: TimeInterval
    public var finishedWindow: TimeInterval
    /// 파일마다 끝에서 읽을 최대 바이트 (`TranscriptTail.readTail`)
    public var tailBytes: Int
    /// 최근에 바뀐 순으로 최대 몇 개 파일까지 볼지
    public var maxFiles: Int

    public init(
        projectsDirectory: URL = SessionRestorer.defaultProjectsDirectory,
        codexSessionsDirectory: URL? = SessionRestorer.defaultCodexSessionsDirectory,
        activeWindow: TimeInterval = 30 * 60,
        finishedWindow: TimeInterval = 15 * 60,
        tailBytes: Int = 256 * 1024,
        maxFiles: Int = 40
    ) {
        self.projectsDirectory = projectsDirectory
        self.codexSessionsDirectory = codexSessionsDirectory
        self.activeWindow = activeWindow
        self.finishedWindow = finishedWindow
        self.tailBytes = tailBytes
        self.maxFiles = maxFiles
    }

    public static var defaultProjectsDirectory: URL {
        NotchServices.claudeDirectory.appendingPathComponent("projects", isDirectory: true)
    }

    public static var defaultCodexSessionsDirectory: URL {
        NotchServices.codexDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    /// 되살릴 세션 목록 (최근 것부터)
    public func scan(now: Date = Date()) -> [RestoredSession] {
        let claude = recentTranscripts(now: now).compactMap { file -> RestoredSession? in
            guard let lines = TranscriptTail.readTail(atPath: file.url.path, maxBytes: tailBytes) else { return nil }
            return TranscriptTail.restore(lines: lines)
        }
        let codex = recentCodexRollouts(now: now).compactMap { file -> RestoredSession? in
            guard let head = CodexRolloutTail.readFirstLine(atPath: file.url.path),
                  let meta = CodexRolloutTail.meta(fromFirstLine: head),
                  !meta.isSubagent,
                  let lines = TranscriptTail.readTail(atPath: file.url.path, maxBytes: tailBytes)
            else { return nil }
            return CodexRolloutTail.restore(meta: meta, lines: lines)
        }
        return (claude + codex)
            .filter { restored in
                guard case .finished = restored.state else { return true }
                return now.timeIntervalSince(restored.lastEventAt) <= finishedWindow
            }
            .sorted { $0.lastEventAt > $1.lastEventAt }
    }

    /// `activeWindow` 안에 바뀐 세션 기록 (최근 것부터 `maxFiles` 개)
    func recentTranscripts(now: Date) -> [(url: URL, modified: Date)] {
        recentJSONL(in: Self.children(projectsDirectory).filter(Self.isDirectory), now: now)
    }

    /// 가장 최근에 바뀐 Codex 기록의 수정 시각 (`activeWindow` 안, 서브에이전트 기록 포함). Codex 가 지금 일하는지 가늠한다
    public func latestCodexActivity(now: Date = Date(), recentDays: Int? = nil) -> Date? {
        recentCodexRollouts(now: now, recentDays: recentDays).first?.modified
    }

    /// `activeWindow` 안에 바뀐 Codex 기록 (`<연>/<월>/<일>/*.jsonl`, 최근 것부터 `maxFiles` 개).
    /// 기록은 시작한 날의 폴더에 남아 계속 쓰이므로 날짜 폴더를 모두 보고 수정 시각으로 고른다. 심볼릭 링크는 따라가지 않는다.
    /// `recentDays` 를 주면 오늘부터 그 날수의 날짜 폴더만 본다: 자주 부르는 곳(`CodexHookMonitor`, 10초마다)이 쌓인 기록 폴더 전체를
    /// 매번 훑지 않게 (며칠 넘게 이어지는 기록은 놓쳐도 되는 곳에서만 쓴다)
    func recentCodexRollouts(now: Date, recentDays: Int? = nil) -> [(url: URL, modified: Date)] {
        guard let root = codexSessionsDirectory else { return [] }
        let dayFolders: [URL]
        if let recentDays {
            let calendar = Calendar.current
            dayFolders = (0..<max(1, recentDays)).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
                let folder = root.appendingPathComponent(String(format: "%04d/%02d/%02d", year, month, day), isDirectory: true)
                return Self.isDirectory(folder) ? folder : nil
            }
        } else {
            dayFolders = Self.children(root).filter(Self.isDirectory)
                .flatMap { Self.children($0).filter(Self.isDirectory) }
                .flatMap { Self.children($0).filter(Self.isDirectory) }
        }
        return recentJSONL(in: dayFolders, now: now)
    }

    // MARK: - 기록 파일 찾기 (Claude Code · Codex 공용)

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
    ]

    private static func children(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles]
        )) ?? []
    }

    /// 심볼릭 링크가 아닌 폴더
    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// 폴더들 바로 아래의 `.jsonl` 일반 파일 중 `activeWindow` 안에 바뀐 것 (최근 것부터 `maxFiles` 개, 링크는 따라가지 않는다)
    private func recentJSONL(in folders: [URL], now: Date) -> [(url: URL, modified: Date)] {
        var found: [(url: URL, modified: Date)] = []
        for folder in folders {
            for file in Self.children(folder) where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: Set(Self.resourceKeys)),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let modified = values.contentModificationDate,
                      now.timeIntervalSince(modified) <= activeWindow
                else { continue }
                found.append((file, modified))
            }
        }
        return Array(found.sorted { $0.modified > $1.modified }.prefix(maxFiles))
    }
}
