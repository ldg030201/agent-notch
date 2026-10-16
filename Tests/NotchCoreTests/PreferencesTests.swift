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
            preferences.notchStyle = .belowNotch
            preferences.compactOverlapStyle = .minimal
            preferences.restoresRecentSessions = false
            preferences.checksForUpdates = false
            preferences.rotatesSessions = false
            preferences.sessionRotationInterval = 12

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
                #expect(preferences.notchStyle == fresh.notchStyle)
                #expect(preferences.compactOverlapStyle == fresh.compactOverlapStyle)
                #expect(preferences.restoresRecentSessions == fresh.restoresRecentSessions)
                #expect(preferences.checksForUpdates == fresh.checksForUpdates)
                #expect(preferences.rotatesSessions == fresh.rotatesSessions)
                #expect(preferences.sessionRotationInterval == fresh.sessionRotationInterval)
            }
            // 저장된 값은 남기지 않는다 (나중 버전의 처음 값을 따르게)
            #expect((defaults.persistentDomain(forName: suite) ?? [:]).isEmpty)
        }
    }

    /// 다시 읽어도 초기화한 값이다
    @Test func resetSurvivesReload() {
        Self.withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            preferences.notchStyle = .belowNotch
            preferences.permissionTimeout = 30
            preferences.resetToDefaults()
            let reloaded = AppPreferences(defaults: defaults)
            #expect(reloaded.notchStyle == .wings)
            #expect(reloaded.permissionTimeout == 120)
        }
    }
}
