import Carbon.HIToolbox

/// 전역 단축키 (Carbon `RegisterEventHotKey`, 손쉬운 사용 권한 불필요).
/// 메뉴바 아이콘이 노치 뒤로 밀려 안 보여도 아일랜드를 펼칠 수 있게 한다.
@MainActor
final class GlobalHotKey {
    /// ⌃⌥⌘N
    static let toggleKeyCode = UInt32(kVK_ANSI_N)
    static let toggleModifiers = UInt32(controlKey | optionKey | cmdKey)

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
