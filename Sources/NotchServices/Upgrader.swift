import AppKit
import Foundation
import Observation

/// 앱 안에서 `brew upgrade agent-notch` 를 돌리고, 사용자가 확인하면 앱을 새 버전으로 바꿔 다시 띄운다.
///
/// `brew upgrade` 는 Homebrew 폴더에만 쓰므로 앱이 살아 있는 채로 끝까지 돌린다. 앱이 스스로 못 하는 건
/// 실행 중인 자기 번들(`/Applications/AgentNotch.app`)을 바꾸는 것뿐이라, 그 단계만 분리된 스크립트(`UpgradeHandoff`)에 맡긴다.
/// 다 받은 뒤에는 멈춰서 기다린다 — 사용자가 "다시 띄우기" 를 눌러야 앱이 꺼진다.
@MainActor
@Observable
public final class Upgrader {
    public enum Phase: Equatable, Sendable {
        case idle
        /// brew 가 도는 중
        case running
        /// 새 버전을 다 받음. 다시 띄우기를 기다린다
        case ready
        /// 교체 스크립트를 띄웠고 곧 꺼진다
        case swapping
        case failed(String)
    }

    /// tap 이름 · formula · 번들 이름 (스크립트와 안내 문구가 같이 쓴다)
    public nonisolated static let tap = "ldg030201/agent-notch"
    public nonisolated static let formula = "agent-notch"
    public nonisolated static let appBundleName = "AgentNotch.app"
    public nonisolated static let executableName = "AgentNotch"
    /// 진행 로그 최대 길이. 소스 빌드로 떨어지면 컴파일 줄이 수천 줄 나온다.
    public nonisolated static let logLimit = 40_000

    public private(set) var phase: Phase = .idle
    /// brew 출력 (stdout + stderr, 뒤쪽 `logLimit` 자만 유지)
    public private(set) var log = ""

    public var isBusy: Bool { phase == .running || phase == .swapping }

    @ObservationIgnored private let isTestBuild: Bool
    @ObservationIgnored private let isAppBundle: Bool
    @ObservationIgnored private let resolveBrew: () -> String?
    @ObservationIgnored private let terminate: @MainActor () -> Void
    @ObservationIgnored private var process: Process?
    /// `.ready` 동안 교체에 쓸 brew 경로
    @ObservationIgnored private var readyBrew: String?

    public init(
        isTestBuild: Bool,
        isAppBundle: Bool = Bundle.main.bundleURL.pathExtension == "app",
        resolveBrew: @escaping () -> String? = { Upgrader.resolveBrew() },
        terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }
    ) {
        self.isTestBuild = isTestBuild
        self.isAppBundle = isAppBundle
        self.resolveBrew = resolveBrew
        self.terminate = terminate
    }

    // MARK: - 받기

    public func start() {
        guard !isBusy else { return }
        guard !isTestBuild else {
            phase = .failed("테스트판은 자체 업데이트를 하지 않아요.")
            return
        }
        guard isAppBundle else {
            phase = .failed("앱 번들로 실행할 때만 업데이트할 수 있어요.")
            return
        }
        guard let brew = resolveBrew() else {
            phase = .failed("Homebrew 를 찾지 못했어요. 터미널에서 brew upgrade \(Self.formula) 를 직접 실행해 주세요.")
            return
        }
        log = ""
        readyBrew = nil
        phase = .running
        run(script: Self.upgradeScript(brew: brew), brew: brew)
    }

    /// 진행 중이면 멈춘다. Homebrew 는 중간에 끊겨도 다음 번에 이어서 한다.
    public func cancel() {
        let running = process
        process = nil
        if let running, running.isRunning {
            // bash 만 끝내면 그 밑의 brew 가 남는다. 직접 띄운 자식부터 끝낸다.
            Self.terminateChildren(of: running.processIdentifier)
            running.terminate()
        }
        if phase == .running {
            phase = .idle
        }
    }

    /// 실패 · 준비 화면을 닫는다
    public func dismiss() {
        guard !isBusy else { return }
        phase = .idle
    }

    private func run(script: String, brew: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", script]
        task.environment = Self.environment(brew: brew)
        // 앱 번들 안을 현재 폴더로 잡고 있으면 교체할 때 걸린다
        task.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        // stdout · stderr 를 한 통으로 받는다 (brew 는 진행 상황을 stderr 로도 낸다)
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.standardInput = FileHandle.nullDevice
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: 핸들러를 놓지 않으면 빈 읽기가 계속 불린다
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.append(text) }
        }
        task.terminationHandler = { [weak self] finished in
            let id = ObjectIdentifier(finished)
            let status = finished.terminationStatus
            // 마지막 출력이 전달될 틈을 잠깐 준다. EOF 를 기다리지 않는 이유: brew 가 띄운 다른 프로세스가
            // 파이프를 물고 있으면 EOF 가 오지 않아 끝나지 않는다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                reader.readabilityHandler = nil
                MainActor.assumeIsolated {
                    self?.finish(processID: id, status: status, brew: brew)
                }
            }
        }

        do {
            try task.run()
            process = task
        } catch {
            reader.readabilityHandler = nil
            phase = .failed("brew 를 실행하지 못했어요: \(error.localizedDescription)")
        }
    }

    private func append(_ text: String) {
        log += text
        if log.count > Self.logLimit {
            log = String(log.suffix(Self.logLimit))
        }
    }

    private func finish(processID: ObjectIdentifier, status: Int32, brew: String) {
        // 취소된 실행(또는 이전 실행)의 종료는 무시한다
        guard let process, ObjectIdentifier(process) == processID else { return }
        self.process = nil
        guard phase == .running else { return }
        guard status == 0 else {
            phase = .failed("업데이트가 끝나지 않았어요 (종료 코드 \(status)). 아래 로그를 확인해 주세요.")
            return
        }
        readyBrew = brew
        phase = .ready
        append("\n새 버전을 받았어요. 다시 띄우면 끝나요.\n")
    }

    // MARK: - 교체 · 다시 띄우기

    /// 받아 둔 새 버전으로 바꾸고 앱을 끈다. **사용자가 눌러야만** 부른다.
    public func relaunch() {
        guard phase == .ready, let brew = readyBrew else { return }
        phase = .swapping
        append("\n앱을 새 버전으로 바꿔요. 잠시 뒤 다시 떠요.\n")

        let configuration = UpgradeHandoff.Configuration(
            brew: brew,
            processID: ProcessInfo.processInfo.processIdentifier,
            logURL: UpgradeHandoff.defaultLogURL
        )
        do {
            try UpgradeHandoff.launch(configuration)
        } catch {
            phase = .failed(
                "새 버전은 받았지만 앱을 바꾸지 못했어요. 터미널에서 실행해 주세요:\n"
                    + "rm -rf /Applications/\(Self.appBundleName) && "
                    + "cp -R \"$(brew --prefix \(Self.formula))/\(Self.appBundleName)\" /Applications/"
            )
            return
        }

        // 교체 스크립트가 우리가 꺼지기를 기다린다. 화면이 한 번 그려지게 두고 끈다.
        let terminate = terminate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated { terminate() }
        }
        // `NSApp.terminate` 는 모달 창 등에 막혀 조용히 무시될 수 있다. 그러면 직접 끝낸다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            exit(0)
        }
    }

    /// 교체가 멈춘 것 같을 때 강제 종료 (화면에서 한 번 확인받고 부른다)
    public func forceQuit() {
        exit(0)
    }

    // MARK: - 스크립트

    /// 앱에는 로그인 셸의 PATH 가 없다. brew 가 제 도구를 찾을 수 있게 맞추고, 묻는 창 · 자동 갱신을 끈다.
    /// (플래그 대신 환경변수를 쓴다 — 옛 Homebrew 는 모르는 변수는 무시하지만 모르는 플래그에는 실패한다)
    nonisolated static func environment(brew: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let brewDirectory = URL(fileURLWithPath: brew).deletingLastPathComponent().path
        environment["PATH"] = "\(brewDirectory):/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOMEBREW_NO_ASK"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        return environment
    }

    /// tap 을 갱신하고 새 버전을 받는다. **`/Applications` 는 건드리지 않는다.**
    public nonisolated static func upgradeScript(brew: String) -> String {
        """
        set -o pipefail
        BREW=\(shellQuoted(brew))

        # brew update 는 Homebrew 와 모든 tap 을 갱신해서 오래 걸린다. 우리 tap 하나만 먼저 당겨 본다.
        TAP="$("$BREW" --repository \(shellQuoted(tap)) 2>/dev/null)"
        if [ -n "$TAP" ] && [ -d "$TAP/.git" ] && git -C "$TAP" pull --quiet 2>/dev/null; then
          echo "tap 갱신 완료"
        else
          echo "tap 만으로 갱신하지 못해 brew update 를 실행해요. 조금 걸려요."
          "$BREW" update || exit 1
        fi

        echo
        "$BREW" upgrade \(shellQuoted(formula)) || exit 1
        """
    }

    /// 작은따옴표로 감싸 셸에 글자 그대로 넘긴다
    public nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `pkill -TERM -P <pid>`: 해당 프로세스가 직접 띄운 자식들에게 종료 신호
    nonisolated static func terminateChildren(of pid: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-TERM", "-P", String(pid)]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return }
        task.waitUntilExit()
    }

    // MARK: - brew 찾기

    /// 알려진 위치를 먼저 보고, 없으면 로그인 셸에 물어본다
    public nonisolated static func resolveBrew(fileManager: FileManager = .default) -> String? {
        let known = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        if let found = known.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return found
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", "command -v brew"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return !path.isEmpty && fileManager.isExecutableFile(atPath: path) ? path : nil
    }

    // MARK: - 점검 (`--probe-upgrade`)

    /// 실제로 돌리지 않고 brew 위치와 두 스크립트의 문법(`bash -n`)만 확인한다. 성공하면 true.
    public nonisolated static func probe(output: (String) -> Void = { print($0) }) -> Bool {
        let brew = resolveBrew()
        output("brew: \(brew ?? "(찾지 못함)")")
        output("교체 로그: \(UpgradeHandoff.defaultLogURL.path)")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notch-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            output("임시 폴더를 만들지 못했어요: \(error.localizedDescription)")
            return false
        }

        let brewPath = brew ?? "/opt/homebrew/bin/brew"
        let handoff = UpgradeHandoff.Configuration(
            brew: brewPath,
            processID: ProcessInfo.processInfo.processIdentifier,
            logURL: UpgradeHandoff.defaultLogURL
        )
        var ok = brew != nil
        for (name, script) in [("받기", upgradeScript(brew: brewPath)), ("교체", UpgradeHandoff.script(handoff))] {
            let url = directory.appendingPathComponent("\(name).sh")
            let passed: Bool
            do {
                try Data(script.utf8).write(to: url)
                passed = syntaxCheck(url)
            } catch {
                passed = false
            }
            output("  \(name) 스크립트 문법: \(passed ? "ok" : "실패")")
            ok = ok && passed
        }
        return ok
    }

    /// `bash -n` 으로 문법만 검사한다 (실행하지 않음)
    public nonisolated static func syntaxCheck(_ url: URL) -> Bool {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/bash")
        check.arguments = ["-n", url.path]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        guard (try? check.run()) != nil else { return false }
        check.waitUntilExit()
        return check.terminationStatus == 0
    }
}

/// 앱이 꺼진 뒤 번들을 새 버전으로 바꾸고 다시 띄우는 분리된 스크립트.
///
/// 실행 중인 앱은 자기 번들을 지울 수 없어서 이 단계만 밖으로 뺀다. 터미널 창은 쓰지 않는다.
public enum UpgradeHandoff {
    public struct Configuration: Sendable {
        public var brew: String
        /// 꺼지기를 기다릴 앱 프로세스
        public var processID: Int32
        public var logURL: URL
        public var applicationsDirectory: String = "/Applications"
        /// 다시 띄우는 명령 (테스트에서 바꿔 끼운다)
        public var opener: String = "/usr/bin/open"
        public var formula: String = Upgrader.formula
        public var appBundleName: String = Upgrader.appBundleName
        public var executableName: String = Upgrader.executableName

        public init(brew: String, processID: Int32, logURL: URL) {
            self.brew = brew
            self.processID = processID
            self.logURL = logURL
        }
    }

    /// `~/Library/Application Support/AgentNotch/upgrade.log`
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentNotch", isDirectory: true)
    }

    public static var defaultLogURL: URL {
        supportDirectory.appendingPathComponent("upgrade.log")
    }

    /// 스크립트를 임시 폴더에 쓰고 분리된 프로세스로 띄운다. 앱이 꺼져도 계속 돈다.
    public static func launch(_ configuration: Configuration) throws {
        let fileManager = FileManager.default
        let logDirectory = configuration.logURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logDirectory.path)

        let scriptURL = fileManager.temporaryDirectory
            .appendingPathComponent("agent-notch-handoff-\(UUID().uuidString).sh")
        try Data(script(configuration).utf8).write(to: scriptURL, options: .withoutOverwriting)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path]
        task.currentDirectoryURL = fileManager.temporaryDirectory
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
    }

    /// 순서: 앱 종료 대기(10초 뒤 종료 신호) → 새 번들 확인(**아무것도 지우기 전에**) → `/Applications` 사본 교체 → `open -n`.
    /// 모든 경로는 작은따옴표로 감싸 넣는다.
    public static func script(_ configuration: Configuration) -> String {
        let quote = Upgrader.shellQuoted
        let brewDirectory = URL(fileURLWithPath: configuration.brew).deletingLastPathComponent().path
        return """
        #!/bin/bash
        # AgentNotch 업데이트 마무리: 앱이 꺼지길 기다렸다가 새 번들로 바꾸고 다시 띄운다.
        export PATH=\(quote(brewDirectory)):/usr/bin:/bin:/usr/sbin:/sbin
        export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1
        trap 'rm -f "$0"' EXIT

        LOG=\(quote(configuration.logURL.path))
        LOG_DIR="$(dirname "$LOG")"
        mkdir -p "$LOG_DIR" && chmod 700 "$LOG_DIR"
        exec >>"$LOG" 2>&1
        echo "=== $(date '+%Y-%m-%d %H:%M:%S') 교체 시작 ==="

        BREW=\(quote(configuration.brew))
        FORMULA=\(quote(configuration.formula))
        APP_NAME=\(quote(configuration.appBundleName))
        EXE_NAME=\(quote(configuration.executableName))
        APPS_DIR=\(quote(configuration.applicationsDirectory))
        OPENER=\(quote(configuration.opener))
        OLD_PID=\(configuration.processID)
        APP="$APPS_DIR/$APP_NAME"

        # 기다리는 프로세스가 아직 우리 앱인지 (PID 가 다른 프로세스에 다시 쓰였으면 건드리지 않는다)
        still_running() {
          ps -p "$OLD_PID" -o comm= 2>/dev/null | grep -qF "$EXE_NAME"
        }

        # 1. 앱이 꺼질 때까지 최대 10초 기다리고, 그래도 살아 있으면 끝낸다
        for _ in $(seq 1 100); do
          still_running || break
          sleep 0.1
        done
        if still_running; then
          echo "10초 안에 꺼지지 않아 종료 신호를 보내요"
          kill "$OLD_PID" 2>/dev/null
          for _ in $(seq 1 50); do
            still_running || break
            sleep 0.1
          done
          still_running && kill -9 "$OLD_PID" 2>/dev/null
          sleep 0.5
        fi

        # 2. 새 번들부터 확인한다. 지운 뒤에 없으면 앱이 통째로 사라진다
        PREFIX="$("$BREW" --prefix "$FORMULA" 2>/dev/null)"
        NEW="$PREFIX/$APP_NAME"
        if [ -z "$PREFIX" ] || [ ! -x "$NEW/Contents/MacOS/$EXE_NAME" ]; then
          echo "새 번들을 찾지 못했어요: $NEW"
          if [ -d "$APP" ]; then "$OPENER" -n "$APP"; fi
          exit 1
        fi

        # 3. /Applications 사본이 있으면 바꾼다 (옆에 먼저 복사해 두고 바꿔서, 복사가 실패해도 원래 앱은 남는다)
        if [ -d "$APP" ]; then
          STAGE="$APPS_DIR/.$APP_NAME.upgrade-$$"
          rm -rf "$STAGE"
          if ! cp -R "$NEW" "$STAGE"; then
            echo "새 번들을 복사하지 못했어요"
            rm -rf "$STAGE"
            "$OPENER" -n "$APP"
            exit 1
          fi
          if ! rm -rf "$APP" || ! mv "$STAGE" "$APP"; then
            echo "기존 앱을 바꾸지 못했어요. Homebrew 쪽 앱을 띄워요"
            rm -rf "$STAGE"
            "$OPENER" -n "$NEW"
            exit 1
          fi
          TARGET="$APP"
        else
          # /Applications 사본이 없으면 Homebrew 쪽 번들을 바로 쓰고 있던 것이다
          TARGET="$NEW"
        fi

        # 4. 다시 띄운다. -n: 방금 끝난 프로세스가 아직 떠 있다고 여겨져도 새로 띄운다
        "$OPENER" -n "$TARGET" || "$OPENER" "$TARGET"
        echo "=== 끝: $TARGET ==="
        """
    }
}
