import Foundation
import Testing
@testable import NotchServices

@MainActor
@Suite("LoginItemManager")
struct LoginItemManagerTests {
    private let executable = "/Applications/AgentNotch.app/Contents/MacOS/AgentNotch"

    @Test func enableWritesLaunchAgentAndDisableRemovesIt() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        // 아직 없는 폴더도 만들어야 한다
        let directory = temp.url.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let manager = LoginItemManager(launchAgentsDirectory: directory, executablePath: executable)
        #expect(!manager.isEnabled)
        #expect(manager.plistURL.lastPathComponent == "dev.agentnotch.AgentNotch.plist")

        try manager.setEnabled(true)
        #expect(manager.isEnabled)
        #expect(posixPermissions(manager.plistURL.path) == 0o644)

        let data = try Data(contentsOf: manager.plistURL)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "dev.agentnotch.AgentNotch")
        #expect(plist["ProgramArguments"] as? [String] == [executable])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["ProcessType"] as? String == "Interactive")
        #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")

        // 다시 켜도 문제없음
        try manager.setEnabled(true)
        #expect(manager.isEnabled)

        try manager.setEnabled(false)
        #expect(!manager.isEnabled)
        #expect(!FileManager.default.fileExists(atPath: manager.plistURL.path))
        try manager.setEnabled(false)
    }

    @Test func detectsHomebrewServices() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let manager = LoginItemManager(launchAgentsDirectory: temp.url, executablePath: executable)
        #expect(!manager.isManagedByHomebrew)

        FileManager.default.createFile(
            atPath: temp.url.appendingPathComponent("homebrew.mxcl.agent-notch.plist").path,
            contents: Data()
        )
        #expect(manager.isManagedByHomebrew)
        #expect(!manager.isEnabled)
    }
}
