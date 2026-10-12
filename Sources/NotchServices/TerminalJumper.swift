import AppKit
import NotchCore
import os

/// 세션을 실행한 터미널/앱을 앞으로 가져온다.
///
/// - iTerm2: `ITERM_SESSION_ID` 의 UUID 로 해당 탭·세션까지 선택 (AppleScript, 자동화 권한 필요)
/// - 그 외: 번들 ID 로 앱만 활성화
@MainActor
public final class TerminalJumper {
    nonisolated static let iTermBundleID = "com.googlecode.iterm2"
    nonisolated static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    /// `TERM_PROGRAM` → 번들 ID (소문자 키)
    nonisolated static let termProgramBundleIDs: [String: String] = [
        "iterm.app": iTermBundleID,
        "apple_terminal": "com.apple.Terminal",
        "vscode": "com.microsoft.VSCode",
        "warpterminal": "dev.warp.Warp-Stable",
        "ghostty": "com.mitchellh.ghostty",
        "wezterm": "com.github.wez.wezterm",
        "zed": "dev.zed.Zed",
    ]

    private let log = NotchServices.logger("terminal")

    public init() {}

    /// 성공적으로 앱(또는 iTerm2 세션)을 앞으로 가져왔으면 true
    @discardableResult
    public func jump(to context: TerminalContext) -> Bool {
        let bundleID = bundleIdentifier(for: context)

        // iTerm2 안에서 실행된 세션이면 탭까지 찾아간다
        // (VS Code 터미널 등이 ITERM_SESSION_ID 를 물려받은 경우는 제외)
        if bundleID == nil || bundleID == Self.iTermBundleID,
           let raw = context.itermSessionID,
           let sessionUUID = Self.iTermSessionUUID(from: raw),
           isRunning(Self.iTermBundleID),
           selectITermSession(sessionUUID) {
            activate(bundleID: Self.iTermBundleID)
            return true
        }

        guard let bundleID else { return false }
        return activate(bundleID: bundleID)
    }

    /// 세션을 띄운 앱의 번들 ID (앞에 있는 앱 감지와 공유)
    public func bundleIdentifier(for context: TerminalContext) -> String? {
        Self.resolveBundleIdentifier(for: context)
    }

    nonisolated static func resolveBundleIdentifier(for context: TerminalContext) -> String? {
        if let bundleID = context.bundleIdentifier?.trimmingCharacters(in: .whitespaces), !bundleID.isEmpty {
            return bundleID
        }
        if let program = context.termProgram?.lowercased(), let bundleID = termProgramBundleIDs[program] {
            return bundleID
        }
        if let entrypoint = context.entrypoint?.lowercased(), entrypoint.contains("desktop") {
            return claudeDesktopBundleID
        }
        return nil
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

    private func isRunning(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    /// iTerm2 의 해당 세션이 있는 창·탭·세션을 선택한다. `sessionUUID` 는 검증된 UUID 만 받는다.
    private func selectITermSession(_ sessionUUID: String) -> Bool {
        guard Self.isStrictUUID(sessionUUID[...]) else { return false }
        let source = """
        tell application id "\(Self.iTermBundleID)"
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
        return false
        """
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil {
            log.error("iTerm2 세션 선택 실패 (자동화 권한 확인 필요)")
            return false
        }
        return result.booleanValue
    }

    @discardableResult
    private func activate(bundleID: String) -> Bool {
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
