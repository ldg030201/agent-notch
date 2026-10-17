import Foundation
import Testing
@testable import NotchServices

/// 공백 · 따옴표 · `$` 가 섞인 경로로 스크립트 인용을 검사한다
private let awkwardName = "dir with 'single' \"double\" $HOME `tick`"

private func writeExecutable(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

@discardableResult
private func runBash(_ arguments: [String], environment: [String: String]? = nil) throws -> (status: Int32, output: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = arguments
    if let environment { task.environment = environment }
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    try task.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return (task.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// 이미 끝난 프로세스의 PID (교체 스크립트가 기다릴 대상이 없게)
private func finishedProcessID() throws -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try task.run()
    task.waitUntilExit()
    return task.processIdentifier
}

@Suite("Upgrader scripts")
struct UpgraderScriptTests {
    @Test func shellQuotingRoundTrips() throws {
        let values = ["plain", "with space", "it's", "\"double\"", "$HOME `id` $(id)", "a\nb", awkwardName, ""]
        for value in values {
            let result = try runBash(["-c", "printf '%s' \(Upgrader.shellQuoted(value))"])
            #expect(result.status == 0)
            #expect(result.output == value, "\(value)")
        }
    }

    @Test func generatedScriptsPassSyntaxCheck() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let base = temp.url.appendingPathComponent(awkwardName, isDirectory: true)
        let brew = base.appendingPathComponent("bin/brew").path

        var handoff = UpgradeHandoff.Configuration(
            brew: brew,
            processID: 4242,
            logURL: base.appendingPathComponent("Application Support/AgentNotch/upgrade.log")
        )
        handoff.applicationsDirectory = base.appendingPathComponent("Applications").path
        handoff.opener = base.appendingPathComponent("open it").path

        for (name, script) in [("upgrade", Upgrader.upgradeScript(brew: brew)), ("handoff", UpgradeHandoff.script(handoff))] {
            let url = temp.url.appendingPathComponent("\(name).sh")
            try Data(script.utf8).write(to: url)
            #expect(Upgrader.syntaxCheck(url), "\(name)")
            #expect(script.contains(Upgrader.shellQuoted(brew)))
        }

        let upgrade = Upgrader.upgradeScript(brew: brew)
        #expect(upgrade.contains("--repository 'ldg030201/agent-notch'"))
        #expect(upgrade.contains("upgrade 'agent-notch'"))

        // 지우기 전에 새 번들부터 확인한다
        let script = UpgradeHandoff.script(handoff)
        let verify = try #require(script.range(of: "[ ! -x \"$NEW/Contents/MacOS/$EXE_NAME\" ]"))
        let remove = try #require(script.range(of: "rm -rf \"$APP\""))
        #expect(verify.lowerBound < remove.lowerBound)
        #expect(script.contains("OLD_PID=4242"))
        #expect(script.contains("\"$OPENER\" -n \"$TARGET\""))
    }

    @Test func brokenScriptFailsSyntaxCheck() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let url = temp.url.appendingPathComponent("broken.sh")
        try Data("if then fi (".utf8).write(to: url)
        #expect(!Upgrader.syntaxCheck(url))
    }

    @Test func environmentAddsBrewDirectoryAndQuietFlags() {
        let environment = Upgrader.environment(brew: "/opt/homebrew/bin/brew")
        #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["HOMEBREW_NO_ASK"] == "1")
        #expect(environment["HOMEBREW_NO_ENV_HINTS"] == "1")
        #expect(environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
    }
}

@Suite("Upgrader installed version")
struct UpgraderInstalledVersionTests {
    @Test func comparesInstalledBundleWithRunningVersion() {
        #expect(Upgrader.checkInstalled("0.2.0", current: "0.1.0") == .newer("0.2.0"))
        #expect(Upgrader.checkInstalled("0.1.0.1", current: "0.1.0") == .newer("0.1.0.1"))
        #expect(Upgrader.checkInstalled("0.1.0", current: "0.1.0") == .notNewer("0.1.0"))
        #expect(Upgrader.checkInstalled("0.0.9", current: "0.1.0") == .notNewer("0.0.9"))
        // 읽지 못한 버전은 판단하지 않는다
        #expect(Upgrader.checkInstalled(nil, current: "0.1.0") == .unknown)
        #expect(Upgrader.checkInstalled("garbage", current: "0.1.0") == .unknown)
        // 지금 버전을 모르면 받은 것으로 본다
        #expect(Upgrader.checkInstalled("0.1.0", current: nil) == .newer("0.1.0"))
    }

    @Test func notPublishedMessageNamesVersions() {
        let message = Upgrader.notPublishedMessage(installed: "0.1.0", latest: "0.2.0")
        #expect(message.contains("새 버전 0.2.0 이 아직 Homebrew 에 올라오지 않았어요"))
        #expect(message.contains("0.1.0"))
        #expect(Upgrader.notPublishedMessage(installed: "0.1.0", latest: nil).hasPrefix("새 버전이 아직 Homebrew 에 올라오지 않았어요"))
    }

    @Test func upgradeScriptRecordsInstalledVersion() throws {
        let script = Upgrader.upgradeScript(brew: "/opt/homebrew/bin/brew", versionFile: "/tmp/it's here.version")
        #expect(script.contains("--prefix 'agent-notch'"))
        #expect(script.contains("PlistBuddy -c 'Print :CFBundleShortVersionString'"))
        #expect(script.contains("> '/tmp/it'\\''s here.version'"))
        // brew upgrade 가 실패하면 버전을 적지 않고 끝난다
        let upgrade = try #require(script.range(of: "upgrade 'agent-notch' || exit 1"))
        let record = try #require(script.range(of: "PlistBuddy"))
        #expect(upgrade.lowerBound < record.lowerBound)
    }
}

/// brew 위치 찾기 (가짜 셸로만 돌린다)
@Suite("Upgrader brew lookup")
struct UpgraderBrewLookupTests {
    private func ask(shell: String, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            Upgrader.askLoginShell(shell: shell, timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    @Test func knownLocationsComeFirstWithoutDuplicates() {
        let locations = Upgrader.knownBrewLocations(
            environment: ["HOMEBREW_PREFIX": "/custom", "PATH": "/a/bin:/opt/homebrew/bin:relative/bin"],
            home: "/Users/dev"
        )
        #expect(locations.first == "/custom/bin/brew")
        #expect(locations.contains("/opt/homebrew/bin/brew"))
        #expect(locations.contains("/usr/local/bin/brew"))
        #expect(locations.contains("/Users/dev/homebrew/bin/brew"))
        #expect(locations.contains("/a/bin/brew"))
        #expect(!locations.contains("relative/bin/brew"))
        #expect(locations.filter { $0 == "/opt/homebrew/bin/brew" }.count == 1)
    }

    @Test func asksUsersLoginShellNotBash() {
        #expect(Upgrader.loginShell(environment: ["SHELL": "/bin/zsh"]) == "/bin/zsh")
        #expect(Upgrader.loginShell(environment: ["SHELL": "/bin/bash"]) == "/bin/bash")
        // 모르는 셸 · 상대 경로는 zsh 로 묻는다
        #expect(Upgrader.loginShell(environment: ["SHELL": "/usr/local/bin/nu"]) == "/bin/zsh")
        #expect(Upgrader.loginShell(environment: ["SHELL": "zsh"]) == "/bin/zsh")
    }

    @Test func picksExecutableAbsolutePathFromNoisyOutput() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let brew = temp.url.appendingPathComponent("bin/brew")
        try writeExecutable("#!/bin/bash\n", to: brew)
        let output = "프로필 인사말\n/not/a/real/brew\n\(brew.path)\n"
        #expect(Upgrader.parseBrewLookup(Data(output.utf8)) == brew.path)
        #expect(Upgrader.parseBrewLookup(Data("brew: aliased to /x/brew\nbrew\n".utf8)) == nil)
        #expect(Upgrader.parseBrewLookup(Data()) == nil)
    }

    /// 프로필이 띄운 백그라운드 프로세스가 출력을 물고 있어도 셸이 끝나면 바로 답한다 (파이프였다면 EOF 를 영영 기다림)
    @Test func doesNotWaitForBackgroundProcessHoldingOutput() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let brew = temp.url.appendingPathComponent("bin/brew")
        try writeExecutable("#!/bin/bash\n", to: brew)
        let shell = temp.url.appendingPathComponent("fake shell")
        try writeExecutable("""
        #!/bin/bash
        ( sleep 4 ) &
        echo "프로필이 찍은 줄"
        echo \(Upgrader.shellQuoted(brew.path))
        """, to: shell)
        let began = Date()
        let found = await ask(shell: shell.path, timeout: 10)
        #expect(found == brew.path)
        #expect(Date().timeIntervalSince(began) < 3)
    }

    @Test func hungShellTimesOut() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let shell = temp.url.appendingPathComponent("hung shell")
        try writeExecutable("#!/bin/bash\nsleep 30\n", to: shell)
        let began = Date()
        let found = await ask(shell: shell.path, timeout: 0.5)
        #expect(found == nil)
        #expect(Date().timeIntervalSince(began) < 5)
    }
}

/// 가짜 brew · 가짜 /Applications 로 교체 스크립트를 실제로 돌려 본다 (진짜 /Applications 와 open 은 쓰지 않음)
@Suite("UpgradeHandoff")
struct UpgradeHandoffTests {
    private struct Fixture {
        let temp: TempDirectory
        let base: URL
        let applications: URL
        let cellarApp: URL
        let openLog: URL
        let configuration: UpgradeHandoff.Configuration

        init(withNewBundle: Bool, withInstalledCopy: Bool = true) throws {
            temp = try TempDirectory()
            base = temp.url.appendingPathComponent(awkwardName, isDirectory: true)
            applications = base.appendingPathComponent("Applications", isDirectory: true)
            let prefix = base.appendingPathComponent("Cellar/agent-notch/0.2.0", isDirectory: true)
            cellarApp = prefix.appendingPathComponent("AgentNotch.app", isDirectory: true)
            openLog = base.appendingPathComponent("opened.txt")

            // brew --prefix agent-notch 에 답하는 가짜 brew
            let brew = base.appendingPathComponent("bin/brew")
            try writeExecutable("""
            #!/bin/bash
            if [ "$1" = "--prefix" ] && [ "$2" = "agent-notch" ]; then
              printf '%s\\n' \(Upgrader.shellQuoted(prefix.path))
            fi
            """, to: brew)
            // open 대신 받은 인자를 기록한다
            let opener = base.appendingPathComponent("bin/fake open")
            try writeExecutable("""
            #!/bin/bash
            printf '%s\\n' "$@" >> \(Upgrader.shellQuoted(openLog.path))
            """, to: opener)

            if withNewBundle {
                try writeExecutable("#!/bin/bash\necho new\n", to: cellarApp.appendingPathComponent("Contents/MacOS/AgentNotch"))
                try Data("new".utf8).write(to: cellarApp.appendingPathComponent("Contents/marker"))
            }
            if withInstalledCopy {
                let installed = applications.appendingPathComponent("AgentNotch.app", isDirectory: true)
                try writeExecutable("#!/bin/bash\necho old\n", to: installed.appendingPathComponent("Contents/MacOS/AgentNotch"))
                try Data("old".utf8).write(to: installed.appendingPathComponent("Contents/marker"))
            } else {
                try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
            }

            var configuration = UpgradeHandoff.Configuration(
                brew: brew.path,
                processID: try finishedProcessID(),
                logURL: base.appendingPathComponent("support dir/upgrade.log")
            )
            configuration.applicationsDirectory = applications.path
            configuration.opener = opener.path
            self.configuration = configuration
        }

        var installedApp: URL { applications.appendingPathComponent("AgentNotch.app", isDirectory: true) }

        func run() throws -> Int32 {
            let script = temp.url.appendingPathComponent("handoff.sh")
            try Data(UpgradeHandoff.script(configuration).utf8).write(to: script)
            let result = try runBash([script.path], environment: ["PATH": "/usr/bin:/bin"])
            // 스크립트는 끝날 때 자기 자신을 지운다
            #expect(!FileManager.default.fileExists(atPath: script.path))
            return result.status
        }

        func marker(_ app: URL) -> String? {
            (try? Data(contentsOf: app.appendingPathComponent("Contents/marker"))).map { String(decoding: $0, as: UTF8.self) }
        }

        func opened() -> [String] {
            let text = (try? String(contentsOf: openLog, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map(String.init)
        }

        func log() -> String {
            (try? String(contentsOf: configuration.logURL, encoding: .utf8)) ?? ""
        }
    }

    @Test func replacesInstalledCopyAndRelaunches() throws {
        let fixture = try Fixture(withNewBundle: true)
        defer { fixture.temp.remove() }
        #expect(try fixture.run() == 0)
        #expect(fixture.marker(fixture.installedApp) == "new")
        #expect(fixture.opened() == ["-n", fixture.installedApp.path])
        // 옆에 만든 임시 사본이 남지 않는다
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.applications.path)
        #expect(leftovers == ["AgentNotch.app"])
        #expect(fixture.log().contains("교체 시작"))
        #expect(posixPermissions(fixture.configuration.logURL.deletingLastPathComponent().path) == 0o700)
    }

    @Test func missingNewBundleLeavesOldAppUntouched() throws {
        let fixture = try Fixture(withNewBundle: false)
        defer { fixture.temp.remove() }
        #expect(try fixture.run() == 1)
        #expect(fixture.marker(fixture.installedApp) == "old")
        // 원래 앱을 다시 띄운다
        #expect(fixture.opened() == ["-n", fixture.installedApp.path])
        #expect(fixture.log().contains("새 번들을 찾지 못했어요"))
    }

    @Test func opensHomebrewCopyWhenNotCopiedToApplications() throws {
        let fixture = try Fixture(withNewBundle: true, withInstalledCopy: false)
        defer { fixture.temp.remove() }
        #expect(try fixture.run() == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.installedApp.path))
        #expect(fixture.opened() == ["-n", fixture.cellarApp.path])
    }
}

/// 가짜 brew 로 `Upgrader` 의 실행 · 로그 · 단계 전환을 확인한다
@MainActor
@Suite("Upgrader")
struct UpgraderTests {
    /// 가짜 brew 가 기다리는 문. 기다리기 시작할 때마다 한 줄 적고(`started`), `open()` 하면 지나간다
    private struct Gate {
        let startedFile: URL
        let openFile: URL

        init(_ temp: TempDirectory) {
            startedFile = temp.url.appendingPathComponent("gate-started")
            openFile = temp.url.appendingPathComponent("gate-open")
        }

        /// 가짜 brew 스크립트에 넣는 셸 명령
        var waitCommand: String {
            "echo . >> \(Upgrader.shellQuoted(startedFile.path)); "
                + "while [ ! -e \(Upgrader.shellQuoted(openFile.path)) ]; do sleep 0.05; done"
        }

        /// 문 앞까지 온 횟수
        var started: Int {
            ((try? String(contentsOf: startedFile, encoding: .utf8)) ?? "").split(separator: "\n").count
        }

        func open() throws {
            try Data().write(to: openFile)
        }
    }

    private func makeFakeBrew(_ body: String) throws -> (TempDirectory, String) {
        let temp = try TempDirectory()
        let brew = temp.url.appendingPathComponent("\(awkwardName)/brew")
        try writeExecutable("#!/bin/bash\n\(body)\n", to: brew)
        return (temp, brew.path)
    }

    @Test func runsBrewAndWaitsForRelaunch() async throws {
        let (temp, brew) = try makeFakeBrew("""
        echo "fake brew $*"
        echo "경고 한 줄" >&2
        """)
        defer { temp.remove() }
        let upgrader = Upgrader(isTestBuild: false, isAppBundle: true, resolveBrew: { brew }, terminate: {})
        upgrader.start()
        #expect(upgrader.phase == .running)
        let done = await waitUntil(timeout: 10) { upgrader.phase != .running }
        #expect(done)
        #expect(upgrader.phase == .ready)
        // tap 이 git 저장소가 아니면 brew update 로 넘어간 뒤 upgrade
        #expect(upgrader.log.contains("brew update 를 실행해요"))
        #expect(upgrader.log.contains("fake brew update"))
        #expect(upgrader.log.contains("fake brew upgrade agent-notch"))
        #expect(upgrader.log.contains("경고 한 줄"))
        upgrader.dismiss()
        #expect(upgrader.phase == .idle)
    }

    @Test func reportsFailureExitCode() async throws {
        let (temp, brew) = try makeFakeBrew("""
        if [ "$1" = "upgrade" ]; then echo "Error: 빌드 실패"; exit 3; fi
        """)
        defer { temp.remove() }
        let upgrader = Upgrader(isTestBuild: false, isAppBundle: true, resolveBrew: { brew }, terminate: {})
        upgrader.start()
        let done = await waitUntil(timeout: 10) { upgrader.phase != .running }
        #expect(done)
        guard case .failed(let reason) = upgrader.phase else {
            Issue.record("실패 단계가 아님: \(upgrader.phase)")
            return
        }
        #expect(reason.contains("종료 코드 1"))
        #expect(upgrader.log.contains("Error: 빌드 실패"))
    }

    @Test func cancelStopsRunningBrew() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let gate = Gate(temp)
        let marker = temp.url.appendingPathComponent("finished")
        let brew = temp.url.appendingPathComponent("brew")
        // brew upgrade 는 시작을 알리고 문이 열릴 때까지 기다렸다가 표시 파일을 만든다 (시간에 기대지 않게)
        try writeExecutable("""
        #!/bin/bash
        if [ "$1" = "upgrade" ]; then \(gate.waitCommand); touch \(Upgrader.shellQuoted(marker.path)); fi
        """, to: brew)
        let upgrader = Upgrader(isTestBuild: false, isAppBundle: true, resolveBrew: { brew.path }, terminate: {})
        upgrader.start()
        #expect(await waitUntil(timeout: 10) { gate.started == 1 })
        upgrader.cancel()
        #expect(upgrader.phase == .idle)
        // 문을 열어도 자식(가짜 brew)까지 끝나 있어서 표시 파일이 생기지 않는다
        try gate.open()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(upgrader.phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func refusesTestBuildsAndMissingBrew() async {
        let test = Upgrader(isTestBuild: true, isAppBundle: true, resolveBrew: { "/opt/homebrew/bin/brew" }, terminate: {})
        test.start()
        #expect(test.phase == .failed("테스트판은 자체 업데이트를 하지 않아요."))

        let unbundled = Upgrader(isTestBuild: false, isAppBundle: false, resolveBrew: { "/opt/homebrew/bin/brew" }, terminate: {})
        unbundled.start()
        #expect(unbundled.phase == .failed("앱 번들로 실행할 때만 업데이트할 수 있어요."))

        let noBrew = Upgrader(isTestBuild: false, isAppBundle: true, resolveBrew: { nil }, terminate: {})
        noBrew.start()
        #expect(await waitUntil { noBrew.phase != .running })
        guard case .failed(let reason) = noBrew.phase else {
            Issue.record("실패 단계가 아님")
            return
        }
        #expect(reason.contains("Homebrew"))
        // relaunch 는 ready 단계에서만 동작한다
        noBrew.relaunch()
        #expect(noBrew.phase == .failed(reason))

        // "닫기" 는 단계를 처음으로 돌려서, 다시 눌렀을 때 같은 실패가 또 보이게 한다
        noBrew.dismiss()
        #expect(noBrew.phase == .idle)
        noBrew.start()
        #expect(noBrew.phase == .running)
        #expect(await waitUntil { noBrew.phase != .running })
        #expect(noBrew.phase == .failed(reason))
    }

    /// brew 를 찾는 동안(로그인 셸에 묻는 중) `start()` 는 메인을 막지 않는다
    @Test func startDoesNotBlockWhileFindingBrew() async throws {
        let (temp, brew) = try makeFakeBrew("echo \"fake brew $*\"")
        defer { temp.remove() }
        let lookedUpOnMain = LockedFlag()
        let upgrader = Upgrader(isTestBuild: false, isAppBundle: true, resolveBrew: {
            lookedUpOnMain.set(pthread_main_np() != 0)
            usleep(500_000)
            return brew
        }, terminate: {})
        let began = Date()
        upgrader.start()
        #expect(Date().timeIntervalSince(began) < 0.3)
        #expect(upgrader.phase == .running)
        #expect(upgrader.log.contains("Homebrew 를 찾는 중"))
        #expect(await waitUntil(timeout: 10) { upgrader.phase != .running })
        #expect(upgrader.phase == .ready)
        #expect(lookedUpOnMain.get() == false)
    }

    @Test func cancelWhileFindingBrewDropsTheLookup() async throws {
        let (temp, brew) = try makeFakeBrew("echo \"fake brew $*\"")
        defer { temp.remove() }
        let upgrader = Upgrader(isTestBuild: false, isAppBundle: true, resolveBrew: {
            usleep(300_000)
            return brew
        }, terminate: {})
        upgrader.start()
        upgrader.cancel()
        #expect(upgrader.phase == .idle)
        try await Task.sleep(nanoseconds: 800_000_000)
        // 늦게 찾은 brew 로 실행을 시작하지 않는다
        #expect(upgrader.phase == .idle)
        #expect(!upgrader.log.contains("fake brew"))
    }

    /// 취소한 실행의 늦은 종료 알림이 바로 다시 시작한 실행을 끝내지 않는다
    /// (예전엔 프로세스 주소로 가려서, 새 Process 가 같은 주소를 쓰면 새 실행이 취소도 안 되고 끝나지도 않았다)
    @Test func staleTerminationDoesNotFinishNextRun() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let gate = Gate(temp)
        // brew upgrade 는 문이 열릴 때까지 끝나지 않는다: 취소 전에 실행이 저절로 끝나는 일이 없다 (느린 CI 에서도)
        let (brewTemp, brew) = try makeFakeBrew("""
        if [ "$1" = "upgrade" ]; then \(gate.waitCommand); fi
        echo "fake brew $*"
        """)
        defer { brewTemp.remove() }
        let upgrader = Upgrader(isTestBuild: false, isAppBundle: true, resolveBrew: { brew }, terminate: {})
        for round in 1...3 {
            upgrader.start()
            #expect(await waitUntil(timeout: 10) { gate.started == round })
            upgrader.cancel()
            #expect(upgrader.phase == .idle)
        }
        upgrader.start()
        #expect(await waitUntil(timeout: 10) { gate.started == 4 })
        // 취소한 실행들의 종료 처리(0.3초 뒤)가 지나도 새 실행은 그대로 돈다
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(upgrader.phase == .running)
        try gate.open()
        #expect(await waitUntil(timeout: 10) { upgrader.phase != .running })
        #expect(upgrader.phase == .ready)
    }

    /// 가짜 Homebrew 접두사에 주어진 버전의 번들을 만들고 `brew --prefix` 에 답하는 가짜 brew
    private func makeBrewWithInstalledApp(version: String?) throws -> (TempDirectory, String) {
        let temp = try TempDirectory()
        let prefix = temp.url.appendingPathComponent("\(awkwardName)/opt/agent-notch", isDirectory: true)
        let contents = prefix.appendingPathComponent("AgentNotch.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if let version {
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleShortVersionString": version],
                format: .xml,
                options: 0
            )
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
        }
        let brew = temp.url.appendingPathComponent("bin/brew")
        try writeExecutable("""
        #!/bin/bash
        if [ "$1" = "--prefix" ]; then printf '%s\\n' \(Upgrader.shellQuoted(prefix.path)); exit 0; fi
        if [ "$1" = "upgrade" ]; then echo "Warning: agent-notch is already installed"; exit 0; fi
        echo "fake brew $*"
        """, to: brew)
        return (temp, brew.path)
    }

    /// formula 가 아직 안 올라와 brew 가 "already installed" 로 0 을 내면 다 받았다고 하지 않는다
    @Test func exitZeroWithoutNewerBundleFails() async throws {
        let (temp, brew) = try makeBrewWithInstalledApp(version: "0.2.0")
        defer { temp.remove() }
        let upgrader = Upgrader(
            isTestBuild: false, isAppBundle: true, currentVersion: "0.2.0", resolveBrew: { brew }, terminate: {}
        )
        upgrader.start(latestVersion: "0.3.0")
        #expect(await waitUntil(timeout: 10) { upgrader.phase != .running })
        #expect(upgrader.phase == .failed(Upgrader.notPublishedMessage(installed: "0.2.0", latest: "0.3.0")))
        #expect(upgrader.log.contains("Homebrew 에 있는 버전: 0.2.0"))
        // 교체로 넘어가지 않는다
        upgrader.relaunch()
        #expect(upgrader.phase != .swapping)
    }

    /// 터미널에서 이미 받아 둔 경우: brew 는 0 을 내고, 설치된 번들이 지금보다 새 버전이라 다시 띄울 수 있다
    @Test func exitZeroWithNewerBundleIsReady() async throws {
        let (temp, brew) = try makeBrewWithInstalledApp(version: "0.2.1")
        defer { temp.remove() }
        let upgrader = Upgrader(
            isTestBuild: false, isAppBundle: true, currentVersion: "0.2.0", resolveBrew: { brew }, terminate: {}
        )
        upgrader.start(latestVersion: "0.3.0")
        #expect(await waitUntil(timeout: 10) { upgrader.phase != .running })
        #expect(upgrader.phase == .ready)
        // 최신보다는 낮은 버전을 받았다고 알려 준다
        #expect(upgrader.log.contains("최신 버전은 0.3.0 인데 Homebrew 에는 아직 0.2.1 까지만 있어요"))
    }

    /// 번들 버전을 못 읽으면 예전처럼 종료 코드를 믿는다
    @Test func unreadableBundleVersionKeepsExitCodeVerdict() async throws {
        let (temp, brew) = try makeBrewWithInstalledApp(version: nil)
        defer { temp.remove() }
        let upgrader = Upgrader(
            isTestBuild: false, isAppBundle: true, currentVersion: "0.2.0", resolveBrew: { brew }, terminate: {}
        )
        upgrader.start(latestVersion: "0.3.0")
        #expect(await waitUntil(timeout: 10) { upgrader.phase != .running })
        #expect(upgrader.phase == .ready)
    }

    @Test func detectsLegacyHomebrewServicesPlist() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let item = MainAppLoginItem(launchAgentsDirectory: temp.url)
        #expect(!item.isManagedByHomebrewServices)
        FileManager.default.createFile(
            atPath: temp.url.appendingPathComponent(MainAppLoginItem.legacyHomebrewPlistName).path,
            contents: Data()
        )
        #expect(item.isManagedByHomebrewServices)
    }
}

/// 다른 스레드에서 적는 참/거짓 (테스트 기록용)
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    func get() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
