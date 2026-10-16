import Foundation
import Testing
@testable import NotchCore

/// 설정 초기화 (임시 UserDefaults 영역만 사용)
@MainActor
@Suite struct PreferencesTests {
    /// 테스트마다 따로 쓰는 UserDefaults 영역. 끝나면 지운다
    static func withDefaults(_ body: (UserDefaults, String) -> Void) {
        let suite = "agent-notch-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults, suite)
    }

    @Test func resetRestoresEveryDefault() {
        Self.withDefaults { defaults, suite in
            let preferences = AppPreferences(defaults: defaults)
            preferences.displayPolicy = .builtInOnly
            preferences.fullscreenBehavior = .hide
            preferences.peekOnEdit = false
            preferences.peekDuration = 9
            preferences.completionDisplayDuration = 12
            preferences.showStreamingText = false
            preferences.permissionTimeout = 30
            preferences.staleSessionTimeout = 60
            preferences.passthroughWhenTerminalFrontmost = false
            preferences.externalDisplayStyle = .hidden
            preferences.restoresRecentSessions = false
            preferences.checksForUpdates = false
            preferences.rotatesSessions = false
            preferences.sessionRotationInterval = 12
            preferences.globalShortcutEnabled = true
            preferences.globalShortcut = KeyCombo(keyCode: 49, modifiers: [.option], key: "Space")
            preferences.permissionShortcutsEnabled = true
            preferences.interactionShortcutsEnabled = true
            preferences.collapseShortcutEnabled = true

            preferences.resetToDefaults()

            Self.withDefaults { empty, _ in
                let fresh = AppPreferences(defaults: empty)
                #expect(preferences.displayPolicy == fresh.displayPolicy)
                #expect(preferences.fullscreenBehavior == fresh.fullscreenBehavior)
                #expect(preferences.peekOnEdit == fresh.peekOnEdit)
                #expect(preferences.peekDuration == fresh.peekDuration)
                #expect(preferences.completionDisplayDuration == fresh.completionDisplayDuration)
                #expect(preferences.showStreamingText == fresh.showStreamingText)
                #expect(preferences.permissionTimeout == fresh.permissionTimeout)
                #expect(preferences.staleSessionTimeout == fresh.staleSessionTimeout)
                #expect(preferences.passthroughWhenTerminalFrontmost == fresh.passthroughWhenTerminalFrontmost)
                #expect(preferences.externalDisplayStyle == fresh.externalDisplayStyle)
                #expect(preferences.restoresRecentSessions == fresh.restoresRecentSessions)
                #expect(preferences.checksForUpdates == fresh.checksForUpdates)
                #expect(preferences.rotatesSessions == fresh.rotatesSessions)
                #expect(preferences.sessionRotationInterval == fresh.sessionRotationInterval)
                #expect(preferences.globalShortcutEnabled == fresh.globalShortcutEnabled)
                #expect(preferences.globalShortcut == fresh.globalShortcut)
                #expect(preferences.permissionShortcutsEnabled == fresh.permissionShortcutsEnabled)
                #expect(preferences.interactionShortcutsEnabled == fresh.interactionShortcutsEnabled)
                #expect(preferences.collapseShortcutEnabled == fresh.collapseShortcutEnabled)
            }
            // 저장된 값은 남기지 않는다 (나중 버전의 처음 값을 따르게)
            #expect((defaults.persistentDomain(forName: suite) ?? [:]).isEmpty)
        }
    }

    /// 단축키는 처음엔 모두 꺼져 있고, 바꾼 키 조합은 다시 읽어도 그대로다
    @Test func shortcutsStartOffAndPersist() {
        Self.withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            #expect(!preferences.globalShortcutEnabled)
            #expect(!preferences.permissionShortcutsEnabled)
            #expect(!preferences.interactionShortcutsEnabled)
            #expect(!preferences.collapseShortcutEnabled)
            #expect(preferences.globalShortcut == .defaultToggle)
            #expect(preferences.globalShortcut.displayString == "⌃⌥⌘N")

            let combo = KeyCombo(keyCode: 49, modifiers: [.command, .shift], key: "Space")
            preferences.globalShortcut = combo
            preferences.globalShortcutEnabled = true
            let reloaded = AppPreferences(defaults: defaults)
            #expect(reloaded.globalShortcut == combo)
            #expect(reloaded.globalShortcut.displayString == "⇧⌘Space")
            #expect(reloaded.globalShortcutEnabled)
        }
    }

    /// 없앤 설정(노치 화면 표시 방식 · 노치 아래 표시 모양)의 저장된 값은 읽을 때 지운다
    @Test func removedKeysAreCleared() {
        Self.withDefaults { defaults, suite in
            defaults.set("wings", forKey: "notchStyle")
            defaults.set("minimal", forKey: "compactOverlapStyle")
            _ = AppPreferences(defaults: defaults)
            let stored = defaults.persistentDomain(forName: suite) ?? [:]
            #expect(stored["notchStyle"] == nil)
            #expect(stored["compactOverlapStyle"] == nil)
        }
    }

    /// 다시 읽어도 초기화한 값이다
    @Test func resetSurvivesReload() {
        Self.withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            preferences.externalDisplayStyle = .hidden
            preferences.permissionTimeout = 30
            preferences.resetToDefaults()
            let reloaded = AppPreferences(defaults: defaults)
            #expect(reloaded.externalDisplayStyle == .inMenuBar)
            #expect(reloaded.permissionTimeout == 120)
        }
    }
}
