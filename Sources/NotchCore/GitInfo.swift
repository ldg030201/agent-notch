import Foundation

/// git 정보 조회. 프로세스를 띄우지 않고 `.git` 파일만 읽는다.
///
/// 보호 폴더(`ProtectedLocations`)는 건드리지 않는다: 작업 폴더는 보호 폴더 밖이어도 worktree 의 `gitdir:` 이나
/// `.git` · `HEAD` 심볼릭 링크가 '문서' 폴더 안을 가리킬 수 있다 (예: `~/Documents/repo` 의 worktree 를 `~/code/wt` 에 둠).
/// 그 안을 stat 하기만 해도 macOS 가 접근 허락 창을 띄우므로, 링크 · `gitdir:` 을 한 칸씩 따라가며 대상 경로를 글자로 먼저 보고
/// 보호 위치면 읽지 않고 nil 을 돌려준다 (호출하는 쪽은 대화 기록의 브랜치를 쓴다)
public enum GitInfo {
    /// 상위로 올라가며 찾을 최대 디렉터리 깊이
    private static let maxDepth = 64
    /// HEAD / .git 파일 최대 읽기 크기
    private static let maxReadBytes = 4_096
    /// 따라갈 최대 심볼릭 링크 수 (macOS `MAXSYMLINKS`)
    private static let maxSymlinkHops = 32

    /// 디렉터리가 속한 git 저장소의 현재 브랜치 (실제 홈 폴더 기준 보호 폴더는 건드리지 않음).
    /// - `ref: refs/heads/x` → "x"
    /// - detached HEAD → 커밋 해시 앞 7자
    /// - 저장소가 아니거나 읽기 실패 · 보호 폴더를 거쳐야 함 → nil
    public static func branch(forDirectory directory: String) -> String? {
        branch(forDirectory: directory, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// `home` 기준 보호 폴더(`ProtectedLocations`)는 건드리지 않고 브랜치를 찾는다 (테스트는 가짜 홈)
    public static func branch(forDirectory directory: String, home: String) -> String? {
        branch(forDirectory: directory, isProtected: { ProtectedLocations.contains($0, home: home) })
    }

    /// - isProtected: 이 경로(글자)를 건드리면 안 되는지. 가는 길에 하나라도 걸리면 읽지 않고 nil
    public static func branch(forDirectory directory: String, isProtected: (String) -> Bool) -> String? {
        guard !directory.isEmpty, let gitDir = findGitDirectory(from: directory, isProtected: isProtected),
              let headPath = resolve((gitDir as NSString).appendingPathComponent("HEAD"), isProtected: isProtected),
              let head = readSmallFile(atPath: headPath)
        else { return nil }
        return parseHead(head)
    }

    /// `.git` 디렉터리(또는 worktree 의 `gitdir:` 이 가리키는 디렉터리)의 실제 경로 (심볼릭 링크를 푼 것)
    static func findGitDirectory(from directory: String, isProtected: (String) -> Bool) -> String? {
        guard var current = resolve(directory, isProtected: isProtected) else { return nil }
        for _ in 0..<maxDepth {
            let dotGit = (current as NSString).appendingPathComponent(".git")
            guard !isProtected(dotGit) else { return nil }
            var info = stat()
            if lstat(dotGit, &info) == 0 {
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    return dotGit
                case S_IFLNK:
                    // 링크 대상이 보호 위치면 그 안은 보지 않는다 (resolve 가 한 칸씩 확인)
                    guard let target = resolve(dotGit, isProtected: isProtected) else { return nil }
                    var targetInfo = stat()
                    guard lstat(target, &targetInfo) == 0 else { return nil }
                    switch targetInfo.st_mode & S_IFMT {
                    case S_IFDIR: return target
                    case S_IFREG: return gitDirectory(fromFile: target, relativeTo: current, isProtected: isProtected)
                    default: return nil
                    }
                case S_IFREG:
                    return gitDirectory(fromFile: dotGit, relativeTo: current, isProtected: isProtected)
                default:
                    return nil
                }
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == current { break }
            current = parent
        }
        return nil
    }

    /// worktree · submodule 의 `.git` 파일: "gitdir: <path>" (상대 경로면 `.git` 이 있는 폴더 `base` 기준)
    private static func gitDirectory(fromFile path: String, relativeTo base: String, isProtected: (String) -> Bool) -> String? {
        guard let content = readSmallFile(atPath: path) else { return nil }
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("gitdir:") else { continue }
            let target = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            let joined = target.hasPrefix("/") ? target : (base as NSString).appendingPathComponent(target)
            // 대상은 글자로 먼저 확인하고, 링크도 한 칸씩 확인하며 푼다
            guard !isProtected(ProtectedLocations.lexicallyNormalized(joined)) else { return nil }
            return resolve(joined, isProtected: isProtected)
        }
        return nil
    }

    /// 경로의 심볼릭 링크를 한 칸씩 푼 실제 경로 (realpath 와 같지만 보호 위치에 들어가기 전에 멈춘다).
    /// 다음에 확인할 경로를 글자로 먼저 `isProtected` 에 물어보고, 걸리면 lstat 도 하지 않고 nil.
    /// 없는 경로 · 링크가 너무 많음 · 읽기 실패도 nil. `..` 은 앞까지 푼 실제 경로 기준으로 한 칸 위
    static func resolve(_ path: String, isProtected: (String) -> Bool) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        // 앞으로 볼 경로 조각 (마지막 원소가 다음 조각)
        var remaining = Array(expanded.split(separator: "/").map(String.init).reversed())
        var resolved = ""
        var hops = 0
        while let part = remaining.popLast() {
            if part == "." { continue }
            if part == ".." {
                resolved = (resolved as NSString).deletingLastPathComponent
                if resolved == "/" { resolved = "" }
                continue
            }
            let candidate = resolved + "/" + part
            guard !isProtected(candidate) else { return nil }
            var info = stat()
            guard lstat(candidate, &info) == 0 else { return nil }
            guard info.st_mode & S_IFMT == S_IFLNK else {
                resolved = candidate
                continue
            }
            hops += 1
            guard hops <= maxSymlinkHops, let destination = readLink(candidate), !destination.isEmpty else { return nil }
            // 링크 대상의 남은 부분을 앞에 붙여 이어서 푼다 (절대 경로면 처음부터)
            if destination.hasPrefix("/") { resolved = "" }
            remaining.append(contentsOf: destination.split(separator: "/").map(String.init).reversed())
        }
        return resolved.isEmpty ? "/" : resolved
    }

    /// 심볼릭 링크 자체의 내용 (대상은 건드리지 않는다)
    private static func readLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
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

    /// 일반 파일만 앞부분 `maxReadBytes` 까지 읽는다 (심볼릭 링크는 따라감 · 부르는 쪽이 `resolve` 로 미리 푼다).
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
