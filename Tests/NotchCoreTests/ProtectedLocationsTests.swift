import Foundation
import Testing
@testable import NotchCore

/// macOS 보호 폴더 판정 · 보호 폴더 프로젝트의 브랜치는 대화 기록에서 (가짜 홈 · 임시 폴더만 사용)
@MainActor
@Suite struct ProtectedLocationsTests {
    @Test func detectsProtectedFolders() {
        let home = "/Users/dev"
        #expect(ProtectedLocations.contains("/Users/dev/Documents/doc-company", home: home))
        #expect(ProtectedLocations.contains("/Users/dev/Documents", home: home))
        #expect(ProtectedLocations.contains("/Users/dev/documents/Notes", home: home))
        #expect(ProtectedLocations.contains("/Users/dev/Desktop/x/../y", home: home))
        #expect(ProtectedLocations.contains("/Users/dev/Downloads/zip", home: home))
        #expect(ProtectedLocations.contains("/Users/dev/Library/Mobile Documents/com~apple~CloudDocs/p", home: home))
        #expect(ProtectedLocations.contains("/Users/dev/Library/CloudStorage/Dropbox/p", home: home))
        #expect(ProtectedLocations.contains("/Volumes/USB/project", home: home))

        #expect(!ProtectedLocations.contains("/Users/dev/code/agent-notch", home: home))
        #expect(!ProtectedLocations.contains("/Users/dev/Documentsx/p", home: home))
        #expect(!ProtectedLocations.contains("/Users/dev/.claude/projects/p/s.jsonl", home: home))
        #expect(!ProtectedLocations.contains("", home: home))
        // 데이터 볼륨 실제 경로도 같은 곳
        #expect(ProtectedLocations.contains("/System/Volumes/Data/Users/dev/Documents/p", home: home))
        #expect(!ProtectedLocations.contains("/System/Volumes/Data/Users/dev/code/p", home: home))
        // 상대 gitdir 을 붙인 경로: 글자로만 정리해서 판단
        #expect(ProtectedLocations.contains("/Users/dev/code/wt/../../Documents/repo/.git/worktrees/wt", home: home))
        #expect(!ProtectedLocations.contains("/Users/dev/Documents/../code/repo", home: home))
    }

    /// 파일 시스템을 보지 않고 글자로만 정리한다
    @Test func lexicalNormalization() {
        #expect(ProtectedLocations.lexicallyNormalized("/a//b/./c/../d/") == "/a/b/d")
        #expect(ProtectedLocations.lexicallyNormalized("/../a") == "/a")
        #expect(ProtectedLocations.lexicallyNormalized("/") == "/")
        #expect(ProtectedLocations.lexicallyNormalized("a/../../b") == "../b")
        #expect(ProtectedLocations.lexicallyNormalized("~/x").hasSuffix("/x"))
        #expect(!ProtectedLocations.lexicallyNormalized("~/x").hasPrefix("~"))
    }

    @Test func protectedProjectBranchComesFromTranscript() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("agentnotch-branch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.path
        let fileManager = FileManager.default

        // 보호 폴더 안 프로젝트: .git 은 main 이지만 직접 읽지 않고 대화 기록의 브랜치를 쓴다
        let protected = root.appendingPathComponent("Documents/doc-company")
        try fileManager.createDirectory(at: protected.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: protected.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        // 보호 폴더 밖 프로젝트: 예전처럼 .git 을 읽는다
        let normal = root.appendingPathComponent("code/app")
        try fileManager.createDirectory(at: normal.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/develop\n".write(to: normal.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)

        let transcriptDir = root.appendingPathComponent(".claude/projects/p")
        try fileManager.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        let transcript = transcriptDir.appendingPathComponent("s.jsonl")
        try """
        {"type":"user","gitBranch":"old-branch","sessionId":"s"}
        {"type":"assistant","gitBranch":"feature-x","sessionId":"s"}
        {"type":"attachment","gitBranch":"","sessionId":"s"}

        """.write(to: transcript, atomically: true, encoding: .utf8)

        #expect(TranscriptTail.lastGitBranch(atPath: transcript.path) == "feature-x")
        #expect(SessionStore.lookupBranch(cwd: protected.path, transcriptPath: transcript.path, home: home) == "feature-x")
        #expect(SessionStore.lookupBranch(cwd: protected.path, transcriptPath: nil, home: home) == nil)
        #expect(SessionStore.lookupBranch(cwd: normal.path, transcriptPath: nil, home: home) == "develop")
        // 대화 기록이 보호 폴더에 있으면 그것도 읽지 않는다
        let protectedTranscript = root.appendingPathComponent("Documents/t.jsonl")
        try "{\"gitBranch\":\"x\"}\n".write(to: protectedTranscript, atomically: true, encoding: .utf8)
        #expect(SessionStore.lookupBranch(cwd: protected.path, transcriptPath: protectedTranscript.path, home: home) == nil)
    }

    /// 작업 폴더는 보호 폴더 밖이지만 워크트리 `gitdir:` 이 보호 폴더 안 저장소를 가리키면 `GitInfo` 가 읽지 않는다 →
    /// 대화 기록의 브랜치를 쓰고, 그것도 없으면 "모름" (알던 값을 지우지 않게). 그냥 git 저장소가 아니면 모름이 아니다
    @Test func worktreeIntoProtectedFolderFallsBackToTranscript() throws {
        let fileManager = FileManager.default
        let made = fileManager.temporaryDirectory.appendingPathComponent("agentnotch-wt-\(UUID().uuidString)")
        try fileManager.createDirectory(at: made, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: made) }
        // 링크를 푼 실제 경로 기준 (GitInfo 는 실제 경로로 보호 폴더를 판단한다)
        let root = try #require(realpath(made.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        let home = "\(root)/home"
        func write(_ text: String, to path: String) throws {
            try fileManager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        try write("ref: refs/heads/wt-branch\n", to: "\(home)/Documents/repo/.git/worktrees/wt/HEAD")
        try write("gitdir: \(home)/Documents/repo/.git/worktrees/wt\n", to: "\(home)/code/wt/.git")
        try fileManager.createDirectory(atPath: "\(home)/code/plain", withIntermediateDirectories: true)
        let transcript = "\(home)/.claude/projects/p/s.jsonl"
        try write(#"{"type":"assistant","gitBranch":"wt-branch","sessionId":"s"}"# + "\n", to: transcript)

        let worktree = "\(home)/code/wt"
        #expect(SessionStore.lookupBranch(cwd: worktree, transcriptPath: transcript, home: home) == "wt-branch")
        let unknown = SessionStore.branchLookup(cwd: worktree, transcriptPath: nil, home: home)
        #expect(unknown.branch == nil)
        #expect(unknown.isUnknown)
        // git 저장소가 아닌 폴더: 대화 기록을 보지 않고 "브랜치 없음"
        let plain = SessionStore.branchLookup(cwd: "\(home)/code/plain", transcriptPath: transcript, home: home)
        #expect(plain.branch == nil)
        #expect(!plain.isUnknown)
    }
}
