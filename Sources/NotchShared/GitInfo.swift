import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// git 브랜치 읽기. 프로세스를 띄우지 않고 `.git` 의 HEAD 만 읽는다.
///
/// 훅 헬퍼(`notch-hook`)가 SessionStart · UserPromptSubmit 때 payload 의 `cwd` 로 읽어 앱에 보낸다 (`NotchWire.attachingGitBranch`).
/// 헬퍼는 Claude Code(터미널 · Claude 앱) 프로세스 안에서 돌아 그 프로젝트 폴더를 이미 볼 수 있으므로 macOS 접근 허락 창이 뜨지 않는다.
/// 앱은 프로젝트 폴더를 직접 읽지 않는다: 보호 폴더(문서 · 데스크탑 · 다운로드 · iCloud 등)는 읽기만 해도 앱에 허락 창이 뜨고,
/// ad-hoc 서명이라 빌드 · 업데이트마다 다시 묻는다
public enum GitInfo {
    /// 상위로 올라가며 찾을 최대 디렉터리 깊이
    static let maxDepth = 64
    /// HEAD / .git 파일 최대 읽기 크기
    static let maxReadBytes = 4_096

    /// 디렉터리가 속한 git 저장소의 현재 브랜치.
    /// - `ref: refs/heads/x` → "x"
    /// - detached HEAD → 커밋 해시 앞 7자
    /// - 저장소가 아니거나 읽기 실패 → nil
    public static func branch(forDirectory directory: String) -> String? {
        guard !directory.isEmpty, let gitDir = findGitDirectory(from: directory),
              let head = readSmallFile(atPath: (gitDir as NSString).appendingPathComponent("HEAD"))
        else { return nil }
        return parseHead(head)
    }

    /// `.git` 디렉터리(또는 worktree · submodule 의 `gitdir:` 이 가리키는 디렉터리). 위로 올라가며 처음 만난 `.git` 을 본다
    static func findGitDirectory(from directory: String) -> String? {
        var current = directory
        for _ in 0..<maxDepth {
            let dotGit = (current as NSString).appendingPathComponent(".git")
            var info = stat()
            if lstat(dotGit, &info) == 0 {
                // 심볼릭 링크면 대상을 본다 (깨진 링크는 nil)
                if info.st_mode & S_IFMT == S_IFLNK, stat(dotGit, &info) != 0 { return nil }
                switch info.st_mode & S_IFMT {
                case S_IFDIR: return dotGit
                case S_IFREG: return gitDirectory(fromFile: dotGit, relativeTo: current)
                default: return nil
                }
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == current { break }
            current = parent
        }
        return nil
    }

    /// worktree · submodule 의 `.git` 파일: "gitdir: <path>" (상대 경로면 `.git` 이 있는 폴더 `base` 기준)
    private static func gitDirectory(fromFile path: String, relativeTo base: String) -> String? {
        guard let content = readSmallFile(atPath: path) else { return nil }
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("gitdir:") else { continue }
            let target = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            return target.hasPrefix("/") ? target : (base as NSString).appendingPathComponent(target)
        }
        return nil
    }

    static func parseHead(_ content: String) -> String? {
        let head = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else { return nil }
        if head.hasPrefix("ref:") {
            let ref = head.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
            let name = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count))
                : ref.hasPrefix("refs/") ? String(ref.dropFirst("refs/".count))
                : ref
            return name.isEmpty ? nil : name
        }
        // detached HEAD: 커밋 해시
        let sha = head.prefix(while: \.isHexDigit)
        guard sha.count >= 7 else { return nil }
        return String(sha.prefix(7))
    }

    /// 일반 파일만 앞부분 `maxReadBytes` 까지 읽는다 (심볼릭 링크는 따라감).
    /// FIFO · 장치 파일은 열기만 해도 멈추거나 부작용이 있을 수 있어 먼저 stat 으로 거르고,
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
