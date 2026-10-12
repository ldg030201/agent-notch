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

    @Test func parseHead() {
        #expect(GitInfo.parseHead("ref: refs/heads/main") == "main")
        #expect(GitInfo.parseHead("ref: refs/remotes/origin/x") == "remotes/origin/x")
        #expect(GitInfo.parseHead("abc") == nil)
        #expect(GitInfo.parseHead("") == nil)
    }
}
