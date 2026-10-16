import AppKit
import NotchCore

/// 설정 → 단축키에서 누른 키를 `KeyCombo` 로 바꾼다 (전역 단축키 녹화).
/// ⌘ · ⌃ · ⌥ 중 하나는 함께 눌러야 한다 (글자 하나만 누르면 평소 타이핑과 겹친다)
enum KeyComboRecorder {
    /// 녹화를 취소하는 키 (⎋, 수식키 없이)
    static let cancelKeyCode: UInt16 = 53

    /// 누른 키 → 키 조합. 수식키가 모자라거나 이름을 붙일 수 없는 키면 nil
    static func combo(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> KeyCombo? {
        let flags = flags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty,
              let key = keyName(keyCode: keyCode, characters: characters)
        else { return nil }
        var modifiers: KeyCombo.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return KeyCombo(keyCode: Int(keyCode), modifiers: modifiers, key: key)
    }

    /// 누른 키 → 키 조합 (`NSEvent.keyDown`). 글자는 수식키를 뺀 자판 글자로 이름 붙인다 (⌥ · ⇧ 로 바뀐 글자가 아니라)
    static func combo(from event: NSEvent) -> KeyCombo? {
        combo(keyCode: event.keyCode, flags: event.modifierFlags, characters: event.characters(byApplyingModifiers: []))
    }

    /// 키 이름: 특수 키는 정해 둔 이름, 나머지는 자판 글자(대문자). 글자가 없거나 보이지 않는 글자면 nil
    static func keyName(keyCode: UInt16, characters: String?) -> String? {
        if let name = specialKeys[keyCode] { return name }
        guard let text = characters?.trimmingCharacters(in: .whitespacesAndNewlines), text.count == 1,
              let scalar = text.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar),
              // 기능 키 · 화살표 등은 사용자 영역 문자(U+F700…)로 온다 (위 표에 없으면 쓰지 않는다)
              !(0xF700...0xF8FF).contains(scalar.value)
        else { return nil }
        return text.uppercased()
    }

    /// 글자로 이름을 붙일 수 없는 키 (`kVK_*`)
    static let specialKeys: [UInt16: String] = [
        49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    ]
}
