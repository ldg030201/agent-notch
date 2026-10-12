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
            #expect(entry["timeout"]?.intValue == HookInstaller.timeout(for: event))
        }

        let permission = try #require(managedEntries(in: settings, event: "PermissionRequest").first)
        #expect(permission["timeout"] == .number(600))
        #expect(permission["command"]?.stringValue?.hasSuffix("' PermissionRequest --reply-timeout 590") == true)
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
        #expect(HookInstaller.shellQuoted("a b") == "'a b'")
        #expect(HookInstaller.shellQuoted("it's") == "'it'\\''s'")

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
