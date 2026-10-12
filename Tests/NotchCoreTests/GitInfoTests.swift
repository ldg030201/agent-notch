import Foundation
import Testing
@testable import NotchCore

/// /tmp 아래 임시 디렉터리에 가짜 git 구조를 만들어 검사한다 (git 프로세스 사용 안 함)
@Suite struct GitInfoTests {
    private func makeTempRoot() throws -> String {
        let root = "/tmp/agentnotch-gitinfo-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func normalRepository() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("ref: refs/heads/feature/login\n", to: "\(root)/repo/.git/HEAD")
        try FileManager.default.createDirectory(atPath: "\(root)/repo/src/deep", withIntermediateDirectories: true)

        #expect(GitInfo.branch(forDirectory: "\(root)/repo") == "feature/login")
        #expect(GitInfo.branch(forDirectory: "\(root)/repo/src/deep") == "feature/login")
        #expect(GitInfo.branch(forDirectory: "\(root)/repo/src/deep/") == "feature/login")
    }

    @Test func worktreeGitdirFile() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("ref: refs/heads/main\n", to: "\(root)/repo/.git/HEAD")
        try write("ref: refs/heads/wt-branch\n", to: "\(root)/repo/.git/worktrees/wt/HEAD")
        // 상대 경로 gitdir
        try write("gitdir: ../repo/.git/worktrees/wt\n", to: "\(root)/wt/.git")
        // 절대 경로 gitdir
        try write("gitdir: \(root)/repo/.git/worktrees/wt\n", to: "\(root)/wt2/.git")

        #expect(GitInfo.branch(forDirectory: "\(root)/wt") == "wt-branch")
        #expect(GitInfo.branch(forDirectory: "\(root)/wt2") == "wt-branch")
        #expect(GitInfo.branch(forDirectory: "\(root)/repo") == "main")
    }

    @Test func detachedHead() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("0123456789abcdef0123456789abcdef01234567\n", to: "\(root)/repo/.git/HEAD")
        #expect(GitInfo.branch(forDirectory: "\(root)/repo") == "0123456")
    }

    @Test func notARepository() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: "\(root)/plain", withIntermediateDirectories: true)
        #expect(GitInfo.branch(forDirectory: "\(root)/plain") == nil)
        #expect(GitInfo.branch(forDirectory: "") == nil)
        // 깨진 .git 파일
        try write("garbage\n", to: "\(root)/broken/.git")
        #expect(GitInfo.branch(forDirectory: "\(root)/broken") == nil)
    }

    /// FIFO 로 된 HEAD · .git 은 열다가 멈추지 않고 바로 nil (#5)
    @Test(.timeLimit(.minutes(1))) func fifoDoesNotBlock() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: "\(root)/repo/.git", withIntermediateDirectories: true)
        #expect(mkfifo("\(root)/repo/.git/HEAD", 0o600) == 0)
        try FileManager.default.createDirectory(atPath: "\(root)/proj/sub", withIntermediateDirectories: true)
        #expect(mkfifo("\(root)/proj/.git", 0o600) == 0)

        let start = Date()
        #expect(GitInfo.branch(forDirectory: "\(root)/repo") == nil)
        #expect(GitInfo.branch(forDirectory: "\(root)/proj/sub") == nil)
        #expect(Date().timeIntervalSince(start) < 5)
        // 일반 파일이 아니면 읽지 않는다
        #expect(GitInfo.readSmallFile(atPath: "\(root)/repo/.git") == nil)
        #expect(GitInfo.readSmallFile(atPath: "/dev/null") == nil)
    }

    /// 심볼릭 링크로 된 .git (· HEAD) 은 계속 따라간다
    @Test func symlinkedGitDirectory() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("ref: refs/heads/linked\n", to: "\(root)/store/repo.git/HEAD")
        try FileManager.default.createDirectory(atPath: "\(root)/repo", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(root)/repo/.git", withDestinationPath: "\(root)/store/repo.git")
        #expect(GitInfo.branch(forDirectory: "\(root)/repo") == "linked")

        try write("ref: refs/heads/main\n", to: "\(root)/real-head")
        try FileManager.default.createDirectory(atPath: "\(root)/repo2/.git", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(root)/repo2/.git/HEAD", withDestinationPath: "\(root)/real-head")
        #expect(GitInfo.branch(forDirectory: "\(root)/repo2") == "main")
    }

    @Test func parseHead() {
        #expect(GitInfo.parseHead("ref: refs/heads/main") == "main")
        #expect(GitInfo.parseHead("ref: refs/remotes/origin/x") == "remotes/origin/x")
        #expect(GitInfo.parseHead("abc") == nil)
        #expect(GitInfo.parseHead("") == nil)
    }
}
