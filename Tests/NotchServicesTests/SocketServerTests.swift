import Darwin
import Foundation
import NotchShared
import Testing
@testable import NotchServices

/// 콜백 기록용
@MainActor
final class SocketRecorder {
    var envelopes: [HookEnvelope] = []
    var cancelled: [UUID] = []
    var reasons: [SocketServer.PendingEnd] = []
}

/// 동시 시작 결과 기록용 (인덱스별 오류, nil 이면 시작 성공)
final class StartOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SocketServerError?]

    init(count: Int) {
        storage = Array(repeating: nil, count: count)
    }

    func set(_ index: Int, _ error: SocketServerError) {
        lock.lock()
        defer { lock.unlock() }
        storage[index] = error
    }

    var values: [SocketServerError?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@MainActor
@Suite("SocketServer")
struct SocketServerTests {
    private func makeServer(path: String, recorder: SocketRecorder, replyID: UUID? = nil) -> SocketServer {
        let server = SocketServer(socketPath: path)
        server.onEnvelope = { envelope in
            recorder.envelopes.append(envelope)
            return envelope.expectsReply ? replyID : nil
        }
        server.onPendingCancelled = { id, reason in
            recorder.cancelled.append(id)
            recorder.reasons.append(reason)
        }
        return server
    }

    @Test func fireAndForgetIsDelivered() async throws {
        let path = shortSocketPath()
        defer { removeSocketFiles(path) }
        let recorder = SocketRecorder()
        let server = makeServer(path: path, recorder: recorder)
        try server.start()
        defer { server.stop() }

        let envelope = makeEnvelope(event: "PreToolUse")
        let leftover = await runBlocking { () -> Data? in
            guard let client = TestClient(path: path), client.sendLine(envelope) else { return nil }
            return client.readUntilEOF(timeout: 5)
        }
        // 응답 없이 서버가 연결을 닫는다
        #expect(leftover == Data())
        #expect(await waitUntil { recorder.envelopes.count == 1 })
        #expect(recorder.envelopes.first == envelope)
        #expect(recorder.cancelled.isEmpty)
    }

    @Test func socketFileIsOwnerOnly() async throws {
        let path = shortSocketPath()
        defer { removeSocketFiles(path) }
        let server = SocketServer(socketPath: path)
        try server.start()
        #expect(server.isRunning)
        #expect(posixPermissions(path) == 0o600)

        server.stop()
        #expect(!server.isRunning)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func replyIsDeliveredToWaitingClient() async throws {
        let path = shortSocketPath()
        defer { removeSocketFiles(path) }
        let recorder = SocketRecorder()
        let id = UUID()
        let server = makeServer(path: path, recorder: recorder, replyID: id)
        try server.start()
        defer { server.stop() }

        let envelope = makeEnvelope(event: "PermissionRequest", expectsReply: true)
        async let line = runBlocking { () -> Data? in
            guard let client = TestClient(path: path), client.sendLine(envelope) else { return nil }
            return client.readLine(timeout: 5)
        }
        #expect(await waitUntil { recorder.envelopes.count == 1 })

        let output: JSONValue = .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("PermissionRequest"),
                "decision": .object(["behavior": .string("allow")]),
            ]),
        ])
        server.reply(to: id, output: output)

        let reply = try JSONDecoder().decode(HookReply.self, from: try #require(await line))
        #expect(reply.v == NotchWire.protocolVersion)
        #expect(reply.output == output)

        // 결정이 났으므로 취소 알림은 없어야 한다
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(recorder.cancelled.isEmpty)
    }

    @Test func replyFromInsideOnEnvelopeIsNotLost() async throws {
        let path = shortSocketPath()
        defer { removeSocketFiles(path) }
        let server = SocketServer(socketPath: path)
        let output: JSONValue = .object(["decided": .bool(true)])
        // onEnvelope 안에서 바로 결정하는 경우 (예: 터미널이 앞에 있어 즉시 넘김)
        server.onEnvelope = { [weak server] _ in
            let id = UUID()
            server?.reply(to: id, output: output)
            return id
        }
        try server.start()
        defer { server.stop() }

        let envelope = makeEnvelope(event: "PermissionRequest", expectsReply: true)
        let line = await runBlocking { () -> Data? in
            guard let client = TestClient(path: path), client.sendLine(envelope) else { return nil }
            return client.readLine(timeout: 5)
        }
        let reply = try JSONDecoder().decode(HookReply.self, from: try #require(line))
        #expect(reply.output == output)
    }

    @Test func expectsReplyWithoutIDRepliesNullImmediately() async throws {
        let path = shortSocketPath()
        defer { removeSocketFiles(path) }
        let recorder = SocketRecorder()
        let server = makeServer(path: path, recorder: recorder, replyID: nil)
        try server.start()
        defer { server.stop() }

        let envelope = makeEnvelope(event: "PermissionRequest", expectsReply: true)
        let line = await runBlocking { () -> Data? in
            guard let client = TestClient(path: path), client.sendLine(envelope) else { return nil }
            return client.readLine(timeout: 5)
        }
        let reply = try JSONDecoder().decode(HookReply.self, from: try #require(line))
        #expect(reply.output == nil)
        #expect(recorder.envelopes.count == 1)
    }

    @Test func clientDisconnectCancelsPending() async throws {
        let path = shortSocketPath()
        defer { removeSocketFiles(path) }
        let recorder = SocketRecorder()
        let id = UUID()
        let server = makeServer(path: path, recorder: recorder, replyID: id)
        try server.start()
        defer { server.stop() }

        let client = try #require(TestClient(path: path))
        #expect(client.sendLine(makeEnvelope(event: "PermissionRequest", expectsReply: true)))
        #expect(await waitUntil { recorder.envelopes.count == 1 })
        try await Task.sleep(nanoseconds: 50_000_000)

        client.close()
        #expect(await waitUntil { recorder.cancelled == [id] })
        #expect(recorder.reasons == [.clientClosed])

        // 끊긴 뒤 들어온 응답은 무시된다
        server.reply(to: id, output: .object([:]))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.cancelled == [id])
    }

    @Test func timeoutRepliesNullAndCancels() async throws {
        let path = shortSocketPath()
        defer { removeSocketFiles(path) }
        let recorder = SocketRecorder()
        let id = UUID()
        let server = makeServer(path: path, recorder: recorder, replyID: id)
        server.replyTimeout = { 0.3 }
        try server.start()
        defer { server.stop() }

        let envelope = makeEnvelope(event: "PermissionRequest", expectsReply: true)
        let line = await runBlocking { () -> Data? in
            guard let client = TestClient(path: path), client.sendLine(envelope) else { return nil }
            return client.readLine(timeout: 5)
        }
        let data = try #require(line)
        let raw = try JSONValue.parse(data)
        #expect(raw["v"]?.intValue == 1)
        #expect(raw["output"] == nil || raw["output"] == .null)
        #expect(try JSONDecoder().decode(HookReply.self, from: data).output == nil)
        #expect(await waitUntil { recorder.cancelled == [id] })
        #expect(recorder.reasons == [.timedOut])
    }

    @Test func stopRepliesNullToPendingAndCancels() async throws {
        let path = shortSocketPath()
        defer { removeSocketFiles(path) }
        let recorder = SocketRecorder()
        let id = UUID()
        let server = makeServer(path: path, recorder: recorder, replyID: id)
        try server.start()

        let envelope = makeEnvelope(event: "PermissionRequest", expectsReply: true)
        async let line = runBlocking { () -> Data? in
            guard let client = TestClient(path: path), client.sendLine(envelope) else { return nil }
            return client.readLine(timeout: 5)
        }
        #expect(await waitUntil { recorder.envelopes.count == 1 })
        try await Task.sleep(nanoseconds: 50_000_000)
        server.stop()

        let reply = try JSONDecoder().decode(HookReply.self, from: try #require(await line))
        #expect(reply.output == nil)
        #expect(await waitUntil { recorder.cancelled == [id] })
        #expect(recorder.reasons == [.serverStopped])
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func secondInstanceIsRejected() async throws {
        let path = shortSocketPath()
        defer { removeSocketFiles(path) }
        let recorder = SocketRecorder()
        let first = makeServer(path: path, recorder: recorder)
        try first.start()
        defer { first.stop() }

        let second = SocketServer(socketPath: path)
        #expect(throws: SocketServerError.alreadyRunning) {
            try second.start()
        }

        // 확인용 빈 연결이 있어도 첫 서버는 정상 동작
        let envelope = makeEnvelope(event: "Stop")
        _ = await runBlocking { () -> Data? in
            guard let client = TestClient(path: path), client.sendLine(envelope) else { return nil }
            return client.readUntilEOF(timeout: 5)
        }
        #expect(await waitUntil { recorder.envelopes.count == 1 })
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func staleSocketFileIsReplaced() async throws {
        let path = shortSocketPath()
        defer { removeSocketFiles(path) }
        // 지난 실행이 남긴 소켓 파일 (bind 후 listen 없이 닫음, 잠금은 이미 풀림)
        #expect(bindUnlistenedSocket(path))
        #expect(FileManager.default.fileExists(atPath: path))

        let recorder = SocketRecorder()
        let server = makeServer(path: path, recorder: recorder)
        try server.start()
        defer { server.stop() }

        let envelope = makeEnvelope(event: "SessionStart")
        _ = await runBlocking { () -> Data? in
            guard let client = TestClient(path: path), client.sendLine(envelope) else { return nil }
            return client.readUntilEOF(timeout: 5)
        }
        #expect(await waitUntil { recorder.envelopes.count == 1 })
    }

    @Test func regularFileAtSocketPathIsNotDeleted() throws {
        let path = shortSocketPath()
        defer { removeSocketFiles(path) }
        FileManager.default.createFile(atPath: path, contents: Data("keep".utf8))

        // 같은 서버가 방금 놓은 잠금을 다시 잡는다
        let server = SocketServer(socketPath: path, lockAttempts: retryingLockAttempts)
        #expect(throws: SocketServerError.pathOccupied) {
            try server.start()
        }
        #expect(FileManager.default.contents(atPath: path) == Data("keep".utf8))
        // 시작에 실패하면 잠금을 바로 놓는다 (다음 시도가 alreadyRunning 으로 막히지 않음)
        #expect(throws: SocketServerError.pathOccupied) {
            try server.start()
        }
        let lock = holdInstanceLock(path)
        #expect(lock >= 0)
        if lock >= 0 { Darwin.close(lock) }
    }

    @Test func instanceLockIsHeldWhileRunning() throws {
        let path = shortSocketPath()
        defer { removeSocketFiles(path) }
        let server = SocketServer(socketPath: path)
        try server.start()
        #expect(server.lockPath == path + ".lock")
        #expect(posixPermissions(server.lockPath) == 0o600)
        // 도는 동안은 다른 쪽이 잠금을 잡을 수 없다
        #expect(holdInstanceLock(path) == -1)

        server.stop()
        // 정지하면 잠금을 놓는다 (잠금 파일 자체는 남김)
        #expect(FileManager.default.fileExists(atPath: server.lockPath))
        let lock = holdInstanceLock(path)
        #expect(lock >= 0)
        if lock >= 0 { Darwin.close(lock) }
    }

    @Test func lockedInstanceSocketIsNotTreatedAsStale() throws {
        // 다른 인스턴스가 잠금을 쥐고 bind 만 했고 아직 listen 전인 순간 (연결 확인은 실패한다)
        let path = shortSocketPath()
        defer { removeSocketFiles(path) }
        let lock = holdInstanceLock(path)
        try #require(lock >= 0)
        #expect(bindUnlistenedSocket(path))

        // 테스트가 방금 놓은 잠금을 다시 잡는다
        let server = SocketServer(socketPath: path, lockAttempts: retryingLockAttempts)
        #expect(throws: SocketServerError.alreadyRunning) {
            try server.start()
        }
        // 그 인스턴스의 소켓 파일을 찌꺼기로 보고 지우면 안 된다
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!server.isRunning)

        // 그 인스턴스가 사라져 잠금이 풀리면 찌꺼기로 보고 대신 시작한다
        Darwin.close(lock)
        try server.start()
        defer { server.stop() }
        #expect(server.isRunning)
    }

    @Test func concurrentStartsOnSamePathAllowOnlyOne() async throws {
        for _ in 0..<25 {
            let path = shortSocketPath()
            defer { removeSocketFiles(path) }
            let servers = [SocketServer(socketPath: path), SocketServer(socketPath: path)]
            defer { servers.forEach { $0.stop() } }

            // 두 서버를 서로 다른 스레드에서 동시에 시작
            let errors = await runBlocking { () -> [SocketServerError?] in
                let outcomes = StartOutcomes(count: servers.count)
                DispatchQueue.concurrentPerform(iterations: servers.count) { index in
                    do {
                        try servers[index].start()
                    } catch let error as SocketServerError {
                        outcomes.set(index, error)
                    } catch {
                        outcomes.set(index, .systemCall(name: "unexpected", code: -1))
                    }
                }
                return outcomes.values
            }
            #expect(errors.filter { $0 == nil }.count == 1, "\(errors)")
            #expect(errors.contains(.alreadyRunning), "\(errors)")
            #expect(servers.filter(\.isRunning).count == 1)
            // 살아남은 쪽이 실제로 연결을 받는다
            let reachable = await runBlocking { () -> Bool in
                guard let client = TestClient(path: path) else { return false }
                client.close()
                return true
            }
            #expect(reachable)
        }
    }

    @Test func tooLongPathIsRejected() {
        let path = "/tmp/" + String(repeating: "a", count: 120) + ".sock"
        let server = SocketServer(socketPath: path)
        #expect(throws: SocketServerError.pathTooLong) {
            try server.start()
        }
    }

    @Test func emptyAndInvalidConnectionsAreTolerated() async throws {
        let path = shortSocketPath()
        defer { removeSocketFiles(path) }
        let recorder = SocketRecorder()
        let server = makeServer(path: path, recorder: recorder)
        try server.start()
        defer { server.stop() }

        let results = await runBlocking { () -> [Data?] in
            // --ping: 연결만 하고 닫기
            var results: [Data?] = []
            if let ping = TestClient(path: path) { ping.close() }
            // 잘못된 JSON → 서버가 닫음
            if let bad = TestClient(path: path), bad.send(Data("not json\n".utf8)) {
                results.append(bad.readUntilEOF(timeout: 5))
            }
            // 줄바꿈 없이 끝난 fire-and-forget envelope 도 받아 준다
            if let noNewline = TestClient(path: path),
               let data = try? JSONEncoder().encode(makeEnvelope(event: "Notification")),
               noNewline.send(data) {
                noNewline.close()
            }
            if let good = TestClient(path: path), good.sendLine(makeEnvelope(event: "Stop")) {
                results.append(good.readUntilEOF(timeout: 5))
            }
            return results
        }
        #expect(results == [Data(), Data()])
        #expect(await waitUntil { recorder.envelopes.count == 2 })
        #expect(Set(recorder.envelopes.map(\.event)) == ["Notification", "Stop"])
    }

    @Test func oversizedEnvelopeClosesConnection() async throws {
        let path = shortSocketPath()
        defer { removeSocketFiles(path) }
        let recorder = SocketRecorder()
        let server = makeServer(path: path, recorder: recorder)
        try server.start()
        defer { server.stop() }

        let result = await runBlocking { () -> Data? in
            guard let client = TestClient(path: path) else { return nil }
            let chunk = Data(repeating: UInt8(ascii: "a"), count: 512 * 1024)
            // 서버가 한도를 넘으면 닫으므로 중간에 쓰기가 실패할 수 있다
            for _ in 0..<12 where client.send(chunk) {}
            return client.readUntilEOF(timeout: 5)
        }
        #expect(result == Data())
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.envelopes.isEmpty)
    }

    @Test func replyTimeoutIsClamped() {
        #expect(SocketServer.clampedReplyTimeout(120) == 120)
        #expect(SocketServer.clampedReplyTimeout(10_000) == SocketServer.maxReplyTimeout)
        #expect(SocketServer.clampedReplyTimeout(-1) == 0.05)
        #expect(SocketServer.clampedReplyTimeout(.infinity) == 120)
    }
}
