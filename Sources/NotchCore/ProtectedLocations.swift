import Foundation

/// macOS 가 앱마다 접근 허락을 묻는 위치 (개인정보 보호 · TCC).
/// 여기 있는 파일을 읽기만 해도 "AgentNotch 가 '문서' 폴더의 파일에 접근하려고 합니다" 같은 창이 뜨고,
/// ad-hoc 서명 앱은 빌드 · 업데이트할 때마다 허락이 풀려 다시 묻는다. 그래서 이 위치의 파일은 직접 읽지 않는다
public enum ProtectedLocations {
    /// 홈 폴더 기준 보호 폴더 (데스크탑 · 문서 · 다운로드 · iCloud Drive · 클라우드 저장소)
    static let homeRelative = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
    /// 이동식 · 네트워크 볼륨
    static let absolute = ["/Volumes"]

    /// 경로가 보호 위치(또는 그 안)인지. 대소문자는 구분하지 않는다 (APFS 기본)
    public static func contains(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        guard !path.isEmpty else { return false }
        let target = (path as NSString).standardizingPath.lowercased()
        let homePath = (home as NSString).standardizingPath
        let roots = homeRelative.map { (homePath as NSString).appendingPathComponent($0) } + absolute
        return roots.contains { root in
            let root = root.lowercased()
            return target == root || target.hasPrefix(root + "/")
        }
    }
}
