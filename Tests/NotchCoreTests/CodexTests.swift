import Foundation
import Testing
@testable import NotchCore
import NotchShared

/// Codex 훅 이벤트 (훅 명령의 `--agent codex` → `HookEnvelope.agent`)
func codexHook(
    _ event: String,
    session: String = "c1",
    cwd: String? = projectCwd,
    _ fields: String = "{}",
    env: [String: String] = [:],
    expectsReply: Bool? = nil
) -> HookEnvelope {
    var envelope = hook(event, session: session, cwd: cwd, fields, env: env)
    envelope.agent = AgentKind.codex.rawValue
    if let expectsReply { envelope.expectsReply = expectsReply }
    return envelope
}

@Suite("Codex 와이어")
struct CodexWireTests {
    @Test func envelopeWithoutAgentIsClaude() throws {
        // 예전 헬퍼 · Claude Code 훅은 agent 를 보내지 않는다
        let line = #"{"v":1,"event":"Stop","sentAt":0,"env":{},"expectsReply":false,"payload":{}}"#
        let envelope = try JSONDecoder().decode(HookEnvelope.self, from: Data(line.utf8))
        #expect(envelope.agent == nil)
        #expect(envelope.agentKind == .claude)
    }

    @Test func envelopeRoundTripsAgent() throws {
        let envelope = codexHook("Stop")
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(HookEnvelope.self, from: data)
        #expect(decoded.agentKind == .codex)
        // Claude Code envelope 는 agent 키를 아예 쓰지 않는다 (예전 앱과 같은 모양)
        let claude = try JSONEncoder().encode(hook("Stop"))
        #expect(!String(decoding: claude, as: UTF8.self).contains("\"agent\""))
    }

    @Test func unknownAgentNameFallsBackToClaude() {
        var envelope = hook("Stop")
        envelope.agent = "gemini"
        #expect(envelope.agentKind == .claude)
        #expect(AgentKind(name: " Codex ") == .codex)
        #expect(AgentKind(name: "") == nil)
    }

    @Test func forwardsOnlyNonSecretCodexKeys() {
        let keys = NotchWire.forwardedEnvironmentKeys
        #expect(keys.contains("CODEX_INTERNAL_ORIGINATOR_OVERRIDE"))
        #expect(keys.contains("CODEX_THREAD_ID"))
        #expect(!keys.contains { $0.contains("KEY") || $0.contains("TOKEN") || $0.contains("SECRET") })
    }
}
