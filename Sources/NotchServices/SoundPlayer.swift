import AppKit
import NotchCore

/// 아일랜드 신호에 맞는 시스템 사운드를 재생한다.
/// 설정(소리 끔, 터미널이 앞에 있으면 생략)은 호출하는 쪽에서 판단한다.
@MainActor
public final class SoundPlayer {
    private var cache: [String: NSSound] = [:]

    public init() {}

    public func play(for signal: IslandSignal) {
        guard let name = Self.soundName(for: signal), let sound = sound(named: name) else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// 신호별 시스템 사운드 이름 (nil 이면 소리 없음)
    public nonisolated static func soundName(for signal: IslandSignal) -> String? {
        switch signal {
        case .permissionRequested: return "Glass"
        case .needsInput: return "Tink"
        case .completed: return "Ping"
        case .failed: return "Basso"
        case .edited, .sessionStarted: return nil
        }
    }

    private func sound(named name: String) -> NSSound? {
        if let cached = cache[name] { return cached }
        guard let sound = NSSound(named: NSSound.Name(name)) else { return nil }
        cache[name] = sound
        return sound
    }
}
