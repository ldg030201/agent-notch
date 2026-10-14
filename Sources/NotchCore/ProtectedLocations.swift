import Foundation

/// macOS 가 앱마다 접근 허락을 묻는 위치 (개인정보 보호 · TCC).
/// 여기 있는 파일을 읽기만 해도 "AgentNotch 가 '문서' 폴더의 파일에 접근하려고 합니다" 같은 창이 뜨고,
/// ad-hoc 서명 앱은 빌드 · 업데이트할 때마다 허락이 풀려 다시 묻는다. 그래서 이 위치의 파일은 직접 읽지 않는다
public enum ProtectedLocations {
    /// 홈 폴더 기준 보호 폴더 (데스크탑 · 문서 · 다운로드 · iCloud Drive · 클라우드 저장소)
    static let homeRelative = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
    /// 이동식 · 네트워크 볼륨
    static let absolute = ["/Volumes"]
    /// 데이터 볼륨의 실제 경로 (`/System/Volumes/Data/Users/x` 는 `/Users/x` 와 같은 곳)
    static let dataVolumePrefix = "/system/volumes/data/"

    /// 경로가 보호 위치(또는 그 안)인지. 글자로만 판단하고 파일 시스템은 건드리지 않는다.
    /// 대소문자는 구분하지 않는다 (APFS 기본)
    public static func contains(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        guard !path.isEmpty else { return false }
        var target = lexicallyNormalized(path).lowercased()
        if target.hasPrefix(dataVolumePrefix) { target = String(target.dropFirst(dataVolumePrefix.count - 1)) }
        let homePath = lexicallyNormalized(home)
        let roots = homeRelative.map { (homePath as NSString).appendingPathComponent($0) } + absolute
        return roots.contains { root in
            let root = root.lowercased()
            return target == root || target.hasPrefix(root + "/")
        }
    }

    /// 파일 시스템을 건드리지 않고 경로를 정리한다: `~` 펼침, 빈 칸 · `.` 제거, `..` 은 글자로만 한 칸 위.
    /// (`NSString.standardizingPath` 는 OS 버전에 따라 `..` 을 풀려고 심볼릭 링크를 확인하러 디스크를 볼 수 있다)
    static func lexicallyNormalized(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let isAbsolute = expanded.hasPrefix("/")
        var parts: [Substring] = []
        for part in expanded.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                if let last = parts.last, last != ".." {
                    parts.removeLast()
                } else if !isAbsolute {
                    parts.append(part)
                }
            default:
                parts.append(part)
            }
        }
        let joined = parts.joined(separator: "/")
        return isAbsolute ? "/" + joined : joined
    }
}
