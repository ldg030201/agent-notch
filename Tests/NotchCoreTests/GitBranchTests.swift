import Foundation
import Testing
@testable import NotchCore
@testable import NotchShared

/// 브랜치는 훅 헬퍼가 읽어 보낸다 (`NotchWire.attachingGitBranch`, SessionStart · UserPromptSubmit 만).
/// 앱은 프로젝트 폴더를 읽지 않고, 헬퍼가 보내지 않으면(예전 헬퍼) `~/.claude` 아래 대화 기록의 브랜치를 쓴다
@Suite struct GitBranchTests {
    /// /tmp 아래 임시 폴더 (git 프로세스 사용 안 함)
    private func makeTempRoot() throws -> String {
        let root = "/tmp/agentnotch-git-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - HEAD 읽기 (헬퍼)

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
        // 상대 경로 · 절대 경로 gitdir
        try write("gitdir: ../repo/.git/worktrees/wt\n", to: "\(root)/wt/.git")
        try write("gitdir: \(root)/repo/.git/worktrees/wt\n", to: "\(root)/wt2/.git")

        #expect(GitInfo.branch(forDirectory: "\(root)/wt") == "wt-branch")
        #expect(GitInfo.branch(forDirectory: "\(root)/wt2") == "wt-branch")
        #expect(GitInfo.branch(forDirectory: "\(root)/repo") == "main")
    }

    @Test func detachedHeadAndRefs() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("0123456789abcdef0123456789abcdef01234567\n", to: "\(root)/repo/.git/HEAD")
        #expect(GitInfo.branch(forDirectory: "\(root)/repo") == "0123456")

        #expect(GitInfo.parseHead("ref: refs/heads/main") == "main")
        #expect(GitInfo.parseHead("ref: refs/remotes/origin/x") == "remotes/origin/x")
        #expect(GitInfo.parseHead("ref: refs/heads/") == nil)
        #expect(GitInfo.parseHead("abc") == nil)
        #expect(GitInfo.parseHead("") == nil)
    }

    @Test func notARepository() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: "\(root)/plain", withIntermediateDirectories: true)
        #expect(GitInfo.branch(forDirectory: "\(root)/plain") == nil)
        #expect(GitInfo.branch(forDirectory: "") == nil)
        // 깨진 .git 파일 · 깨진 링크
        try write("garbage\n", to: "\(root)/broken/.git")
        #expect(GitInfo.branch(forDirectory: "\(root)/broken") == nil)
        try FileManager.default.createDirectory(atPath: "\(root)/dangling", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(root)/dangling/.git", withDestinationPath: "\(root)/missing")
        #expect(GitInfo.branch(forDirectory: "\(root)/dangling") == nil)
    }

    /// FIFO 로 된 HEAD · .git 은 열다가 멈추지 않고 바로 nil (훅이 Claude Code 를 막지 않게)
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
        #expect(GitInfo.readSmallFile(atPath: "\(root)/repo/.git") == nil)
        #expect(GitInfo.readSmallFile(atPath: "/dev/null") == nil)
    }

    /// 심볼릭 링크로 된 .git · HEAD 는 따라간다
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

    // MARK: - 헬퍼가 붙이는 브랜치

    @Test func helperAttachesBranchOnlyForSessionStartAndPrompt() {
        var asked: [String] = []
        let read: (String) -> String? = { cwd in
            asked.append(cwd)
            return cwd == "/work/repo" ? "feature" : nil
        }
        let payload = json(#"{"session_id":"s1","cwd":"/work/repo","prompt":"hi"}"#)
        for event in ["SessionStart", "UserPromptSubmit"] {
            let attached = NotchWire.attachingGitBranch(to: payload, event: event, readBranch: read)
            #expect(attached[NotchWire.gitBranchKey] == .string("feature"), "\(event)")
            #expect(attached["prompt"] == .string("hi"))
        }
        // 저장소가 아니면 빈 문자열 (헬퍼가 확인했다는 표시)
        let plain = NotchWire.attachingGitBranch(to: json(#"{"cwd":"/work/plain"}"#), event: "SessionStart", readBranch: read)
        #expect(plain[NotchWire.gitBranchKey] == .string(""))
        #expect(asked == ["/work/repo", "/work/repo", "/work/plain"])

        // 다른 이벤트(특히 화면을 막는 MessageDisplay) · cwd 없음은 읽지 않고 그대로
        asked = []
        for event in ["MessageDisplay", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "Stop", "SubagentStop"] {
            #expect(NotchWire.attachingGitBranch(to: payload, event: event, readBranch: read) == payload, "\(event)")
        }
        let noCwd = json(#"{"session_id":"s1"}"#)
        #expect(NotchWire.attachingGitBranch(to: noCwd, event: "SessionStart", readBranch: read) == noCwd)
        #expect(asked.isEmpty)
    }

    @Test func helperReadsRealRepository() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("ref: refs/heads/develop\n", to: "\(root)/repo/.git/HEAD")
        let payload = JSONValue.object(["cwd": .string("\(root)/repo/sub")])
        #expect(NotchWire.attachingGitBranch(to: payload, event: "UserPromptSubmit")[NotchWire.gitBranchKey] == .string("develop"))
    }

    /// 헬퍼가 큰 payload 를 줄여도 브랜치는 모든 단계에서 남는다
    @Test func shrinkerKeepsBranchAtEveryLevel() {
        let payload = JSONValue.object([
            "hook_event_name": .string("UserPromptSubmit"),
            "session_id": .string("s1"),
            "cwd": .string("/work/repo"),
            "prompt": .string(String(repeating: "x", count: 100_000)),
            "tool_input": .object(["content": .string("y")]),
            NotchWire.gitBranchKey: .string("feature/login"),
        ])
        for level in 1...PayloadShrinker.maxLevel {
            let shrunk = PayloadShrinker.shrink(payload, level: level)
            #expect(shrunk[NotchWire.gitBranchKey] == .string("feature/login"), "level \(level)")
            #expect(shrunk["session_id"] == .string("s1"), "level \(level)")
            #expect(shrunk[NotchWire.truncatedMarkerKey] == .bool(true), "level \(level)")
        }
        #expect(PayloadShrinker.identityKeys.contains(NotchWire.gitBranchKey))
    }

    // MARK: - 앱

    @Test func claudeDirectoryCheckIsLexical() {
        let home = "/Users/dev"
        #expect(TranscriptTail.isInClaudeDirectory("/Users/dev/.claude/projects/p/s.jsonl", home: home))
        #expect(!TranscriptTail.isInClaudeDirectory("/Users/dev/.claude", home: home))
        #expect(!TranscriptTail.isInClaudeDirectory("/Users/dev/.claudex/p/s.jsonl", home: home))
        #expect(!TranscriptTail.isInClaudeDirectory("/Users/dev/.claude/../Documents/s.jsonl", home: home))
        #expect(!TranscriptTail.isInClaudeDirectory("/Users/dev/.claude/./p/s.jsonl", home: home))
        #expect(!TranscriptTail.isInClaudeDirectory("/Users/dev/Documents/s.jsonl", home: home))
        #expect(!TranscriptTail.isInClaudeDirectory("relative/.claude/s.jsonl", home: home))
        #expect(!TranscriptTail.isInClaudeDirectory("/Users/dev/.claude/s.jsonl", home: ""))
    }

    /// 앱은 헬퍼가 보낸 브랜치를 쓰고, 작업 폴더가 git 저장소여도 직접 읽지 않는다
    @MainActor @Test func storeUsesHelperBranchAndNeverReadsProject() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // 작업 폴더는 진짜 저장소지만 앱은 읽지 않는다
        try write("ref: refs/heads/on-disk\n", to: "\(root)/repo/.git/HEAD")
        let cwd = "\(root)/repo"
        let store = makeStore(TestClock())
        store.homeDirectory = "\(root)/home"

        store.ingest(hook("PreToolUse", cwd: cwd, #"{"tool_name":"Read","tool_use_id":"r1","tool_input":{}}"#))
        #expect(store.sessions["s1"]?.gitBranch == nil)

        store.ingest(hook("UserPromptSubmit", cwd: cwd, #"{"prompt":"go","_agent_notch_git_branch":"feature/x"}"#))
        #expect(store.sessions["s1"]?.gitBranch == "feature/x")
        // 헬퍼가 저장소가 아니라고 알림 (빈 문자열)
        store.ingest(hook("SessionStart", cwd: cwd, #"{"source":"clear","_agent_notch_git_branch":""}"#))
        #expect(store.sessions["s1"]?.gitBranch == nil)

        // 새 세션도 SessionStart 의 브랜치로 만든다
        store.ingest(hook("SessionStart", session: "s2", cwd: cwd, #"{"source":"startup","_agent_notch_git_branch":"main"}"#))
        #expect(store.sessions["s2"]?.gitBranch == "main")

        // 되살린 세션은 대화 기록에 적힌 브랜치만 쓴다
        store.restore([
            RestoredSession(id: "r1", cwd: cwd, gitBranch: "from-transcript", state: .thinking, lastEventAt: Date()),
            RestoredSession(id: "r2", cwd: cwd, state: .thinking, lastEventAt: Date()),
        ])
        #expect(store.sessions["r1"]?.gitBranch == "from-transcript")
        #expect(store.sessions["r2"]?.gitBranch == nil)
    }

    /// 헬퍼가 브랜치를 보내지 않으면(예전 헬퍼) `~/.claude` 아래 대화 기록의 브랜치를 쓴다. 그 밖의 기록은 읽지 않는다
    @MainActor @Test func storeFallsBackToTranscriptUnderClaudeDirectory() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let home = "\(root)/home"
        let transcript = "\(home)/.claude/projects/p/s1.jsonl"
        try write(#"{"type":"user","gitBranch":"from-transcript"}"# + "\n", to: transcript)
        let outside = "\(root)/elsewhere/s3.jsonl"
        try write(#"{"type":"user","gitBranch":"outside"}"# + "\n", to: outside)

        let store = makeStore(TestClock())
        store.homeDirectory = home
        store.ingest(hook("SessionStart", cwd: projectCwd, #"{"source":"startup","transcript_path":"\#(transcript)"}"#))
        #expect(store.sessions["s1"]?.gitBranch == "from-transcript")

        // 기록에 브랜치가 없으면 알던 값을 그대로 둔다
        try write(#"{"type":"user"}"# + "\n", to: transcript)
        store.ingest(hook("UserPromptSubmit", cwd: projectCwd, #"{"prompt":"go","transcript_path":"\#(transcript)"}"#))
        #expect(store.sessions["s1"]?.gitBranch == "from-transcript")

        store.ingest(hook("SessionStart", session: "s3", cwd: projectCwd, #"{"source":"startup","transcript_path":"\#(outside)"}"#))
        #expect(store.sessions["s3"] != nil)
        #expect(store.sessions["s3"]?.gitBranch == nil)
    }
}
