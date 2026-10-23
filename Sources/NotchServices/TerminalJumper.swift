import AppKit
import NotchCore
import os

/// 세션을 실행한 터미널/앱을 앞으로 가져온다.
///
/// - iTerm2: `ITERM_SESSION_ID` 의 UUID 로 해당 탭·세션까지 선택 (AppleScript, 자동화 권한 필요)
/// - Claude 데스크톱 앱: 앱 안의 그 세션을 링크로 연다 (`TerminalContext.claudeDesktopSessionURL`, 못 열면 앱만)
/// - Codex 데스크톱 앱: 앱 안의 그 스레드를 링크로 연다 (`TerminalContext.codexDesktopThreadURL`, 못 열면 앱만)
/// - 그 외: 번들 ID 로 앱만 활성화
///
/// iTerm2 AppleScript 는 메인 스레드 밖 전용 큐에서 돌린다. 멈춘 iTerm2 나 처음 뜨는 자동화 권한 창이
/// 메인을 붙잡으면 그동안 훅 이벤트 · 권한 응답이 모두 멈추기 때문이다 (스크립트에도 `with timeout` 을 건다).
@MainActor
public final class TerminalJumper {
    nonisolated static let iTermBundleID = "com.googlecode.iterm2"
    /// iTerm2 에 보낸 Apple Event 의 응답을 기다리는 최대 시간 (초)
    nonisolated static let scriptTimeoutSeconds = 5

    /// AppleScript 전용 직렬 큐. `NSAppleScript` 는 스레드 안전하지 않아 만들고 돌리는 일을 모두 여기서만 한다.
    private nonisolated static let scriptQueue = DispatchQueue(label: "com.ldg.agent-notch.iterm-script", qos: .userInitiated)
    private nonisolated static let log = NotchServices.logger("terminal")

    /// iTerm2 세션 선택 (`scriptQueue` 에서 불린다). 검증된 UUID 만 받는다
    private let selectITermSession: @Sendable (String) -> Bool
    private let isRunning: (String) -> Bool
    private let activateApp: (String) -> Bool
    /// 링크를 그 번들 ID 의 앱으로 연다. 열기 시작했으면 true
    private let openURL: (URL, String) -> Bool

    public convenience init() {
        self.init(
            selectITermSession: { Self.runITermSelectScript($0) },
            isRunning: { Self.isRunning($0) },
            activate: { Self.activate(bundleID: $0) },
            openURL: { Self.open($0, inAppWithBundleID: $1) }
        )
    }

    /// 테스트에서 AppleScript · 앱 활성화 · 링크 열기를 바꿔 끼운다
    init(
        selectITermSession: @escaping @Sendable (String) -> Bool,
        isRunning: @escaping (String) -> Bool,
        activate: @escaping (String) -> Bool,
        openURL: @escaping (URL, String) -> Bool = { _, _ in false }
    ) {
        self.selectITermSession = selectITermSession
        self.isRunning = isRunning
        self.activateApp = activate
        self.openURL = openURL
    }

    /// 앱을 앞으로 가져오기 시작했으면 true.
    /// iTerm2 세션 선택은 메인 밖에서 돌고 끝나면 iTerm2 를 활성화한다 (실패하면 번들 ID 로 앱만 활성화).
    @discardableResult
    public func jump(to context: TerminalContext) -> Bool {
        let bundleID = context.hostBundleIdentifier

        // iTerm2 안에서 실행된 세션이면 탭까지 찾아간다
        // (VS Code 터미널 등이 ITERM_SESSION_ID 를 물려받은 경우는 제외)
        if bundleID == nil || bundleID == Self.iTermBundleID,
           let raw = context.itermSessionID,
           let sessionUUID = Self.iTermSessionUUID(from: raw),
           isRunning(Self.iTermBundleID) {
            let select = selectITermSession
            Self.scriptQueue.async { [weak self] in
                let selected = select(sessionUUID)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.finishITermJump(selected: selected, fallback: bundleID) }
                }
            }
            return true
        }

        // Claude · Codex 데스크톱 앱 세션이면 앱 안의 그 세션까지 연다 (링크를 열지 못하면 앱만 앞으로)
        if let url = context.claudeDesktopSessionURL, openURL(url, TerminalContext.claudeDesktopBundleID) {
            return true
        }
        if let url = context.codexDesktopThreadURL, openURL(url, TerminalContext.codexDesktopBundleID) {
            return true
        }

        guard let bundleID else { return false }
        return activateApp(bundleID)
    }

    /// `w0t1p0:9F1C…` → UUID 부분. 엄격한 UUID 형식이 아니면 nil (AppleScript 에 넣기 전 검증).
    nonisolated static func iTermSessionUUID(from raw: String) -> String? {
        let candidate: Substring
        if let colon = raw.firstIndex(of: ":") {
            candidate = raw[raw.index(after: colon)...]
        } else {
            candidate = raw[...]
        }
        return isStrictUUID(candidate) ? String(candidate) : nil
    }

    /// 8-4-4-4-12 형식의 16진수 UUID 인지
    nonisolated static func isStrictUUID(_ text: Substring) -> Bool {
        let utf8 = Array(text.utf8)
        guard utf8.count == 36 else { return false }
        for (index, byte) in utf8.enumerated() {
            switch index {
            case 8, 13, 18, 23:
                guard byte == UInt8(ascii: "-") else { return false }
            default:
                let isHex = (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                    || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
                guard isHex else { return false }
            }
        }
        return true
    }

    // MARK: - 내부

    private func finishITermJump(selected: Bool, fallback bundleID: String?) {
        if selected {
            _ = activateApp(Self.iTermBundleID)
        } else if let bundleID {
            _ = activateApp(bundleID)
        }
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    /// iTerm2 의 해당 세션이 있는 창·탭·세션을 고르는 AppleScript. `sessionUUID` 는 검증된 UUID 만 받는다.
    /// `with timeout`: iTerm2 가 응답하지 않으면 기다리지 않고 오류로 끝낸다
    nonisolated static func iTermSelectScript(_ sessionUUID: String) -> String? {
        guard isStrictUUID(sessionUUID[...]) else { return nil }
        return """
        with timeout of \(scriptTimeoutSeconds) seconds
            tell application id "\(iTermBundleID)"
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aSession in sessions of aTab
                            if (unique id of aSession) is "\(sessionUUID)" then
                                tell aWindow to select
                                tell aTab to select
                                tell aSession to select
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
        end timeout
        return false
        """
    }

    /// AppleScript 를 실제로 돌린다. **`scriptQueue` 에서만** 부른다 (메인을 막지 않게, `NSAppleScript` 를 한 스레드에 가둔다)
    private nonisolated static func runITermSelectScript(_ sessionUUID: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(scriptQueue))
        guard let source = iTermSelectScript(sessionUUID), let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil {
            log.error("iTerm2 세션 선택 실패 (자동화 권한 · 응답 시간 확인 필요)")
            return false
        }
        return result.booleanValue
    }

    /// 링크를 번들 ID 로 정한 앱에서 연다 (같은 스킴을 등록한 다른 앱이 받지 않게). 앱이 설치돼 있지 않으면 false.
    /// 열다가 실패하면 앱만 앞으로 가져온다
    private static func open(_ url: URL, inAppWithBundleID bundleID: String) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        // 비활성 앱(노치 패널)에서 여는 앱이 앞으로 오도록 활성화를 넘겨준다
        NSApp?.yieldActivation(toApplicationWithBundleIdentifier: bundleID)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
            guard error != nil else { return }
            log.error("앱 세션 링크 열기 실패 (앱만 앞으로)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = activate(bundleID: bundleID) }
            }
        }
        return true
    }

    @discardableResult
    private static func activate(bundleID: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated }) else {
            log.info("대상 앱이 실행 중이 아님: \(bundleID, privacy: .private)")
            return false
        }
        // 비활성 앱(노치 패널)에서의 활성화 요청이 거절되지 않도록 활성화를 넘겨준다
        NSApp?.yieldActivation(to: app)
        if app.activate(options: [.activateAllWindows]) {
            return true
        }
        // 협력적 활성화가 거절되면 LaunchServices 로 다시 시도
        guard let url = app.bundleURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        return true
    }
}
