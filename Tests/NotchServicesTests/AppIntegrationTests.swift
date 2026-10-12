import Foundation
import NotchCore
import Testing
@testable import NotchServices

@Suite("TerminalJumper")
struct TerminalJumperTests {
    @Test func extractsValidITermSessionUUID() {
        let uuid = "9F1C2B3A-1234-4ABC-9DEF-0123456789AB"
        #expect(TerminalJumper.iTermSessionUUID(from: "w0t1p0:\(uuid)") == uuid)
        #expect(TerminalJumper.iTermSessionUUID(from: uuid) == uuid)
        #expect(TerminalJumper.iTermSessionUUID(from: "w12t3p1:\(uuid.lowercased())") == uuid.lowercased())
    }

    @Test func rejectsUnsafeITermSessionIDs() {
        let invalid = [
            "",
            "w0t1p0:",
            "w0t1p0:not-a-uuid",
            "w0t1p0:9F1C2B3A-1234-4ABC-9DEF-0123456789ABX",
            "w0t1p0:9F1C2B3A-1234-4ABC-9DEF-0123456789A\"",
            "w0t1p0:\" & (do shell script \"echo pwned\") & \"",
            "w0t1p0:9F1C2B3A_1234_4ABC_9DEF_0123456789AB",
            "w0t1p0:9F1C2B3A-1234-4ABC-9DEF-0123456789AG",
        ]
        for raw in invalid {
            #expect(TerminalJumper.iTermSessionUUID(from: raw) == nil, "\(raw)")
        }
    }

    @Test func resolvesBundleIdentifier() {
        func resolve(_ context: TerminalContext) -> String? {
            TerminalJumper.resolveBundleIdentifier(for: context)
        }
        #expect(resolve(TerminalContext(termProgram: "iTerm.app")) == "com.googlecode.iterm2")
        #expect(resolve(TerminalContext(termProgram: "Apple_Terminal")) == "com.apple.Terminal")
        #expect(resolve(TerminalContext(termProgram: "vscode")) == "com.microsoft.VSCode")
        #expect(resolve(TerminalContext(termProgram: "WarpTerminal")) == "dev.warp.Warp-Stable")
        #expect(resolve(TerminalContext(termProgram: "ghostty")) == "com.mitchellh.ghostty")
        #expect(resolve(TerminalContext(termProgram: "WezTerm")) == "com.github.wez.wezterm")
        #expect(resolve(TerminalContext(termProgram: "zed")) == "dev.zed.Zed")
        #expect(resolve(TerminalContext(entrypoint: "claude-desktop")) == "com.anthropic.claudefordesktop")
        // 번들 ID 가 있으면 그것을 우선
        #expect(resolve(TerminalContext(termProgram: "tmux", bundleIdentifier: "com.googlecode.iterm2")) == "com.googlecode.iterm2")
        #expect(resolve(TerminalContext(termProgram: "vscode", bundleIdentifier: "com.todesktop.230313mzl4w4u92")) == "com.todesktop.230313mzl4w4u92")
        #expect(resolve(TerminalContext(termProgram: "tmux")) == nil)
        #expect(resolve(TerminalContext()) == nil)
    }

    @MainActor
    @Test func instanceMethodMatchesStatic() {
        let context = TerminalContext(termProgram: "ghostty")
        #expect(TerminalJumper().bundleIdentifier(for: context) == "com.mitchellh.ghostty")
    }
}

@MainActor
@Suite("FrontmostAppMonitor")
struct FrontmostAppMonitorTests {
    @Test func comparesWithSessionTerminal() {
        let monitor = FrontmostAppMonitor()
        monitor.frontmostBundleID = "com.googlecode.iterm2"
        #expect(monitor.isFrontmost(TerminalContext(termProgram: "iTerm.app")))
        #expect(!monitor.isFrontmost(TerminalContext(termProgram: "Apple_Terminal")))
        #expect(!monitor.isFrontmost(TerminalContext()))

        monitor.frontmostBundleID = nil
        #expect(!monitor.isFrontmost(TerminalContext(termProgram: "iTerm.app")))
    }
}

@Suite("SoundPlayer")
struct SoundPlayerTests {
    @Test func mapsSignalsToSystemSounds() {
        let diff = DiffSnippet(filePath: "/Users/dev/projects/api-server/src/session.ts", added: 1, removed: 0, lines: [])
        #expect(SoundPlayer.soundName(for: .permissionRequested(id: UUID(), sessionID: "s")) == "Glass")
        #expect(SoundPlayer.soundName(for: .needsInput(sessionID: "s", message: "질문")) == "Tink")
        #expect(SoundPlayer.soundName(for: .completed(sessionID: "s")) == "Ping")
        #expect(SoundPlayer.soundName(for: .failed(sessionID: "s")) == "Basso")
        #expect(SoundPlayer.soundName(for: .edited(sessionID: "s", diff: diff)) == nil)
        #expect(SoundPlayer.soundName(for: .sessionStarted(sessionID: "s")) == nil)
    }
}

@Suite("FileOpener")
struct FileOpenerTests {
    @Test func classifiesFilesBeforeOpening() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        func make(_ name: String, executable: Bool = false) throws -> String {
            let url = temp.url.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            if executable {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            return url.path
        }

        #expect(FileOpener.disposition(for: try make("notes.md")) == .open)
        #expect(FileOpener.disposition(for: try make("session.swift")) == .open)
        #expect(FileOpener.disposition(for: try make("build.py")) == .openAsText)
        #expect(FileOpener.disposition(for: try make("deploy.sh")) == .openAsText)
        #expect(FileOpener.disposition(for: try make("run.command")) == .reveal)
        #expect(FileOpener.disposition(for: try make("Install.pkg")) == .reveal)
        #expect(FileOpener.disposition(for: try make("tool", executable: true)) == .reveal)
        #expect(FileOpener.disposition(for: temp.url.path) == .reveal)
        #expect(FileOpener.disposition(for: temp.url.appendingPathComponent("missing.txt").path) == .unavailable)
        #expect(FileOpener.disposition(for: "relative/path.txt") == .unavailable)
    }
}
