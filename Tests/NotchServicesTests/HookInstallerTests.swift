import Foundation
import NotchShared
import Testing
@testable import NotchServices

/// 임시 폴더 안에 가짜 홈/설정/헬퍼를 꾸린다 (실제 ~/.claude 는 절대 건드리지 않음)
private struct InstallerFixture {
    let temp: TempDirectory
    let settingsURL: URL
    let helperSource: URL
    let helperInstallURL: URL
    let date = Date(timeIntervalSince1970: 1_760_000_000)

    init(supportFolder: String = "Application Support") throws {
        temp = try TempDirectory()
        settingsURL = temp.url.appendingPathComponent("home/.claude/settings.json")
        helperSource = temp.url.appendingPathComponent("build/notch-hook")
        helperInstallURL = temp.url
            .appendingPathComponent(supportFolder, isDirectory: true)
            .appendingPathComponent("AgentNotch/bin/notch-hook")

        // 받은 인자를 한 줄씩 출력하는 가짜 헬퍼
        try FileManager.default.createDirectory(at: helperSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: helperSource)
    }

    func makeInstaller() -> HookInstaller {
        let date = date
        return HookInstaller(settingsURL: settingsURL, helperInstallURL: helperInstallURL, now: { date })
    }

    /// 같은 가짜 홈의 Codex 훅 파일 (`home/.codex/hooks.json`) 설치기. 헬퍼는 Claude Code 와 같은 것을 쓴다
    var codexHooksURL: URL { temp.url.appendingPathComponent("home/.codex/hooks.json") }

    func makeCodexInstaller() -> HookInstaller {
        let date = date
        return HookInstaller(agent: .codex, settingsURL: codexHooksURL, helperInstallURL: helperInstallURL, now: { date })
    }

    func codexHooks() throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: codexHooksURL))
    }

    func writeSettings(_ text: String, permissions: Int = 0o644) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: settingsURL)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: settingsURL.path)
    }

    func settingsData() throws -> Data {
        try Data(contentsOf: settingsURL)
    }

    func settings() throws -> JSONValue {
        try JSONValue.parse(settingsData())
    }

    func backups() -> [String] {
        let directory = settingsURL.deletingLastPathComponent().path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.contains("agentnotch-backup") }.sorted()
    }
}

/// iTerm2 cc-status 같은 다른 훅과 기타 설정이 들어 있는 기존 settings.json
private let existingSettings = """
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "cleanupPeriodDays": 30,
  "env": { "EXAMPLE_FLAG": "1" },
  "permissions": { "allow": ["Bash(npm test:*)", "Read(/Users/dev/projects/**)"], "deny": [] },
  "statusLine": { "type": "command", "command": "~/.claude/statusline.sh", "padding": 0 },
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "\\"/Applications/iTerm.app/Contents/Resources/utilities/cc-status\\" SessionStart", "async": true } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "\\"/Applications/iTerm.app/Contents/Resources/utilities/cc-status\\" UserPromptSubmit", "async": true } ] }
    ],
    "PreToolUse": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "\\"/Applications/iTerm.app/Contents/Resources/utilities/cc-status\\" PreToolUse", "async": true } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/Users/dev/bin/guard.sh", "timeout": 15 } ] }
    ],
    "PermissionRequest": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "\\"/Applications/iTerm.app/Contents/Resources/utilities/cc-status\\" PermissionRequest", "async": true } ] }
    ],
    "Notification": [
      { "matcher": "idle_prompt", "hooks": [ { "type": "command", "command": "\\"/Applications/iTerm.app/Contents/Resources/utilities/cc-status\\" Notification", "async": true } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "\\"/Applications/iTerm.app/Contents/Resources/utilities/cc-status\\" Stop", "async": true } ] }
    ],
    "PermissionDenied": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "\\"/Applications/iTerm.app/Contents/Resources/utilities/cc-status\\" PermissionDenied", "async": true } ] }
    ]
  }
}
"""

private func managedEntries(in settings: JSONValue, event: String) -> [JSONValue] {
    let groups = settings["hooks"]?[event]?.arrayValue ?? []
    return groups.flatMap { $0["hooks"]?.arrayValue ?? [] }.filter {
        $0["command"]?.stringValue?.contains(HookInstaller.marker) ?? false
    }
}

@Suite("HookInstaller")
struct HookInstallerTests {
    @Test func freshInstallCreatesSettingsAndHelper() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        let installer = fixture.makeInstaller()
        #expect(installer.status() == .notInstalled)

        let backup = try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: false)
        #expect(backup == nil)  // 기존 파일이 없었으므로 백업 없음
        #expect(posixPermissions(fixture.settingsURL.path) == 0o600)

        // 헬퍼 복사 (0755, 같은 내용)
        #expect(posixPermissions(fixture.helperInstallURL.path) == 0o755)
        #expect(try Data(contentsOf: fixture.helperInstallURL) == Data(contentsOf: fixture.helperSource))

        let settings = try fixture.settings()
        let hooks = try #require(settings["hooks"]?.objectValue)
        let expectedEvents = Set(HookInstaller.managedEvents).subtracting(["MessageDisplay"])
        #expect(Set(hooks.keys) == expectedEvents)

        for event in expectedEvents {
            let groups = try #require(hooks[event]?.arrayValue)
            #expect(groups.count == 1)
            let group = try #require(groups.first)
            if HookInstaller.toolEvents.contains(event) {
                #expect(group["matcher"] == .string("*"))
            } else {
                #expect(group["matcher"] == nil)
            }
            let entry = try #require(group["hooks"]?[0])
            #expect(entry["type"] == .string("command"))
            #expect(entry["async"] == nil)
            #expect(entry["command"]?.stringValue == installer.command(for: event))
            #expect(entry["timeout"]?.intValue == installer.timeout(for: event))
        }

        let permission = try #require(managedEntries(in: settings, event: "PermissionRequest").first)
        #expect(permission["timeout"] == .number(600))
        #expect(permission["command"]?.stringValue?.hasSuffix("' PermissionRequest --reply-timeout 590") == true)
        // 질문 · 계획 승인을 노치에서 답하도록 PreToolUse 도 응답을 기다린다 (그 두 툴만 — 헬퍼가 판단)
        let preToolUse = try #require(managedEntries(in: settings, event: "PreToolUse").first)
        #expect(preToolUse["timeout"] == .number(600))
        #expect(preToolUse["command"]?.stringValue?.hasSuffix("' PreToolUse --reply-timeout 590") == true)
        #expect(managedEntries(in: settings, event: "PostToolUse").first?["timeout"] == .number(10))
        #expect(managedEntries(in: settings, event: "PostToolUse").first?["command"]?.stringValue?.contains("--reply-timeout") == false)
        #expect(managedEntries(in: settings, event: "SessionEnd").first?["timeout"] == .number(2))
        #expect(managedEntries(in: settings, event: "Stop").first?["timeout"] == .number(10))

        // 정수는 ".0" 없이, 슬래시는 이스케이프 없이 저장
        let text = try #require(String(data: fixture.settingsData(), encoding: .utf8))
        #expect(text.contains("\"timeout\" : 600"))
        #expect(!text.contains(".0,") && !text.contains(".0\n"))
        #expect(!text.contains("\\/"))

        #expect(installer.status() == .installed)
    }

    @Test func existingSettingsAndOtherHooksArePreserved() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        try fixture.writeSettings(existingSettings)
        let original = try fixture.settings()

        try fixture.makeInstaller().install(helperSource: fixture.helperSource, includeMessageDisplay: false)
        let updated = try fixture.settings()

        // hooks 외의 키는 그대로
        let originalObject = try #require(original.objectValue)
        let updatedObject = try #require(updated.objectValue)
        #expect(Set(originalObject.keys) == Set(updatedObject.keys))
        for (key, value) in originalObject where key != "hooks" {
            #expect(updatedObject[key] == value, "\(key) 변경됨")
        }

        // 기존 그룹은 순서·내용 그대로, 우리 그룹은 뒤에 하나만 추가
        let originalHooks = try #require(original["hooks"]?.objectValue)
        for (event, value) in originalHooks {
            let before = try #require(value.arrayValue)
            let after = try #require(updated["hooks"]?[event]?.arrayValue)
            if HookInstaller.managedEvents.contains(event) {
                #expect(Array(after.prefix(before.count)) == before, "\(event) 기존 그룹 변경됨")
                #expect(after.count == before.count + 1)
                #expect(managedEntries(in: updated, event: event).count == 1)
            } else {
                #expect(after == before, "\(event) 관리 대상이 아닌데 바뀜")
            }
        }

        let text = try #require(String(data: fixture.settingsData(), encoding: .utf8))
        #expect(text.contains("\"cleanupPeriodDays\" : 30"))
        #expect(text.contains("\"padding\" : 0"))
    }

    @Test func installIsIdempotent() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        try fixture.writeSettings(existingSettings)
        let installer = fixture.makeInstaller()

        let firstBackup = try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: true)
        #expect(firstBackup != nil)
        let afterFirst = try fixture.settingsData()

        let secondBackup = try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: true)
        #expect(secondBackup == nil)  // 바뀐 게 없으면 쓰지도, 백업하지도 않는다
        #expect(try fixture.settingsData() == afterFirst)
        #expect(fixture.backups().count == 1)

        let settings = try fixture.settings()
        for event in HookInstaller.managedEvents {
            #expect(managedEntries(in: settings, event: event).count == 1, "\(event) 중복 설치")
        }
    }

    @Test func outdatedEntryIsUpdatedInPlace() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        try fixture.writeSettings("""
        {"hooks": {"Stop": [
          {"hooks": [{"type": "command", "command": "'/old/place/AgentNotch/bin/notch-hook' Stop", "timeout": 30, "async": true}]},
          {"hooks": [{"type": "command", "command": "'/old/place/AgentNotch/bin/notch-hook' Stop"}]}
        ]}}
        """)
        let installer = fixture.makeInstaller()
        try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: false)

        let groups = try #require(try fixture.settings()["hooks"]?["Stop"]?.arrayValue)
        #expect(groups.count == 1)  // 중복 그룹은 정리
        let entry = try #require(groups.first?["hooks"]?[0])
        #expect(entry["command"]?.stringValue == installer.command(for: "Stop"))
        #expect(entry["timeout"] == .number(10))
        #expect(entry["async"] == nil)
    }

    // MARK: - 예전 설정 고치기 (앱 업데이트 후 실행)

    /// 질문 · 계획 승인 응답 대기 전 버전이 설치한 설정: PreToolUse 가 timeout 10 · `--reply-timeout` 없음.
    /// 우리 PreToolUse 항목은 다른 훅과 같은 그룹에 있고, SubagentStart 등 일부 이벤트는 빠져 있다
    private func oldInstalledSettings(helper: String) -> String {
        let command = { (event: String) in "'\(helper)' \(event)" }
        return """
        {
          "env": { "EXAMPLE_FLAG": "1" },
          "permissions": { "allow": ["Bash(npm test:*)"], "deny": [] },
          "hooks": {
            "SessionStart": [
              { "hooks": [ { "type": "command", "command": "\\"/Applications/iTerm.app/Contents/Resources/utilities/cc-status\\" SessionStart", "async": true } ] },
              { "hooks": [ { "type": "command", "command": "\(command("SessionStart"))", "timeout": 10 } ] }
            ],
            "PreToolUse": [
              { "matcher": "*", "hooks": [
                { "type": "command", "command": "\\"/Applications/iTerm.app/Contents/Resources/utilities/cc-status\\" PreToolUse", "async": true },
                { "type": "command", "command": "\(command("PreToolUse"))", "timeout": 10 }
              ] },
              { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/Users/dev/bin/guard.sh", "timeout": 15 } ] }
            ],
            "PermissionRequest": [
              { "matcher": "*", "hooks": [ { "type": "command", "command": "\(command("PermissionRequest")) --reply-timeout 590", "timeout": 600 } ] }
            ],
            "Stop": [
              { "hooks": [ { "type": "command", "command": "\(command("Stop"))", "timeout": 10 } ] }
            ]
          }
        }
        """
    }

    @Test func outdatedHooksAreUpdatedOnlyInPlace() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        let installer = fixture.makeInstaller()
        try fixture.writeSettings(oldInstalledSettings(helper: fixture.helperInstallURL.path), permissions: 0o644)
        let originalData = try fixture.settingsData()
        let original = try fixture.settings()
        #expect(installer.hasOutdatedHooks())

        let backup = try #require(try installer.updateInstalledHooks())
        #expect(posixPermissions(backup.path) == 0o600)
        #expect(try Data(contentsOf: backup) == originalData)
        #expect(posixPermissions(fixture.settingsURL.path) == 0o644)

        let updated = try fixture.settings()
        // hooks 밖의 설정은 그대로
        for (key, value) in try #require(original.objectValue) where key != "hooks" {
            #expect(updated[key] == value, "\(key) 변경됨")
        }
        // 같은 그룹의 다른 훅 · 다른 그룹은 그대로, 우리 항목만 그 자리에서 지금 형태로
        let groups = try #require(updated["hooks"]?["PreToolUse"]?.arrayValue)
        let before = try #require(original["hooks"]?["PreToolUse"]?.arrayValue)
        #expect(groups.count == 2)
        #expect(groups[1] == before[1])
        #expect(groups[0]["matcher"] == .string("*"))
        #expect(groups[0]["hooks"]?[0] == before[0]["hooks"]?[0])
        let ours = try #require(groups[0]["hooks"]?[1])
        #expect(ours["command"]?.stringValue == installer.command(for: "PreToolUse"))
        #expect(ours["command"]?.stringValue?.hasSuffix(" PreToolUse --reply-timeout 590") == true)
        #expect(ours["timeout"] == .number(600))
        #expect(managedEntries(in: updated, event: "PreToolUse").count == 1)
        // 이미 지금 형태인 이벤트 · 다른 훅이 있는 이벤트도 그대로
        #expect(updated["hooks"]?["PermissionRequest"] == original["hooks"]?["PermissionRequest"])
        #expect(updated["hooks"]?["SessionStart"] == original["hooks"]?["SessionStart"])
        #expect(updated["hooks"]?["Stop"] == original["hooks"]?["Stop"])
        // 빠진 이벤트를 새로 넣지 않는다 (설치 · 제거는 사용자가 고른다)
        #expect(Set(try #require(updated["hooks"]?.objectValue).keys) == ["SessionStart", "PreToolUse", "PermissionRequest", "Stop"])

        // 한 번 고친 뒤엔 바뀌는 게 없다 (백업도 더 안 남김)
        #expect(!installer.hasOutdatedHooks())
        #expect(try installer.updateInstalledHooks() == nil)
        #expect(fixture.backups().count == 1)
    }

    @Test func updateDoesNothingWithoutOurHooksOrWhenCurrent() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        let installer = fixture.makeInstaller()

        // 설정 파일이 없음
        #expect(try installer.updateInstalledHooks() == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.settingsURL.path))

        // 다른 훅만 있음 (설치한 적 없음)
        try fixture.writeSettings(existingSettings)
        let foreign = try fixture.settingsData()
        #expect(!installer.hasOutdatedHooks())
        #expect(try installer.updateInstalledHooks() == nil)
        #expect(try fixture.settingsData() == foreign)

        // 지금 버전으로 설치한 설정
        try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: false)
        let installed = try fixture.settingsData()
        let backups = fixture.backups().count
        #expect(!installer.hasOutdatedHooks())
        #expect(try installer.updateInstalledHooks() == nil)
        #expect(try fixture.settingsData() == installed)
        #expect(fixture.backups().count == backups)

        // 잘못된 JSON 은 건드리지 않는다
        let broken = "{ \"hooks\": { \"PreToolUse\": [ "
        try fixture.writeSettings(broken)
        #expect(try installer.updateInstalledHooks() == nil)
        #expect(try fixture.settingsData() == Data(broken.utf8))
    }

    @Test func uninstallRemovesOnlyOurEntries() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        try fixture.writeSettings(existingSettings)
        let original = try fixture.settings()
        let installer = fixture.makeInstaller()

        try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: true)
        let backup = try installer.uninstall()
        #expect(backup != nil)

        // 우리가 만든 그룹/배열만 사라지고 나머지는 원래와 같다
        #expect(try fixture.settings() == original)
        #expect(installer.status() == .notInstalled)
        // 헬퍼 삭제는 별도
        #expect(FileManager.default.fileExists(atPath: fixture.helperInstallURL.path))
        try installer.removeHelper()
        #expect(!FileManager.default.fileExists(atPath: fixture.helperInstallURL.path))

        // 다시 제거해도 바뀌는 게 없다
        #expect(try installer.uninstall() == nil)
    }

    @Test func uninstallAfterFreshInstallLeavesEmptyObject() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        let installer = fixture.makeInstaller()
        try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: true)
        try installer.uninstall()
        #expect(try fixture.settings() == .object([:]))
    }

    @Test func uninstallKeepsGroupSharedWithOtherHook() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        let installer = fixture.makeInstaller()
        try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: false)

        // 사용자가 우리 그룹 안에 다른 훅을 추가한 경우
        var settings = try #require(try fixture.settings().objectValue)
        var hooks = try #require(settings["hooks"]?.objectValue)
        var group = try #require(hooks["Stop"]?[0]?.objectValue)
        var entries = try #require(group["hooks"]?.arrayValue)
        let userHook: JSONValue = .object(["type": .string("command"), "command": .string("/Users/dev/bin/notify.sh")])
        entries.append(userHook)
        group["hooks"] = .array(entries)
        hooks["Stop"] = .array([.object(group)])
        settings["hooks"] = .object(hooks)
        try Data(JSONValue.object(settings).serialized()).write(to: fixture.settingsURL)

        try installer.uninstall()
        let after = try fixture.settings()
        #expect(after["hooks"]?.objectValue?.keys.sorted() == ["Stop"])
        #expect(after["hooks"]?["Stop"]?[0]?["hooks"] == .array([userHook]))
    }

    @Test func invalidJSONIsNotModified() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        let broken = "{ \"hooks\": { \"Stop\": [ "
        try fixture.writeSettings(broken)
        let installer = fixture.makeInstaller()

        #expect(throws: HookInstallerError.self) {
            try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: false)
        }
        #expect(throws: HookInstallerError.self) {
            try installer.uninstall()
        }
        #expect(try fixture.settingsData() == Data(broken.utf8))
        #expect(fixture.backups().isEmpty)
        // 설정이 잘못됐으면 헬퍼도 복사하지 않는다
        #expect(!FileManager.default.fileExists(atPath: fixture.helperInstallURL.path))
    }

    @Test func unexpectedShapesAreRejected() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        let installer = fixture.makeInstaller()

        for text in ["[1, 2]", "{\"hooks\": []}", "{\"hooks\": {\"Stop\": {}}}"] {
            try fixture.writeSettings(text)
            #expect(throws: HookInstallerError.self) {
                try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: false)
            }
            #expect(try fixture.settingsData() == Data(text.utf8))
        }
    }

    @Test func backupIsWrittenWithOwnerOnlyPermissions() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        try fixture.writeSettings(existingSettings, permissions: 0o644)
        let originalData = try fixture.settingsData()
        let installer = fixture.makeInstaller()

        let backup = try #require(try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: false))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        #expect(backup.lastPathComponent == "settings.json.agentnotch-backup-\(formatter.string(from: fixture.date))")
        #expect(backup.deletingLastPathComponent().path == fixture.settingsURL.deletingLastPathComponent().path)
        #expect(posixPermissions(backup.path) == 0o600)
        #expect(try Data(contentsOf: backup) == originalData)
        // 원래 파일 권한 유지
        #expect(posixPermissions(fixture.settingsURL.path) == 0o644)

        // 같은 초에 다시 저장해도 기존 백업을 덮어쓰지 않는다
        let second = try #require(try installer.uninstall())
        #expect(second != backup)
        #expect(second.lastPathComponent.hasPrefix(backup.lastPathComponent))
        #expect(try Data(contentsOf: backup) == originalData)
        #expect(fixture.backups().count == 2)
    }

    @Test func messageDisplayToggle() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        try fixture.writeSettings("""
        {"hooks": {"MessageDisplay": [{"hooks": [{"type": "command", "command": "/Users/dev/bin/cc-status MessageDisplay", "async": true}]}]}}
        """)
        let installer = fixture.makeInstaller()

        try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: true)
        var settings = try fixture.settings()
        let entry = try #require(managedEntries(in: settings, event: "MessageDisplay").first)
        #expect(entry["timeout"] == .number(5))
        #expect(settings["hooks"]?["MessageDisplay"]?.arrayValue?.count == 2)
        #expect(settings["hooks"]?["MessageDisplay"]?[1]?["matcher"] == nil)
        #expect(installer.installedEvents().contains("MessageDisplay"))
        #expect(installer.status() == .installed)

        try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: false)
        settings = try fixture.settings()
        #expect(managedEntries(in: settings, event: "MessageDisplay").isEmpty)
        // 다른 MessageDisplay 훅은 남는다
        #expect(settings["hooks"]?["MessageDisplay"]?.arrayValue?.count == 1)
        #expect(!installer.installedEvents().contains("MessageDisplay"))
        #expect(installer.status() == .installed)
        #expect(managedEntries(in: settings, event: "Stop").count == 1)
    }

    @Test func messageDisplayKeyIsRemovedWhenOnlyOurs() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        let installer = fixture.makeInstaller()
        try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: true)
        try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: false)
        #expect(try fixture.settings()["hooks"]?["MessageDisplay"] == nil)
    }

    @Test func commandQuotingSurvivesTheShell() throws {
        // 공백과 작은따옴표가 들어간 경로
        let fixture = try InstallerFixture(supportFolder: "it's Application Support")
        defer { fixture.temp.remove() }
        let installer = fixture.makeInstaller()
        try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: false)

        let path = fixture.helperInstallURL.path
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        #expect(installer.command(for: "SessionStart") == "'\(escaped)' SessionStart")

        // settings.json 에 저장된 명령을 실제 셸로 실행해 인자가 그대로 전달되는지 확인
        let settings = try fixture.settings()
        for (event, expected) in [
            ("SessionStart", ["SessionStart"]),
            ("PermissionRequest", ["PermissionRequest", "--reply-timeout", "590"]),
        ] {
            let command = try #require(managedEntries(in: settings, event: event).first?["command"]?.stringValue)
            #expect(try runShell(command) == expected)
        }
    }

    @Test func statusReportsPartialAndMissingHelper() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        let installer = fixture.makeInstaller()
        #expect(installer.status() == .notInstalled)
        #expect(installer.status().description == "설치 안 됨")

        try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: false)
        #expect(installer.status().description == "설치됨")

        // PreToolUse 를 손으로 지운 경우
        var settings = try #require(try fixture.settings().objectValue)
        var hooks = try #require(settings["hooks"]?.objectValue)
        hooks["PreToolUse"] = nil
        settings["hooks"] = .object(hooks)
        try Data(JSONValue.object(settings).serialized()).write(to: fixture.settingsURL)
        #expect(installer.status() == .partial(missing: ["PreToolUse"]))
        #expect(installer.status().description == "일부만 설치됨")

        try installer.removeHelper()
        #expect(installer.status() == .helperMissing)
        #expect(installer.status().description == "헬퍼 없음")
    }

    @Test func symlinkedSettingsStaysASymlink() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        // dotfiles 저장소의 실제 파일을 가리키는 링크
        let real = fixture.temp.url.appendingPathComponent("dotfiles/claude-settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"model\": \"opus\"}".utf8).write(to: real)
        try FileManager.default.createDirectory(at: fixture.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.settingsURL, withDestinationURL: real)

        let backup = try fixture.makeInstaller().install(helperSource: fixture.helperSource, includeMessageDisplay: false)
        let type = try FileManager.default.attributesOfItem(atPath: fixture.settingsURL.path)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
        let realSettings = try JSONValue.parse(Data(contentsOf: real))
        #expect(realSettings["model"] == .string("opus"))
        #expect(managedEntries(in: realSettings, event: "Stop").count == 1)
        // 백업은 링크 옆에 (dotfiles 저장소를 어지르지 않음)
        #expect(backup?.deletingLastPathComponent().path == fixture.settingsURL.deletingLastPathComponent().path)
    }

    @Test func helperIsRefreshedOnlyWhenInstalledAndChanged() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        let installer = fixture.makeInstaller()

        // 설치한 적이 없으면 복사하지 않는다
        #expect(try installer.refreshHelperIfInstalled(helperSource: fixture.helperSource) == false)
        #expect(!FileManager.default.fileExists(atPath: fixture.helperInstallURL.path))

        try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: false)
        #expect(try installer.refreshHelperIfInstalled(helperSource: fixture.helperSource) == false)

        // 앱 업데이트로 헬퍼가 바뀐 경우
        let updated = Data("#!/bin/sh\necho updated\n".utf8)
        try updated.write(to: fixture.helperSource)
        #expect(try installer.refreshHelperIfInstalled(helperSource: fixture.helperSource))
        #expect(try Data(contentsOf: fixture.helperInstallURL) == updated)
        #expect(posixPermissions(fixture.helperInstallURL.path) == 0o755)

        // 헬퍼만 지워졌어도 훅이 남아 있으면 복구한다
        try installer.removeHelper()
        #expect(installer.status() == .helperMissing)
        #expect(try installer.refreshHelperIfInstalled(helperSource: fixture.helperSource))
        #expect(installer.status() == .installed)

        try installer.uninstall()
        try installer.removeHelper()
        #expect(try installer.refreshHelperIfInstalled(helperSource: fixture.helperSource) == false)
    }

    /// 앱을 띄울 때마다 두 파일을 통째로 비교하지 않도록 크기 · 수정 시각을 먼저 본다
    @Test func helperCopyChecksSizeAndModificationTimeFirst() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        let installer = fixture.makeInstaller()
        let source = fixture.helperSource.path
        let installed = fixture.helperInstallURL.path
        try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: false)
        // 복사본의 수정 시각을 원본에 맞춰 둔다
        #expect(FileStamp(path: installed) == FileStamp(path: source))

        // 크기가 같아도 수정 시각이 다르면 내용을 비교해 바꾼다
        let original = try Data(contentsOf: fixture.helperSource)
        let sameSize = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "printf", with: "printX").utf8)
        #expect(sameSize.count == original.count && sameSize != original)
        try sameSize.write(to: fixture.helperSource)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: source)
        #expect(try installer.refreshHelperIfInstalled(helperSource: fixture.helperSource))
        #expect(try Data(contentsOf: fixture.helperInstallURL) == sameSize)
        #expect(FileStamp(path: installed) == FileStamp(path: source))

        // 내용이 같고 수정 시각만 다르면 복사하지 않고 시각만 맞춘다
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_100)], ofItemAtPath: source)
        #expect(try installer.refreshHelperIfInstalled(helperSource: fixture.helperSource) == false)
        #expect(FileStamp(path: installed) == FileStamp(path: source))
        #expect(posixPermissions(installed) == 0o755)
    }

    @Test func missingHelperSourceThrows() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        let installer = fixture.makeInstaller()
        #expect(throws: HookInstallerError.helperSourceMissing) {
            try installer.install(helperSource: fixture.temp.url.appendingPathComponent("nope"), includeMessageDisplay: false)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.settingsURL.path))
    }
}

@Suite("HookInstaller · Codex")
struct CodexHookInstallerTests {
    @Test func installsCodexHooksWithAgentFlag() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        let installer = fixture.makeCodexInstaller()
        #expect(installer.status() == .notInstalled)

        try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: true)
        #expect(installer.status() == .installed)
        #expect(posixPermissions(fixture.codexHooksURL.path) == 0o600)

        let hooks = try #require(fixture.codexHooks()["hooks"]?.objectValue)
        // Codex 이벤트만 (MessageDisplay 를 켜도 Codex 에는 없다)
        #expect(Set(hooks.keys) == Set(HookInstaller.codexManagedEvents))
        for event in HookInstaller.codexManagedEvents {
            let group = try #require(hooks[event]?[0])
            #expect(group["matcher"] == (["PreToolUse", "PostToolUse", "PermissionRequest"].contains(event) ? .string("*") : nil))
            let entry = try #require(group["hooks"]?[0])
            #expect(entry["command"]?.stringValue == installer.command(for: event))
            #expect(entry["command"]?.stringValue?.contains("' --agent codex \(event)") == true)
        }

        // 권한 요청만 응답을 기다린다 (Codex 질문은 훅으로 답할 수 없다)
        let permission = try #require(managedEntries(in: fixture.codexHooks(), event: "PermissionRequest").first)
        #expect(permission["timeout"] == .number(600))
        #expect(permission["command"]?.stringValue?.hasSuffix("' --agent codex PermissionRequest --reply-timeout 590") == true)
        #expect(permission["statusMessage"]?.stringValue == HookInstaller.codexPermissionStatusMessage)
        let preToolUse = try #require(managedEntries(in: fixture.codexHooks(), event: "PreToolUse").first)
        #expect(preToolUse["timeout"] == .number(10))
        #expect(preToolUse["command"]?.stringValue?.contains("--reply-timeout") == false)
        #expect(preToolUse["statusMessage"] == nil)
        // Codex 는 SessionEnd · Interrupt 를 3초까지만 기다린다
        #expect(try managedEntries(in: fixture.codexHooks(), event: "Interrupt").first?["timeout"] == .number(2))
        #expect(try managedEntries(in: fixture.codexHooks(), event: "SessionEnd").first?["timeout"] == .number(2))

        // 실제 셸로 돌리면 헬퍼가 `--agent codex` 를 받는다
        let command = try #require(permission["command"]?.stringValue)
        #expect(try runShell(command) == ["--agent", "codex", "PermissionRequest", "--reply-timeout", "590"])
    }

    /// 설치된 우리 훅 내용의 지문: 설치 전 nil, 같은 내용이면 같고, 우리 항목 내용이 바뀌면 바뀐다 (다른 훅은 상관없음)
    @Test func fingerprintFollowsOurEntriesOnly() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        let installer = fixture.makeCodexInstaller()
        #expect(installer.managedFingerprint() == nil)

        try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: false)
        let first = try #require(installer.managedFingerprint())
        #expect(installer.managedFingerprint() == first)
        #expect(installer.settingsModifiedAt() != nil)

        // 다른 훅을 더해도 그대로
        var root = try #require(fixture.codexHooks().objectValue)
        var hooks = try #require(root["hooks"]?.objectValue)
        let other = try JSONValue.parse(Data(#"{"hooks":[{"type":"command","command":"/usr/bin/true"}]}"#.utf8))
        hooks["Stop"] = .array((hooks["Stop"]?.arrayValue ?? []) + [other])
        root["hooks"] = .object(hooks)
        try JSONValue.object(root).serialized().write(to: fixture.codexHooksURL)
        #expect(installer.managedFingerprint() == first)

        // 우리 항목 내용이 바뀌면 (예: 예전 timeout) 바뀐다
        var group = try #require(hooks["PermissionRequest"]?[0]?.objectValue)
        var entry = try #require(group["hooks"]?[0]?.objectValue)
        entry["timeout"] = .number(300)
        group["hooks"] = .array([.object(entry)])
        hooks["PermissionRequest"] = .array([.object(group)])
        root["hooks"] = .object(hooks)
        try JSONValue.object(root).serialized().write(to: fixture.codexHooksURL)
        #expect(installer.managedFingerprint() != first)

        try installer.uninstall()
        #expect(installer.managedFingerprint() == nil)
    }

    @Test func claudeAndCodexDoNotTouchEachOther() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        let claude = fixture.makeInstaller()
        let codex = fixture.makeCodexInstaller()
        try claude.install(helperSource: fixture.helperSource, includeMessageDisplay: false)
        #expect(codex.status() == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: fixture.codexHooksURL.path))

        try codex.install(helperSource: fixture.helperSource, includeMessageDisplay: false)
        try codex.uninstall()
        #expect(codex.status() == .notInstalled)
        #expect(claude.status() == .installed)
        // Claude Code 명령은 예전 모양 그대로 (`--agent` 없음)
        #expect(!claude.command(for: "Stop").contains("--agent"))
    }

    @Test func keepsOtherCodexHooksAndIsStable() throws {
        let fixture = try InstallerFixture()
        defer { fixture.temp.remove() }
        try FileManager.default.createDirectory(at: fixture.codexHooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let other = #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/bin/python3 policy.py","statusMessage":"Checking Bash command"}]}]}}"#
        try Data(other.utf8).write(to: fixture.codexHooksURL)
        let installer = fixture.makeCodexInstaller()

        let backup = try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: false)
        #expect(backup != nil)
        let groups = try #require(fixture.codexHooks()["hooks"]?["PreToolUse"]?.arrayValue)
        #expect(groups.count == 2)
        #expect(groups[0]["hooks"]?[0]?["command"] == .string("/usr/bin/python3 policy.py"))

        // 이미 지금 모양이면 파일을 다시 쓰지 않는다 (Codex 는 바뀐 항목을 다시 검토하게 한다)
        let before = try Data(contentsOf: fixture.codexHooksURL)
        #expect(!installer.hasOutdatedHooks())
        #expect(try installer.updateInstalledHooks() == nil)
        #expect(try installer.install(helperSource: fixture.helperSource, includeMessageDisplay: false) == nil)
        #expect(try Data(contentsOf: fixture.codexHooksURL) == before)

        try installer.uninstall()
        let remaining = try #require(fixture.codexHooks()["hooks"]?.objectValue)
        #expect(Array(remaining.keys) == ["PreToolUse"])
    }
}

/// `/bin/sh -c` 로 실행한 출력 줄들
private func runShell(_ command: String) throws -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
}
