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

    // MARK: - 보호 폴더 (가짜 홈)

    /// 심볼릭 링크를 푼 실제 경로의 임시 폴더 (/tmp → /private/tmp). 가짜 홈 기준 보호 폴더 판정이 실제 경로와 맞게
    private func makePhysicalTempRoot() throws -> String {
        let root = try makeTempRoot()
        return try #require(realpath(root, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
    }

    /// 보호 폴더 판정을 기록하는 검사기. 허락한(= lstat · 읽기를 했을 수 있는) 경로가 실제로 보호 폴더 안이었는지 확인한다
    final class ProtectionProbe {
        let home: String
        private(set) var allowed: [String] = []
        init(home: String) { self.home = home }
        func isProtected(_ path: String) -> Bool {
            let protected = ProtectedLocations.contains(path, home: home)
            if !protected { allowed.append(path) }
            return protected
        }
        /// 허락한 경로 중 실제 위치(부모 폴더의 링크를 푼 것)가 보호 폴더 안인 것 (있으면 안 된다)
        var touchedInside: [String] {
            allowed.filter { path in
                let parent = (path as NSString).deletingLastPathComponent
                guard let real = realpath(parent, nil) else { return false }
                defer { free(real) }
                let physical = (String(cString: real) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
                return ProtectedLocations.contains(physical, home: home)
            }
        }
    }

    /// worktree 의 `gitdir:` 이 '문서' 폴더 안 저장소를 가리키면 따라가지 않는다 (HEAD 를 stat 만 해도 접근 허락 창이 뜬다)
    @Test func worktreeGitdirIntoProtectedFolderIsNotRead() throws {
        let root = try makePhysicalTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let home = "\(root)/home"
        try write("ref: refs/heads/main\n", to: "\(home)/Documents/repo/.git/HEAD")
        try write("ref: refs/heads/wt-branch\n", to: "\(home)/Documents/repo/.git/worktrees/wt/HEAD")
        // 절대 경로 · 상대 경로 gitdir
        try write("gitdir: \(home)/Documents/repo/.git/worktrees/wt\n", to: "\(home)/code/wt/.git")
        try write("gitdir: ../../Documents/repo/.git/worktrees/wt\n", to: "\(home)/code/wt2/.git")
        // 보호 폴더 밖 저장소의 worktree 는 그대로 읽는다
        try write("ref: refs/heads/feature\n", to: "\(home)/code/main/.git/worktrees/wt3/HEAD")
        try write("gitdir: ../main/.git/worktrees/wt3\n", to: "\(home)/code/wt3/.git")

        for directory in ["\(home)/code/wt", "\(home)/code/wt2"] {
            let probe = ProtectionProbe(home: home)
            #expect(GitInfo.branch(forDirectory: directory, isProtected: probe.isProtected) == nil, "\(directory)")
            #expect(probe.touchedInside.isEmpty, "\(directory)")
            #expect(!probe.allowed.isEmpty, "\(directory)")
            #expect(GitInfo.branch(forDirectory: directory, home: home) == nil)
        }
        #expect(GitInfo.branch(forDirectory: "\(home)/code/wt3", home: home) == "feature")
        // 같은 구조라도 보호 폴더가 아니면 (진짜 홈 기준) 예전처럼 읽는다
        #expect(GitInfo.branch(forDirectory: "\(home)/code/wt") == "wt-branch")
        #expect(GitInfo.branch(forDirectory: "\(home)/code/wt2") == "wt-branch")
    }

    /// `.git` · `HEAD` 심볼릭 링크, 작업 폴더 중간의 링크가 보호 폴더를 가리켜도 따라가지 않는다 (링크를 한 칸씩 확인)
    @Test func symlinksIntoProtectedFolderAreNotFollowed() throws {
        let root = try makePhysicalTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let home = "\(root)/home"
        let fileManager = FileManager.default
        try write("ref: refs/heads/secret\n", to: "\(home)/Desktop/repo/.git/HEAD")
        try write("ref: refs/heads/secret\n", to: "\(home)/Downloads/HEAD")

        // .git → 보호 폴더 (바로)
        try fileManager.createDirectory(atPath: "\(home)/code/a", withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: "\(home)/code/a/.git", withDestinationPath: "\(home)/Desktop/repo/.git")
        // .git → 보호 폴더 밖 링크 → 보호 폴더 (두 번째 칸에서 걸림)
        try fileManager.createDirectory(atPath: "\(home)/code/b", withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: "\(home)/code/hop", withDestinationPath: "../Desktop/repo/.git")
        try fileManager.createSymbolicLink(atPath: "\(home)/code/b/.git", withDestinationPath: "../hop")
        // HEAD → 보호 폴더
        try fileManager.createDirectory(atPath: "\(home)/code/c/.git", withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: "\(home)/code/c/.git/HEAD", withDestinationPath: "\(home)/Downloads/HEAD")
        // 작업 폴더 경로 중간의 링크 → 보호 폴더
        try fileManager.createSymbolicLink(atPath: "\(home)/code/desk", withDestinationPath: "\(home)/Desktop")

        for directory in ["\(home)/code/a", "\(home)/code/b", "\(home)/code/c", "\(home)/code/desk/repo"] {
            let probe = ProtectionProbe(home: home)
            #expect(GitInfo.branch(forDirectory: directory, isProtected: probe.isProtected) == nil, "\(directory)")
            #expect(probe.touchedInside.isEmpty, "\(directory)")
            #expect(!probe.allowed.isEmpty, "\(directory)")
        }
        // 보호 폴더 밖이면 링크도 따라간다 (진짜 홈 기준)
        #expect(GitInfo.branch(forDirectory: "\(home)/code/a") == "secret")
        #expect(GitInfo.branch(forDirectory: "\(home)/code/b") == "secret")
        #expect(GitInfo.branch(forDirectory: "\(home)/code/c") == "secret")
    }

    @Test func resolveFollowsLinksHopByHop() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: "\(root)/real/dir", withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: "\(root)/link", withDestinationPath: "real")
        let physical = try #require(GitInfo.resolve(root, isProtected: { _ in false }))
        #expect(GitInfo.resolve("\(root)/link/dir", isProtected: { _ in false }) == "\(physical)/real/dir")
        // .. 은 링크를 푼 뒤 기준
        #expect(GitInfo.resolve("\(root)/link/../real", isProtected: { _ in false }) == "\(physical)/real")
        #expect(GitInfo.resolve("\(root)/missing", isProtected: { _ in false }) == nil)
        #expect(GitInfo.resolve("relative/path", isProtected: { _ in false }) == nil)
        // 순환 링크
        try fileManager.createSymbolicLink(atPath: "\(root)/loop1", withDestinationPath: "loop2")
        try fileManager.createSymbolicLink(atPath: "\(root)/loop2", withDestinationPath: "loop1")
        #expect(GitInfo.resolve("\(root)/loop1", isProtected: { _ in false }) == nil)
        // 보호 판정에 걸리면 그 경로는 lstat 하지 않고 멈춘다
        var asked: [String] = []
        #expect(GitInfo.resolve("\(root)/real/dir", isProtected: { asked.append($0); return $0.hasSuffix("/real") }) == nil)
        #expect(asked.last?.hasSuffix("/real") == true)
    }

    @Test func parseHead() {
        #expect(GitInfo.parseHead("ref: refs/heads/main") == "main")
        #expect(GitInfo.parseHead("ref: refs/remotes/origin/x") == "remotes/origin/x")
        #expect(GitInfo.parseHead("abc") == nil)
        #expect(GitInfo.parseHead("") == nil)
    }
}
