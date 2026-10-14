import Foundation
import NotchCore

/// 앱을 새로 띄웠을 때 최근 Claude Code 대화 기록(`~/.claude/projects/<프로젝트>/<세션>.jsonl`)의 끝부분을 읽어 세션을 되살린다.
///
/// - 읽기만 하고 아무것도 쓰지 않는다. 내용은 메모리에서 상태(툴 실행 중 · 응답 중 · 끝남)를 고르는 데만 쓴다 (`TranscriptTail`).
/// - 서브에이전트 기록(`<세션>/subagents/`)은 보지 않는다 (프로젝트 폴더 바로 아래 jsonl 만).
/// - 돌고 있던 세션은 `activeWindow` 안에 기록이 바뀐 것만, 끝난 세션은 `finishedWindow` 안에 끝난 것만 되살린다
///   (닫힌 세션이 유령처럼 남지 않게. 긴 Bash 처럼 툴이 도는 동안은 기록이 안 바뀌어서 돌던 세션 창을 더 길게 둔다).
public struct SessionRestorer: Sendable {
    public var projectsDirectory: URL
    public var activeWindow: TimeInterval
    public var finishedWindow: TimeInterval
    /// 파일마다 끝에서 읽을 최대 바이트 (`TranscriptTail.readTail`)
    public var tailBytes: Int
    /// 최근에 바뀐 순으로 최대 몇 개 파일까지 볼지
    public var maxFiles: Int

    public init(
        projectsDirectory: URL = SessionRestorer.defaultProjectsDirectory,
        activeWindow: TimeInterval = 30 * 60,
        finishedWindow: TimeInterval = 15 * 60,
        tailBytes: Int = 256 * 1024,
        maxFiles: Int = 40
    ) {
        self.projectsDirectory = projectsDirectory
        self.activeWindow = activeWindow
        self.finishedWindow = finishedWindow
        self.tailBytes = tailBytes
        self.maxFiles = maxFiles
    }

    public static var defaultProjectsDirectory: URL {
        NotchServices.claudeDirectory.appendingPathComponent("projects", isDirectory: true)
    }

    /// 되살릴 세션 목록 (최근 것부터)
    public func scan(now: Date = Date()) -> [RestoredSession] {
        recentTranscripts(now: now).compactMap { file -> RestoredSession? in
            guard let lines = TranscriptTail.readTail(atPath: file.url.path, maxBytes: tailBytes),
                  let restored = TranscriptTail.restore(lines: lines)
            else { return nil }
            if case .finished = restored.state {
                return now.timeIntervalSince(restored.lastEventAt) <= finishedWindow ? restored : nil
            }
            return restored
        }
    }

    /// `activeWindow` 안에 바뀐 세션 기록 (최근 것부터 `maxFiles` 개)
    func recentTranscripts(now: Date) -> [(url: URL, modified: Date)] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let projects = try? fileManager.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [(url: URL, modified: Date)] = []
        for project in projects {
            guard let values = try? project.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let files = try? fileManager.contentsOfDirectory(
                      at: project, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
                  )
            else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: Set(keys)),
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
