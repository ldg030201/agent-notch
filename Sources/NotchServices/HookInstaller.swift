import CryptoKit
import Darwin
import Foundation
import NotchShared
import os

/// 훅 설정 파일(Claude Code `~/.claude/settings.json` · Codex `~/.codex/hooks.json`)에 AgentNotch 훅이 설치된 상태
public enum HookInstallStatus: Equatable, Sendable, CustomStringConvertible {
    case notInstalled
    case installed
    /// 일부 이벤트에만 설치됨 (빠진 이벤트 이름)
    case partial(missing: [String])
    /// 훅은 있는데 헬퍼 실행 파일이 없음 (훅 실행이 매번 실패한다)
    case helperMissing

    public var description: String {
        switch self {
        case .notInstalled: return "설치 안 됨"
        case .installed: return "설치됨"
        case .partial: return "일부만 설치됨"
        case .helperMissing: return "헬퍼 없음"
        }
    }
}

public enum HookInstallerError: Error, Equatable, LocalizedError {
    /// settings.json 이 JSON 객체가 아님 (수정하지 않음)
    case invalidSettings(String)
    /// 복사할 헬퍼 실행 파일이 없음
    case helperSourceMissing
    /// 파일 쓰기 실패
    case writeFailed(path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidSettings(let reason): return "훅 설정 파일 형식 오류 (\(reason)). 파일은 그대로 둠"
        case .helperSourceMissing: return "notch-hook 헬퍼를 찾을 수 없음"
        case .writeFailed(_, let code): return "파일 저장 실패 (\(String(cString: strerror(code))))"
        }
    }
}

/// 에이전트의 훅 설정에 AgentNotch 항목을 추가/제거한다.
/// - Claude Code: `~/.claude/settings.json` 의 `hooks`
/// - Codex: `~/.codex/hooks.json` 의 `hooks` (같은 모양: 이벤트 → matcher 그룹 → 훅 항목). 명령에 `--agent codex` 를 붙인다.
///   Codex 는 새 훅(사용자 훅 포함)을 사용자가 검토해 믿을 때까지 실행하지 않는다 (Codex 앱 · CLI `/hooks`).
///   믿음은 항목 내용에 묶이므로 이미 있는 항목은 내용이 바뀔 때만 고친다
///
/// - 다른 키와 다른 훅(예: iTerm2 `cc-status`)은 건드리지 않는다.
/// - 기존 파일을 바꾸기 전에 타임스탬프 백업(0600)을 남긴다.
/// - 명령에 `AgentNotch/bin/notch-hook` 이 들어 있는 항목만 우리 것으로 본다.
public final class HookInstaller {
    /// 우리 훅 명령을 알아보는 표식
    public static let marker = "AgentNotch/bin/notch-hook"

    /// Claude Code 에서 관리하는 이벤트 (MessageDisplay 는 설정에 따라 선택)
    public static let managedEvents: [String] = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "PermissionRequest",
        "Notification",
        "MessageDisplay",
        "Stop",
        "StopFailure",
        "SubagentStart",
        "SubagentStop",
        "PreCompact",
        "PostCompact",
    ]

    /// Codex 에서 관리하는 이벤트 (Codex 훅이 보내는 이벤트 전부. Notification · MessageDisplay · StopFailure ·
    /// PostToolUseFailure 는 Codex 에 없고, 사용자 중단은 Interrupt 로 온다)
    public static let codexManagedEvents: [String] = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "Stop",
        "SubagentStart",
        "SubagentStop",
        "PreCompact",
        "PostCompact",
        "Interrupt",
    ]

    /// 설치 여부를 사용자가 고를 수 있는 이벤트 (status 계산에서 필수로 보지 않음)
    public static let optionalEvents: Set<String> = ["MessageDisplay"]

    /// `matcher: "*"` 를 붙이는 툴 이벤트
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"]

    /// 헬퍼가 앱 응답을 기다리는 이벤트: 권한 요청, 질문 · 계획 승인 툴의 PreToolUse
    /// (PreToolUse 는 그 두 툴일 때만 기다리고 다른 툴은 바로 끝난다 — `NotchWire.expectsReply`).
    /// Codex 는 권한 요청만 (Codex 질문은 훅으로 답할 수 없다)
    static func replyEvents(for agent: AgentKind) -> Set<String> {
        switch agent {
        case .claude: return ["PermissionRequest", "PreToolUse"]
        case .codex: return ["PermissionRequest"]
        }
    }

    /// Codex 가 권한 요청 훅을 기다리는 동안 Codex 화면에 보여 줄 문구 (`statusMessage`)
    static let codexPermissionStatusMessage = "AgentNotch: 노치에서 승인 기다리는 중"

    public static var defaultSettingsURL: URL {
        NotchServices.claudeDirectory.appendingPathComponent("settings.json")
    }

    /// Codex 사용자 훅 파일 (`~/.codex/hooks.json`)
    public static var defaultCodexHooksURL: URL {
        NotchServices.codexDirectory.appendingPathComponent("hooks.json")
    }

    /// 에이전트별 기본 훅 설정 파일
    public static func defaultSettingsURL(for agent: AgentKind) -> URL {
        switch agent {
        case .claude: return defaultSettingsURL
        case .codex: return defaultCodexHooksURL
        }
    }

    public static var defaultHelperInstallURL: URL {
        NotchWire.appSupportDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("notch-hook")
    }

    /// 이 설치기가 다루는 에이전트
    public let agent: AgentKind
    public let settingsURL: URL
    public let helperInstallURL: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private let log = NotchServices.logger("hooks")

    /// - settingsURL: 없으면 에이전트의 기본 파일 (`defaultSettingsURL(for:)`)
    public init(
        agent: AgentKind = .claude,
        settingsURL: URL? = nil,
        helperInstallURL: URL = HookInstaller.defaultHelperInstallURL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.agent = agent
        self.settingsURL = settingsURL ?? Self.defaultSettingsURL(for: agent)
        self.helperInstallURL = helperInstallURL
        self.fileManager = fileManager
        self.now = now
    }

    /// 이 에이전트에서 관리하는 이벤트
    public var managedEvents: [String] {
        switch agent {
        case .claude: return Self.managedEvents
        case .codex: return Self.codexManagedEvents
        }
    }

    // MARK: - 상태

    public func status() -> HookInstallStatus {
        let installed = installedEvents()
        let required = managedEvents.filter { !Self.optionalEvents.contains($0) }
        let missing = required.filter { !installed.contains($0) }

        if missing.count == required.count { return .notInstalled }
        if !fileManager.isExecutableFile(atPath: helperInstallURL.path) { return .helperMissing }
        return missing.isEmpty ? .installed : .partial(missing: missing)
    }

    /// AgentNotch 훅이 하나라도 걸려 있는 이벤트 이름들 (설정을 읽을 수 없으면 빈 집합)
    public func installedEvents() -> Set<String> {
        guard let root = try? readSettings()?.value, let hooks = root["hooks"]?.objectValue else { return [] }
        var events = Set<String>()
        for (event, groups) in hooks where containsManagedHook(groups) {
            events.insert(event)
        }
        return events
    }

    /// 설치된 AgentNotch 훅 항목의 지문 (이벤트 · 항목 내용의 SHA-256). 설치돼 있지 않으면 nil.
    /// Codex 는 훅 항목 내용에 믿음을 묶으므로, 지문이 바뀌면(설치 · 고치기) 사용자가 다시 허용해야 할 수 있다.
    /// 앱은 이 지문으로 "이 훅 내용으로 이벤트를 받아 봤다" 를 기억한다
    public func managedFingerprint() -> String? {
        guard let root = try? readSettings()?.value, let hooks = root["hooks"]?.objectValue else { return nil }
        var parts: [JSONValue] = []
        for event in hooks.keys.sorted() {
            for group in hooks[event]?.arrayValue ?? [] {
                for entry in group["hooks"]?.arrayValue ?? [] where isManaged(entry) {
                    parts.append(.object(["event": .string(event), "matcher": group["matcher"] ?? .null, "entry": entry]))
                }
            }
        }
        guard !parts.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(JSONValue.array(parts)) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 훅 설정 파일을 마지막으로 바꾼 시각 (없으면 nil)
    public func settingsModifiedAt() -> Date? {
        (try? fileManager.attributesOfItem(atPath: settingsURL.path)[.modificationDate]) as? Date
    }

    // MARK: - 설치 / 제거

    /// 헬퍼를 복사하고 훅을 등록한다. 기존 설정 파일을 바꿨으면 백업 파일 URL 을 돌려준다.
    @discardableResult
    public func install(helperSource: URL, includeMessageDisplay: Bool) throws -> URL? {
        // 설정을 먼저 검증한다 (잘못된 JSON 이면 아무것도 바꾸지 않음)
        let existing = try readSettings()
        var root = try Self.rootObject(existing?.value ?? .object([:]))
        var hooks = try Self.hooksObject(in: root)

        try installHelper(from: helperSource)

        for event in managedEvents {
            if event == "MessageDisplay" && !includeMessageDisplay {
                hooks = removingManagedHooks(from: hooks, events: [event])
                continue
            }
            let groups = try Self.groups(for: event, in: hooks)
            hooks[event] = .array(upserting(event: event, into: groups))
        }
        root["hooks"] = .object(hooks)

        let backup = try save(.object(root), replacing: existing)
        log.info("훅 설치 완료")
        return backup
    }

    /// AgentNotch 훅만 제거한다. 설정 파일을 바꿨으면 백업 파일 URL 을 돌려준다.
    @discardableResult
    public func uninstall() throws -> URL? {
        guard let existing = try readSettings() else { return nil }
        var root = try Self.rootObject(existing.value)
        guard root["hooks"] != nil else { return nil }
        let hooks = try Self.hooksObject(in: root)

        let remaining = removingManagedHooks(from: hooks, events: Array(hooks.keys))
        if remaining.isEmpty && !hooks.isEmpty {
            root["hooks"] = nil  // 우리 항목만 있던 hooks 는 통째로 지운다
        } else {
            root["hooks"] = .object(remaining)
        }

        let backup = try save(.object(root), replacing: existing)
        log.info("훅 제거 완료")
        return backup
    }

    /// 앱 업데이트 후 첫 실행 때 호출: 훅을 쓰는 중이고 헬퍼 내용이 달라졌으면 다시 복사한다.
    /// 설치한 적이 없으면 아무것도 하지 않는다. 복사했으면 true.
    @discardableResult
    public func refreshHelperIfInstalled(helperSource: URL) throws -> Bool {
        let helperExists = fileManager.fileExists(atPath: helperInstallURL.path)
        guard helperExists || !installedEvents().isEmpty else { return false }
        return try installHelper(from: helperSource)
    }

    /// 설치된 AgentNotch 항목 중 지금 형태(명령 · timeout)와 다른 것이 있는지
    /// (예: 질문 · 계획 승인 응답 대기 전에 설치한 PreToolUse — timeout 10, `--reply-timeout` 없음)
    public func hasOutdatedHooks() -> Bool {
        guard let root = try? readSettings()?.value, let hooks = root["hooks"]?.objectValue else { return false }
        for event in managedEvents {
            guard let groups = hooks[event]?.arrayValue else { continue }
            let desired = hookEntry(for: event)
            for group in groups {
                for entry in group["hooks"]?.arrayValue ?? [] where isManaged(entry) && entry != desired {
                    return true
                }
            }
        }
        return false
    }

    /// 이미 설치된 AgentNotch 항목만 지금 형태로 고친다 (앱 업데이트 후 실행 때 `refreshHelperIfInstalled` 다음에 부른다).
    /// - 우리 항목이 없거나(설치한 적 없음) 이미 지금 형태면 아무것도 하지 않는다 (nil).
    /// - 우리 항목이 있는 이벤트만 그 자리에서 고친다. 빠진 이벤트를 새로 넣거나 다른 훅(예: iTerm2 `cc-status`) · 설정은 건드리지 않는다.
    /// - 바꾸기 전에 타임스탬프 백업(0600)을 남기고 그 URL 을 돌려준다. settings.json 이 잘못된 JSON 이면 throw (파일은 그대로).
    @discardableResult
    public func updateInstalledHooks() throws -> URL? {
        guard hasOutdatedHooks(), let existing = try readSettings() else { return nil }
        var root = try Self.rootObject(existing.value)
        var hooks = try Self.hooksObject(in: root)
        for event in managedEvents {
            guard let value = hooks[event], containsManagedHook(value) else { continue }
            let groups = try Self.groups(for: event, in: hooks)
            hooks[event] = .array(upserting(event: event, into: groups))
        }
        root["hooks"] = .object(hooks)

        let backup = try save(.object(root), replacing: existing)
        log.info("예전 훅 항목을 지금 형태로 고침")
        return backup
    }

    /// 복사해 둔 헬퍼 실행 파일 삭제
    public func removeHelper() throws {
        guard fileManager.fileExists(atPath: helperInstallURL.path) else { return }
        try fileManager.removeItem(at: helperInstallURL)
    }

    // MARK: - 훅 항목 만들기

    /// 셸 형식 명령. 경로에 공백이 있어 작은따옴표로 감싼다.
    /// 응답을 기다리는 이벤트는 `--reply-timeout` 을 붙인다 (헬퍼는 이 옵션이 있을 때만 PreToolUse 에서 기다린다).
    /// Codex 는 이벤트 이름 앞에 `--agent codex` (Claude Code 명령은 예전 모양 그대로)
    public func command(for event: String) -> String {
        var command = Upgrader.shellQuoted(helperInstallURL.path)
        if agent != .claude {
            command += " \(AgentKind.commandLineFlag) \(agent.rawValue)"
        }
        command += " \(event)"
        if Self.replyEvents(for: agent).contains(event) {
            command += " \(NotchWire.replyTimeoutFlag) \(NotchWire.helperReplyTimeout)"
        }
        return command
    }

    func timeout(for event: String) -> Int {
        if Self.replyEvents(for: agent).contains(event) { return NotchWire.hookTimeout }
        switch event {
        case "MessageDisplay": return 5
        // Codex 의 SessionEnd · Interrupt 는 최대 3초
        case "SessionEnd", "Interrupt": return 2
        default: return 10
        }
    }

    private func hookEntry(for event: String) -> JSONValue {
        var entry: [String: JSONValue] = [
            "type": .string("command"),
            "command": .string(command(for: event)),
            "timeout": .number(Double(timeout(for: event))),
        ]
        if agent == .codex, event == "PermissionRequest" {
            entry["statusMessage"] = .string(Self.codexPermissionStatusMessage)
        }
        return .object(entry)
    }

    private func matcherGroup(for event: String) -> JSONValue {
        var group: [String: JSONValue] = ["hooks": .array([hookEntry(for: event)])]
        if Self.toolEvents.contains(event) {
            group["matcher"] = .string("*")
        }
        return .object(group)
    }

    private func isManaged(_ entry: JSONValue) -> Bool {
        guard let command = entry["command"]?.stringValue else { return false }
        return command.contains(Self.marker) || command.contains(helperInstallURL.path)
    }

    private func containsManagedHook(_ groups: JSONValue) -> Bool {
        guard let groups = groups.arrayValue else { return false }
        return groups.contains { group in
            group["hooks"]?.arrayValue?.contains(where: isManaged) ?? false
        }
    }

    /// 이미 우리 항목이 있으면 그 자리에서 최신 형태로 고치고(중복은 제거), 없을 때만 그룹을 덧붙인다.
    private func upserting(event: String, into groups: [JSONValue]) -> [JSONValue] {
        let desired = hookEntry(for: event)
        var found = false
        var result: [JSONValue] = []

        for group in groups {
            guard case .object(var object) = group, let entries = object["hooks"]?.arrayValue else {
                result.append(group)
                continue
            }
            var kept: [JSONValue] = []
            var touched = false
            for entry in entries {
                guard isManaged(entry) else {
                    kept.append(entry)
                    continue
                }
                if found {
                    touched = true  // 중복 항목 제거
                } else {
                    found = true
                    if entry != desired { touched = true }
                    kept.append(desired)
                }
            }
            if !touched {
                result.append(group)
            } else if !kept.isEmpty {
                object["hooks"] = .array(kept)
                result.append(.object(object))
            }
            // 우리 항목만 있다가 비게 된 그룹은 지운다
        }

        if !found {
            result.append(matcherGroup(for: event))
        }
        return result
    }

    /// 지정한 이벤트에서 우리 항목만 지운다. 우리 때문에 빈 그룹/배열만 정리한다.
    private func removingManagedHooks(from hooks: [String: JSONValue], events: [String]) -> [String: JSONValue] {
        var hooks = hooks
        for event in events {
            guard let value = hooks[event], let groups = value.arrayValue else { continue }
            var result: [JSONValue] = []
            var removedAny = false
            for group in groups {
                guard case .object(var object) = group, let entries = object["hooks"]?.arrayValue else {
                    result.append(group)
                    continue
                }
                let kept = entries.filter { !isManaged($0) }
                if kept.count == entries.count {
                    result.append(group)
                    continue
                }
                removedAny = true
                if !kept.isEmpty {
                    object["hooks"] = .array(kept)
                    result.append(.object(object))
                }
            }
            guard removedAny else { continue }
            hooks[event] = result.isEmpty ? nil : .array(result)
        }
        return hooks
    }

    // MARK: - settings.json 읽기 / 쓰기

    private struct SettingsFile {
        var data: Data
        var value: JSONValue
        var permissions: mode_t
    }

    /// 파일이 없으면 nil. JSON 이 잘못됐으면 throw.
    private func readSettings() throws -> SettingsFile? {
        let path = settingsURL.path
        guard fileManager.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: settingsURL)

        var info = stat()
        let permissions: mode_t = stat(path, &info) == 0 ? info.st_mode & 0o7777 : 0o600

        // 빈 파일은 빈 객체로 본다
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) {
            return SettingsFile(data: data, value: .object([:]), permissions: permissions)
        }
        do {
            return SettingsFile(data: data, value: try JSONValue.parse(data, repairingLoneSurrogates: false), permissions: permissions)
        } catch {
            throw HookInstallerError.invalidSettings("JSON 해석 실패")
        }
    }

    private static func rootObject(_ value: JSONValue) throws -> [String: JSONValue] {
        guard let object = value.objectValue else {
            throw HookInstallerError.invalidSettings("최상위가 객체가 아님")
        }
        return object
    }

    private static func hooksObject(in root: [String: JSONValue]) throws -> [String: JSONValue] {
        guard let hooks = root["hooks"] else { return [:] }
        guard let object = hooks.objectValue else {
            throw HookInstallerError.invalidSettings("hooks 가 객체가 아님")
        }
        return object
    }

    private static func groups(for event: String, in hooks: [String: JSONValue]) throws -> [JSONValue] {
        guard let value = hooks[event] else { return [] }
        guard let groups = value.arrayValue else {
            throw HookInstallerError.invalidSettings("hooks.\(event) 가 배열이 아님")
        }
        return groups
    }

    /// 바뀐 게 있을 때만 백업 후 저장한다. 백업 URL 을 돌려준다.
    private func save(_ root: JSONValue, replacing existing: SettingsFile?) throws -> URL? {
        if let existing, existing.value == root { return nil }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(root)
        data.append(0x0A)

        // 심볼릭 링크(dotfiles 관리 등)는 링크를 유지하고 실제 파일을 바꾼다
        let target = settingsURL.resolvingSymlinksInPath()
        var backup: URL?
        if let existing {
            backup = try writeBackup(existing.data)
            try AtomicFile.write(data, to: target, permissions: existing.permissions)
        } else {
            try createDirectoryIfNeeded(target.deletingLastPathComponent())
            try AtomicFile.write(data, to: target, permissions: 0o600)
        }
        return backup
    }

    private func writeBackup(_ data: Data) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(settingsURL.lastPathComponent).agentnotch-backup-\(formatter.string(from: now()))"
        let directory = settingsURL.deletingLastPathComponent()

        // 같은 초에 여러 번 저장해도 기존 백업을 덮어쓰지 않는다
        for attempt in 0..<100 {
            let name = attempt == 0 ? base : "\(base)-\(attempt)"
            let url = directory.appendingPathComponent(name)
            if try AtomicFile.createExclusive(data, at: url, permissions: 0o600) {
                return url
            }
        }
        throw HookInstallerError.writeFailed(path: directory.path, code: EEXIST)
    }

    private func createDirectoryIfNeeded(_ directory: URL) throws {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    // MARK: - 헬퍼 복사

    /// 헬퍼를 고정 경로로 복사한다. 실제로 파일을 바꿨으면 true.
    ///
    /// 앱을 띄울 때마다 불리므로 두 파일을 통째로 비교하는 일을 줄인다: 복사본의 수정 시각을 원본에 맞춰 두고,
    /// 크기 · 수정 시각이 같으면 그대로 둔다. 크기가 다르면 비교 없이 복사하고, 크기만 같으면 내용을 비교한다.
    @discardableResult
    private func installHelper(from source: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: source.path) else { throw HookInstallerError.helperSourceMissing }
        let destination = helperInstallURL
        if source.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath() {
            try setPermissions(0o755, at: destination)
            return false
        }

        let sourceInfo = FileStamp(path: source.path)
        let currentInfo = FileStamp(path: destination.path)
        if let sourceInfo, sourceInfo == currentInfo {
            try setPermissions(0o755, at: destination)
            return false
        }
        let data = try Data(contentsOf: source)
        try createDirectoryIfNeeded(destination.deletingLastPathComponent())
        // 크기가 같을 때만 내용을 비교한다. 같으면 그대로 두고 수정 시각만 맞춘다 (다음부터는 비교하지 않게)
        if currentInfo?.size == off_t(data.count), let current = try? Data(contentsOf: destination), current == data {
            try setPermissions(0o755, at: destination)
            sourceInfo?.applyModificationTime(to: destination.path)
            return false
        }
        // rename 으로 교체하므로 실행 중인 훅 프로세스가 있어도 안전하다
        try AtomicFile.write(data, to: destination, permissions: 0o755)
        sourceInfo?.applyModificationTime(to: destination.path)
        log.info("훅 헬퍼 복사 완료")
        return true
    }

    private func setPermissions(_ permissions: mode_t, at url: URL) throws {
        guard chmod(url.path, permissions) == 0 else {
            throw HookInstallerError.writeFailed(path: url.path, code: errno)
        }
    }
}

// MARK: - 파일 크기 · 수정 시각

/// 내용을 읽지 않고 같은 파일인지 가늠하는 크기 · 수정 시각 (나노초까지)
struct FileStamp: Equatable {
    var size: off_t
    var modifiedSeconds: Int
    var modifiedNanoseconds: Int

    /// 일반 파일이 아니거나 없으면 nil
    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }

    /// 다른 파일의 수정 시각을 이 값으로 맞춘다 (실패해도 다음에 내용을 비교할 뿐이라 무시)
    func applyModificationTime(to path: String) {
        var times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            timespec(tv_sec: modifiedSeconds, tv_nsec: modifiedNanoseconds),
        ]
        _ = utimensat(AT_FDCWD, path, &times, 0)
    }
}

// MARK: - 원자적 파일 쓰기

enum AtomicFile {
    /// 같은 디렉터리의 임시 파일에 쓰고 rename 으로 교체한다. 권한은 처음부터 지정값으로 만든다.
    static func write(_ data: Data, to url: URL, permissions: mode_t) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).agentnotch-\(UUID().uuidString)")
        try writeNew(data, at: temporary, permissions: permissions)
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw HookInstallerError.writeFailed(path: url.path, code: code)
        }
    }

    /// 파일이 없을 때만 만든다. 이미 있으면 false.
    static func createExclusive(_ data: Data, at url: URL, permissions: mode_t) throws -> Bool {
        do {
            try writeNew(data, at: url, permissions: permissions)
            return true
        } catch HookInstallerError.writeFailed(_, let code) where code == EEXIST {
            return false
        }
    }

    private static func writeNew(_ data: Data, at url: URL, permissions: mode_t) throws {
        let path = url.path
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
        guard fd >= 0 else { throw HookInstallerError.writeFailed(path: path, code: errno) }

        var failure: Int32 = 0
        // umask 영향을 받지 않도록 권한을 다시 지정
        if fchmod(fd, permissions) != 0 { failure = errno }
        if failure == 0 {
            failure = data.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return 0 }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, base + offset, raw.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EINTR {
                        continue
                    } else {
                        return written < 0 ? errno : EIO
                    }
                }
                return 0
            }
        }
        if failure == 0, fsync(fd) != 0 { failure = errno }
        if close(fd) != 0, failure == 0 { failure = errno }
        if failure != 0 {
            unlink(path)
            throw HookInstallerError.writeFailed(path: path, code: failure)
        }
    }
}
