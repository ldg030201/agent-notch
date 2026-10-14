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
    /// 지금 실행 중인 버전. brew 가 받은 번들이 이보다 새 버전인지 확인한다 (nil 이면 확인하지 않음)
    @ObservationIgnored private let currentVersion: String?
    @ObservationIgnored private let resolveBrew: @Sendable () async -> String?
    @ObservationIgnored private let terminate: @MainActor () -> Void
    @ObservationIgnored private var process: Process?
    /// 실행마다 하나씩 늘리는 번호. 끝난 뒤 늦게 오는 종료 알림이 어느 실행 것인지 가린다
    /// (프로세스 주소로 가리면 취소 뒤 새 Process 가 같은 주소를 다시 쓸 수 있다)
    @ObservationIgnored private var runCounter = 0
    /// 진행 중인 실행 번호 (brew 찾기 포함). 취소 · 종료되면 nil
    @ObservationIgnored private var activeRun: Int?
    /// 이번 실행에서 알고 있던 최신 버전 (안내 문구용)
    @ObservationIgnored private var expectedVersion: String?
    /// 받기 스크립트가 받은 번들의 버전을 적는 임시 파일
    @ObservationIgnored private var versionFile: URL?
    /// `.ready` 동안 교체에 쓸 brew 경로
    @ObservationIgnored private var readyBrew: String?

    public init(
        isTestBuild: Bool,
        isAppBundle: Bool = Bundle.main.bundleURL.pathExtension == "app",
        currentVersion: String? = nil,
        resolveBrew: @escaping @Sendable () async -> String? = { await Upgrader.resolveBrew() },
        terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }
    ) {
        self.isTestBuild = isTestBuild
        self.isAppBundle = isAppBundle
        self.currentVersion = currentVersion
        self.resolveBrew = resolveBrew
        self.terminate = terminate
    }

    // MARK: - 받기

    /// 받기 시작. brew 위치는 메인 밖에서 찾고(로그인 셸에 물을 수 있음), 그동안 단계는 `.running` 이다.
    /// `latestVersion`: 새 버전 확인에서 본 최신 버전 (받은 번들이 새 버전이 아닐 때 안내에 쓴다)
    public func start(latestVersion: String? = nil) {
        guard !isBusy else { return }
        guard !isTestBuild else {
            phase = .failed("테스트판은 자체 업데이트를 하지 않아요.")
            return
        }
        guard isAppBundle else {
            phase = .failed("앱 번들로 실행할 때만 업데이트할 수 있어요.")
            return
        }
        log = ""
        readyBrew = nil
        expectedVersion = latestVersion
        runCounter += 1
        let token = runCounter
        activeRun = token
        phase = .running
        append("Homebrew 를 찾는 중…\n")

        let resolve = resolveBrew
        Task { [weak self] in
            let brew = await resolve()
            // 그사이 취소됐거나 다른 실행이 시작됐으면 버린다
            guard let self, self.activeRun == token, self.phase == .running else { return }
            guard let brew else {
                self.activeRun = nil
                self.phase = .failed("Homebrew 를 찾지 못했어요. 터미널에서 brew upgrade \(Self.formula) 를 직접 실행해 주세요.")
                return
            }
            self.run(brew: brew, token: token)
        }
    }

    /// 진행 중이면 멈춘다. Homebrew 는 중간에 끊겨도 다음 번에 이어서 한다.
    public func cancel() {
        activeRun = nil
        let running = process
        process = nil
        if let running, running.isRunning {
            // bash 만 끝내면 그 밑의 brew 가 남는다. 직접 띄운 자식부터 끝낸다.
            Self.terminateChildren(of: running.processIdentifier)
            running.terminate()
        }
        removeVersionFile()
        if phase == .running {
            phase = .idle
        }
    }

    /// 실패 · 준비 화면을 닫는다. 다음 실행 결과가 같은 문구여도 다시 보이게 단계를 처음으로 돌린다.
    public func dismiss() {
        guard !isBusy else { return }
        phase = .idle
    }

    private func run(brew: String, token: Int) {
        let versionFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notch-upgrade-\(UUID().uuidString).version")
        self.versionFile = versionFile

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", Self.upgradeScript(brew: brew, versionFile: versionFile.path)]
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
            let status = finished.terminationStatus
            // 마지막 출력이 전달될 틈을 잠깐 준다. EOF 를 기다리지 않는 이유: brew 가 띄운 다른 프로세스가
            // 파이프를 물고 있으면 EOF 가 오지 않아 끝나지 않는다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                reader.readabilityHandler = nil
                MainActor.assumeIsolated {
                    self?.finish(token: token, status: status, brew: brew)
                }
            }
        }

        do {
            try task.run()
            process = task
        } catch {
            reader.readabilityHandler = nil
            activeRun = nil
            removeVersionFile()
            phase = .failed("brew 를 실행하지 못했어요: \(error.localizedDescription)")
        }
    }

    private func append(_ text: String) {
        log += text
        if log.count > Self.logLimit {
            log = String(log.suffix(Self.logLimit))
        }
    }

    private func finish(token: Int, status: Int32, brew: String) {
        // 취소된 실행(또는 이전 실행)의 종료는 무시한다
        guard activeRun == token else { return }
        activeRun = nil
        process = nil
        let installed = readInstalledVersion()
        guard phase == .running else { return }
        guard status == 0 else {
            phase = .failed("업데이트가 끝나지 않았어요 (종료 코드 \(status)). 아래 로그를 확인해 주세요.")
            return
        }
        // brew 는 formula 가 아직 새 버전이 아니어도 "already installed" 만 찍고 0 으로 끝난다.
        // 이미 터미널에서 받아 둔 경우(설치된 번들이 지금보다 새 버전)만 0 을 그대로 믿는다
        switch Self.checkInstalled(installed, current: currentVersion) {
        case .notNewer(let installed):
            phase = .failed(Self.notPublishedMessage(installed: installed, latest: expectedVersion))
            return
        case .newer(let installed):
            if let expected = expectedVersion.flatMap(AppVersion.init), let got = AppVersion(installed), got < expected {
                append("\n최신 버전은 \(expected) 인데 Homebrew 에는 아직 \(installed) 까지만 있어요.\n")
            }
        case .unknown:
            break
        }
        readyBrew = brew
        phase = .ready
        append("\n새 버전을 받았어요. 다시 띄우면 끝나요.\n")
    }

    /// 받기 스크립트가 적어 둔 번들 버전을 읽고 파일을 지운다
    private func readInstalledVersion() -> String? {
        guard let versionFile else { return nil }
        let text = (try? String(contentsOf: versionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        removeVersionFile()
        return text?.isEmpty == false ? text : nil
    }

    private func removeVersionFile() {
        guard let versionFile else { return }
        try? FileManager.default.removeItem(at: versionFile)
        self.versionFile = nil
    }

    // MARK: - 받은 버전 확인

    enum InstalledCheck: Equatable, Sendable {
        /// 지금보다 새 버전을 받았다 (또는 지금 버전을 모름)
        case newer(String)
        /// 받은(설치된) 번들이 지금 버전보다 새롭지 않다 — formula 가 아직 안 올라옴
        case notNewer(String)
        /// 받은 번들의 버전을 읽지 못함 (예전처럼 종료 코드를 믿는다)
        case unknown
    }

    nonisolated static func checkInstalled(_ installed: String?, current: String?) -> InstalledCheck {
        guard let installed, let installedVersion = AppVersion(installed) else { return .unknown }
        guard let current, let currentVersion = AppVersion(current) else { return .newer(installed) }
        return currentVersion < installedVersion ? .newer(installed) : .notNewer(installed)
    }

    nonisolated static func notPublishedMessage(installed: String, latest: String?) -> String {
        let subject = latest.map { "새 버전 \($0) 이" } ?? "새 버전이"
        return "\(subject) 아직 Homebrew 에 올라오지 않았어요 (Homebrew 에 있는 버전 \(installed)). 잠시 뒤 다시 해 보세요."
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
    ///
    /// 끝나면 Homebrew 쪽 번들의 버전을 `versionFile` 에 적는다. formula 가 아직 새 버전이 아니면 brew 는
    /// "already installed" 만 찍고 0 으로 끝나서, 종료 코드만으로는 새 버전을 받았는지 알 수 없다.
    public nonisolated static func upgradeScript(brew: String, versionFile: String? = nil) -> String {
        let record = versionFile.map { "printf '%s\\n' \"$INSTALLED\" > \(shellQuoted($0))" } ?? ":"
        return """
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

        # 받은 번들의 버전을 앱에 알린다 (읽지 못하면 적지 않는다)
        PREFIX="$("$BREW" --prefix \(shellQuoted(formula)) 2>/dev/null)"
        PLIST="$PREFIX/\(appBundleName)/Contents/Info.plist"
        INSTALLED=""
        if [ -n "$PREFIX" ] && [ -f "$PLIST" ]; then
          INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null)"
        fi
        if [ -n "$INSTALLED" ]; then
          echo "Homebrew 에 있는 버전: $INSTALLED"
          \(record)
        fi
        exit 0
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

    /// 로그인 셸에 물을 때 기다리는 최대 시간 (초). 넘기면 셸을 끝내고 못 찾은 것으로 본다
    public nonisolated static let shellLookupTimeout: TimeInterval = 8

    /// 알려진 위치를 먼저 보고, 없으면 로그인 셸에 물어본다. 메인을 막지 않는다.
    public nonisolated static func resolveBrew(timeout: TimeInterval = shellLookupTimeout) async -> String? {
        if let found = findKnownBrew() { return found }
        return await withCheckedContinuation { continuation in
            askLoginShell(shell: loginShell(), timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    /// 동기 버전 (`--probe-upgrade` 같은 명령줄 전용). **앱 메인 스레드에서 부르지 않는다**
    public nonisolated static func resolveBrewBlocking(timeout: TimeInterval = shellLookupTimeout) -> String? {
        if let found = findKnownBrew() { return found }
        let result = LookupResult()
        let done = DispatchSemaphore(value: 0)
        askLoginShell(shell: loginShell(), timeout: timeout) { path in
            result.value = path
            done.signal()
        }
        done.wait()
        return result.value
    }

    /// 알려진 위치 중 실행할 수 있는 첫 brew
    nonisolated static func findKnownBrew(fileManager: FileManager = .default) -> String? {
        knownBrewLocations().first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// brew 가 흔히 있는 곳 (순서대로 본다). 앱에는 로그인 셸의 PATH 가 없어서 셸에 묻기 전에 직접 본다.
    nonisolated static func knownBrewLocations(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String] {
        var candidates: [String] = []
        if let prefix = environment["HOMEBREW_PREFIX"], prefix.hasPrefix("/") {
            candidates.append("\(prefix)/bin/brew")
        }
        candidates += [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew",
            "/usr/local/Homebrew/bin/brew",
            "\(home)/homebrew/bin/brew",
            "\(home)/.homebrew/bin/brew",
            "\(home)/.linuxbrew/bin/brew",
        ]
        // 터미널에서 띄웠으면 그 PATH 도 본다
        for directory in (environment["PATH"] ?? "").split(separator: ":") where directory.hasPrefix("/") {
            candidates.append("\(directory)/brew")
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// `command -v brew` 를 물을 셸: 사용자 로그인 셸(`$SHELL`)이 아는 셸이면 그것, 아니면 zsh (macOS 기본).
    /// bash 로 물으면 zsh 사용자의 `~/.zprofile` (Homebrew 설치 안내가 PATH 를 넣는 곳)을 읽지 않는다.
    nonisolated static func loginShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let supported: Set<String> = ["zsh", "bash", "sh", "ksh", "dash", "fish"]
        // Finder 로 띄운 앱에 SHELL 이 없으면 계정에 적힌 로그인 셸을 본다
        let candidate = environment["SHELL"] ?? getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) }
        if let shell = candidate, shell.hasPrefix("/"),
           supported.contains((shell as NSString).lastPathComponent),
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }

    /// 로그인 셸(`-l`: zsh 는 ~/.zprofile, bash 는 ~/.bash_profile)에 `command -v brew` 를 묻는다. 결과는 아무 큐에서나 온다.
    ///
    /// 출력은 파이프가 아닌 임시 파일로 받는다. 프로필이 띄운 백그라운드 프로세스가 출력을 물고 있으면 파이프는 EOF 가
    /// 오지 않아 영영 끝나지 않는다. 셸이 `timeout` 안에 끝나지 않으면 끝내고, 그때까지 적힌 것만 본다.
    nonisolated static func askLoginShell(
        shell: String,
        timeout: TimeInterval,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        let fileManager = FileManager.default
        let output = fileManager.temporaryDirectory.appendingPathComponent("agent-notch-brew-\(UUID().uuidString).txt")
        guard fileManager.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: output) else {
            completion(nil)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: shell)
        task.arguments = ["-l", "-c", "command -v brew"]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = handle
        task.standardError = FileHandle.nullDevice
        task.currentDirectoryURL = fileManager.homeDirectoryForCurrentUser

        let once = LookupOnce()
        let finish: @Sendable (_ timedOut: Bool) -> Void = { timedOut in
            guard once.claim() else { return }
            // 시간 초과로 끝낸 셸의 늦은 종료 알림은 받지 않는다 (핸들러가 task 를 붙잡는 순환도 끊는다)
            task.terminationHandler = nil
            if timedOut, task.isRunning {
                terminateChildren(of: task.processIdentifier)
                task.terminate()
            }
            let data = (try? Data(contentsOf: output)) ?? Data()
            try? FileManager.default.removeItem(at: output)
            completion(parseBrewLookup(data))
        }
        task.terminationHandler = { _ in finish(false) }
        do {
            try task.run()
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: output)
            completion(nil)
            return
        }
        // 셸이 자기 사본을 가졌으니 우리 쪽은 닫는다
        try? handle.close()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { finish(true) }
    }

    /// 셸 출력에서 brew 경로를 고른다. 프로필이 찍은 다른 줄 · 별칭 · 함수 이름은 버리고, 실행할 수 있는 절대 경로만 받는다
    nonisolated static func parseBrewLookup(_ data: Data, fileManager: FileManager = .default) -> String? {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && fileManager.isExecutableFile(atPath: $0) }
    }

    // MARK: - 점검 (`--probe-upgrade`)

    /// 실제로 돌리지 않고 brew 위치와 두 스크립트의 문법(`bash -n`)만 확인한다. 성공하면 true.
    public nonisolated static func probe(output: (String) -> Void = { print($0) }) -> Bool {
        let brew = resolveBrewBlocking()
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

/// 셸 조회가 끝남(종료 · 시간 초과) 중 먼저 온 쪽만 처리하게 한다
private final class LookupOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// `resolveBrewBlocking` 이 결과를 넘겨받는 상자 (세마포어로 순서를 맞춘다)
private final class LookupResult: @unchecked Sendable {
    var value: String?
}
