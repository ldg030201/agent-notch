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
}
