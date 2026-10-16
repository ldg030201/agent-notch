import Carbon.HIToolbox
import Observation
import NotchCore
import NotchShared
import NotchUI
import os

/// 설정 → 단축키의 "어디서든 펼치기 · 접기" (처음엔 꺼짐). 켜거나 키 조합을 바꾸면 다시 등록하고,
/// 다른 앱이 같은 조합을 쓰면 `registrationFailed` 로 설정 화면에 알린다. 키를 녹화하는 동안(`isPaused`)은 잠깐 해제한다
@MainActor
@Observable
final class GlobalShortcutController: GlobalShortcutState {
    private(set) var registrationFailed = false
    var isPaused = false {
        didSet { if oldValue != isPaused { apply() } }
    }

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let action: @MainActor () -> Void
    @ObservationIgnored private var hotKey: GlobalHotKey?
    /// 지금 등록해 둔 조합 (등록하지 않았으면 nil)
    @ObservationIgnored private var registered: KeyCombo?
    @ObservationIgnored private var running = false

    private static let log = Logger(subsystem: NotchWire.logSubsystem, category: "Shortcut")

    init(preferences: AppPreferences, action: @escaping @MainActor () -> Void) {
        self.preferences = preferences
        self.action = action
    }

    func start() {
        guard !running else { return }
        running = true
        apply()
        observe()
    }

    func stop() {
        running = false
        unregister()
    }

    /// 단축키 설정이 바뀌면 다시 등록한다
    private func observe() {
        guard running else { return }
        withObservationTracking {
            _ = preferences.globalShortcutEnabled
            _ = preferences.globalShortcut
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running else { return }
                self.apply()
                self.observe()
            }
        }
    }

    /// 지금 설정대로 등록 · 해제한다 (같은 조합이 이미 등록돼 있으면 그대로)
    private func apply() {
        let wanted = running && preferences.globalShortcutEnabled && !isPaused ? preferences.globalShortcut : nil
        // 같은 조합이 이미 등록돼 있으면 그대로 (등록에 실패했던 조합은 다시 해 본다)
        if let wanted, wanted == registered { return }
        unregister()
        guard let combo = wanted else {
            if registrationFailed { registrationFailed = false }
            return
        }
        let action = self.action
        hotKey = GlobalHotKey(keyCode: UInt32(combo.keyCode), modifiers: Self.carbonModifiers(combo.modifiers)) { action() }
        registered = hotKey == nil ? nil : combo
        let failed = hotKey == nil
        if failed { Self.log.info("전역 단축키 등록 실패 (다른 앱이 사용 중)") }
        if registrationFailed != failed { registrationFailed = failed }
    }

    private func unregister() {
        hotKey?.invalidate()
        hotKey = nil
        registered = nil
    }

    /// 수식키 → Carbon 수식키 (`RegisterEventHotKey`)
    static func carbonModifiers(_ modifiers: KeyCombo.Modifiers) -> UInt32 {
        var value = 0
        if modifiers.contains(.control) { value |= controlKey }
        if modifiers.contains(.option) { value |= optionKey }
        if modifiers.contains(.shift) { value |= shiftKey }
        if modifiers.contains(.command) { value |= cmdKey }
        return UInt32(value)
    }
}

/// 전역 단축키 하나 (Carbon `RegisterEventHotKey`, 손쉬운 사용 권한 불필요).
/// 메뉴바 아이콘이 노치 뒤로 밀려 안 보여도 아일랜드를 펼칠 수 있게 한다. 켜고 끄기 · 조합은 `GlobalShortcutController` 가 정한다
@MainActor
final class GlobalHotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            // Carbon 이벤트는 메인 스레드에서 전달된다
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &eventType, context, &handlerRef)
        guard installed == noErr else { return nil }

        let identifier = EventHotKeyID(signature: OSType(0x414E_4F54), id: 1)  // 'ANOT'
        let registered = RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            // 다른 앱이 같은 조합을 쓰는 중
            invalidate()
            return nil
        }
    }

    func invalidate() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
