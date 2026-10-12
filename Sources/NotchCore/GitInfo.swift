import Foundation

/// git 정보 조회. 프로세스를 띄우지 않고 `.git` 파일만 읽는다.
public enum GitInfo {
    /// 상위로 올라가며 찾을 최대 디렉터리 깊이
    private static let maxDepth = 64
    /// HEAD / .git 파일 최대 읽기 크기
    private static let maxReadBytes = 4_096

    /// 디렉터리가 속한 git 저장소의 현재 브랜치.
    /// - `ref: refs/heads/x` → "x"
    /// - detached HEAD → 커밋 해시 앞 7자
    /// - 저장소가 아니거나 읽기 실패 → nil
    public static func branch(forDirectory directory: String) -> String? {
        guard !directory.isEmpty, let gitDir = findGitDirectory(from: directory) else { return nil }
        guard let head = readSmallFile(atPath: (gitDir as NSString).appendingPathComponent("HEAD")) else { return nil }
        return parseHead(head)
    }

    /// `.git` 디렉터리(또는 worktree 의 `gitdir:` 이 가리키는 디렉터리) 경로
    static func findGitDirectory(from directory: String) -> String? {
        let fileManager = FileManager.default
        var current = (directory as NSString).standardizingPath
        for _ in 0..<maxDepth {
            let dotGit = (current as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return dotGit }
                // worktree · submodule: "gitdir: <path>" (상대 경로면 .git 파일 위치 기준)
                guard let content = readSmallFile(atPath: dotGit) else { return nil }
                for line in content.split(whereSeparator: \.isNewline) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("gitdir:") else { continue }
                    let target = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    guard !target.isEmpty else { return nil }
                    let resolved = target.hasPrefix("/") ? target : (current as NSString).appendingPathComponent(target)
                    return (resolved as NSString).standardizingPath
                }
                return nil
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == current { break }
            current = parent
        }
        return nil
    }

    static func parseHead(_ content: String) -> String? {
        let head = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else { return nil }
        if head.hasPrefix("ref:") {
            let ref = head.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
            if ref.hasPrefix("refs/heads/") { return TextUtils.nonEmpty(String(ref.dropFirst("refs/heads/".count))) }
            if ref.hasPrefix("refs/") { return TextUtils.nonEmpty(String(ref.dropFirst("refs/".count))) }
            return TextUtils.nonEmpty(ref)
        }
        // detached HEAD: 커밋 해시
        let sha = head.prefix(while: \.isHexDigit)
        guard sha.count >= 7 else { return nil }
        return String(sha.prefix(7))
    }

    /// 일반 파일만 앞부분 `maxReadBytes` 까지 읽는다 (심볼릭 링크는 따라감).
    /// FIFO · 장치 파일은 열기만 해도 메인 스레드가 멈추거나 부작용이 있을 수 있어 먼저 stat 으로 거르고,
    /// 확인과 열기 사이에 바뀌는 경우를 위해 논블로킹으로 열어 fstat 으로 한 번 더 확인한다.
    static func readSmallFile(atPath path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOCTTY)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let data = try? handle.read(upToCount: maxReadBytes)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
