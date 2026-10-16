import Foundation

// 변경 내역 데이터 모델.
//
// 내용(버전별 목록)은 App 의 `Changelog.entries` 에 있고, 여기에는 형태만 둔다.
// 업데이트 확인(`UpdateChecker`)이 원격 JSON 을 같은 형태로 읽어야 해서 Services 에 둔다.
// 쓰는 규칙은 docs/development.md 의 "변경 내역" 참고.

/// 변경 한 줄의 갈래. 화면에서 항목 앞 딱지로 붙는다.
public enum ChangeKind: String, Codable, Equatable, CaseIterable, Sendable {
    case new
    case improve
    case change
    case fix
    case remove

    /// 모르는 갈래(새 앱이 늘린 값)는 `change` 로 읽는다. 하나 때문에 내역 전체를 버리지 않는다.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ChangeKind(rawValue: raw) ?? .change
    }
}

/// 변경 한 줄
public struct ChangelogNote: Codable, Equatable, Sendable {
    public let kind: ChangeKind
    public let text: String

    public init(kind: ChangeKind, text: String) {
        self.kind = kind
        self.text = text
    }

    public static func new(_ text: String) -> Self { Self(kind: .new, text: text) }
    public static func improve(_ text: String) -> Self { Self(kind: .improve, text: text) }
    public static func change(_ text: String) -> Self { Self(kind: .change, text: text) }
    public static func fix(_ text: String) -> Self { Self(kind: .fix, text: text) }
    public static func remove(_ text: String) -> Self { Self(kind: .remove, text: text) }
}

/// 기능 단위 묶음. 제목은 화면·메뉴 이름을 그대로 쓴다 ("권한 요청", "업데이트").
public struct ChangelogGroup: Codable, Equatable, Sendable {
    public let title: String
    /// 제목 앞 아이콘 (SF Symbol 이름). 없으면(예전 내역) 화면이 기본 표시를 쓴다. 예전 앱은 이 키를 모르고 넘긴다
    public let icon: String?
    /// 설정 탭 이야기면 그 탭(`SettingsSection` rawValue: general / display / shortcuts / version). 탭에 없으면 nil.
    public let tab: String?
    /// 묶음 자체가 이번에 새로 생긴 기능인지. 신규 묶음의 줄에는 갈래를 따로 붙이지 않는다.
    public let isNew: Bool
    public let notes: [ChangelogNote]

    public init(title: String, icon: String? = nil, tab: String? = nil, isNew: Bool = false, notes: [ChangelogNote]) {
        self.title = title
        self.icon = icon
        self.tab = tab
        self.isNew = isNew
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case title, icon, tab, isNew, notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        tab = try container.decodeIfPresent(String.self, forKey: .tab)
        isNew = try container.decodeIfPresent(Bool.self, forKey: .isNew) ?? false
        notes = try container.decodeIfPresent([ChangelogNote].self, forKey: .notes) ?? []
    }
}

/// 한 버전의 변경 내역
public struct ChangelogEntry: Codable, Equatable, Sendable {
    public let version: String
    /// 아직 내보내지 않은 항목은 nil. `scripts/release.sh` 가 릴리스할 때 날짜를 채운다.
    public let date: String?
    /// 평평한 목록 (`[묶음] 내용`). `groups` 에서 만들어 내므로 손으로 적지 않는다.
    public let notes: [String]
    public let groups: [ChangelogGroup]?

    public init(version: String, date: String?, groups: [ChangelogGroup]) {
        self.version = version
        self.date = date
        self.groups = groups
        notes = groups.flatMap { group in
            group.notes.map { "[\(group.title)] \($0.text)" }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, date, notes, groups
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        groups = try container.decodeIfPresent([ChangelogGroup].self, forKey: .groups)
        notes = try container.decodeIfPresent([String].self, forKey: .notes)
            ?? (groups ?? []).flatMap { group in group.notes.map { "[\(group.title)] \($0.text)" } }
    }
}

/// 원격 변경 내역 파일(`docs/changelog.json`)의 형태
public struct ChangelogFeed: Codable, Equatable, Sendable {
    public let entries: [ChangelogEntry]

    public init(entries: [ChangelogEntry]) {
        self.entries = entries
    }

    /// `--dump-changelog` 가 쓰는 JSON.
    /// 키 순서를 고정해야(`.sortedKeys`) 같은 소스에서 항상 같은 파일이 나온다 (CI 가 저장소 파일과 비교).
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}
