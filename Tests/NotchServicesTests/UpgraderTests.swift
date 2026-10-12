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
        let marker = temp.url.appendingPathComponent("finished")
        let brew = temp.url.appendingPathComponent("brew")
        try writeExecutable("""
        #!/bin/bash
        if [ "$1" = "upgrade" ]; then sleep 2; touch \(Upgrader.shellQuoted(marker.path)); fi
        """, to: brew)
        let upgrader = Upgrader(isTestBuild: false, isAppBundle: true, resolveBrew: { brew.path }, terminate: {})
        upgrader.start()
        _ = await waitUntil(timeout: 5) { upgrader.log.contains("brew update") }
        try await Task.sleep(nanoseconds: 300_000_000)
        upgrader.cancel()
        #expect(upgrader.phase == .idle)
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(upgrader.phase == .idle)
        // 자식(가짜 brew)까지 끝나서 표시 파일이 생기지 않는다
        try await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func refusesTestBuildsAndMissingBrew() {
        let test = Upgrader(isTestBuild: true, isAppBundle: true, resolveBrew: { "/opt/homebrew/bin/brew" }, terminate: {})
        test.start()
        #expect(test.phase == .failed("테스트판은 자체 업데이트를 하지 않아요."))

        let unbundled = Upgrader(isTestBuild: false, isAppBundle: false, resolveBrew: { "/opt/homebrew/bin/brew" }, terminate: {})
        unbundled.start()
        #expect(unbundled.phase == .failed("앱 번들로 실행할 때만 업데이트할 수 있어요."))

        let noBrew = Upgrader(isTestBuild: false, isAppBundle: true, resolveBrew: { nil }, terminate: {})
        noBrew.start()
        guard case .failed(let reason) = noBrew.phase else {
            Issue.record("실패 단계가 아님")
            return
        }
        #expect(reason.contains("Homebrew"))
        // relaunch 는 ready 단계에서만 동작한다
        noBrew.relaunch()
        #expect(noBrew.phase == .failed(reason))
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
