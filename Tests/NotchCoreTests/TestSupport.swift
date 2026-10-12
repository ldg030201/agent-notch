import Foundation
@testable import NotchCore
import NotchShared

/// 테스트용 시계 (시간을 직접 진행)
final class TestClock {
    var now: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        now = start
    }

    func advance(_ seconds: TimeInterval = 1) {
        now = now.addingTimeInterval(seconds)
    }
}

/// 가짜 프로젝트 경로 (실제 사용자 경로 아님)
let projectCwd = "/Users/dev/projects/api-server"
let otherCwd = "/Users/dev/projects/web-app"

func json(_ text: String) -> JSONValue {
    do {
        return try JSONValue.parse(Data(text.utf8))
    } catch {
        fatalError("테스트 JSON 파싱 실패: \(text)")
    }
}

/// 훅 이벤트 envelope 생성. `fields` 는 payload 에 합칠 JSON 객체 문자열
func hook(
    _ event: String,
    session: String = "s1",
    cwd: String? = projectCwd,
    _ fields: String = "{}",
    env: [String: String] = [:]
) -> HookEnvelope {
    var object = json(fields).objectValue ?? [:]
    object["hook_event_name"] = .string(event)
    object["session_id"] = .string(session)
    if let cwd { object["cwd"] = .string(cwd) }
    return HookEnvelope(
        event: event,
        sentAt: 0,
        env: env,
        expectsReply: NotchWire.replyEvents.contains(event),
        payload: .object(object)
    )
}

@MainActor
func makeStore(_ clock: TestClock) -> SessionStore {
    SessionStore(clock: { clock.now })
}

/// 권한 결정 콜백 기록
@MainActor
final class ResolutionRecorder {
    var calls: [(PermissionRequestInfo, PermissionDecision)] = []

    func attach(to store: SessionStore) {
        store.onPermissionResolved = { [weak self] info, decision in
            self?.calls.append((info, decision))
        }
    }
}

func session(
    _ id: String,
    phase: SessionPhase,
    at seconds: TimeInterval,
    unseen: Bool = false
) -> AgentSession {
    let date = Date(timeIntervalSince1970: 1_800_000_000 + seconds)
    return AgentSession(
        id: id,
        cwd: "/Users/dev/projects/\(id)",
        projectName: id,
        phase: phase,
        startedAt: date,
        lastEventAt: date,
        hasUnseenCompletion: unseen
    )
}

func pending(_ sessionID: String, at seconds: TimeInterval) -> PermissionRequestInfo {
    PermissionRequestInfo(
        id: UUID(),
        sessionID: sessionID,
        toolName: "Bash",
        title: "Bash 실행 요청",
        detail: "npm test",
        toolInput: .object(["command": .string("npm test")]),
        suggestions: nil,
        receivedAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds)
    )
}
