import Foundation

/// 노치 UI 에서 일어나는 사용자 동작. App 타깃이 Services 를 이용해 구현하고 UI 에 주입한다.
/// (UI 모듈이 Services 모듈에 직접 의존하지 않도록 하기 위한 경계)
@MainActor
public protocol IslandActions: AnyObject {
    /// 권한 요청 결정 (질문의 답 · 계획 승인 포함)
    func resolvePermission(id: UUID, decision: PermissionDecision)
    /// 노치에서 정하지 않고 세션 앱(터미널 · Claude 앱)의 다이얼로그로 넘김 (`SessionStore.handOff`)
    func handOff(requestID: UUID)
    /// 세션을 실행한 터미널/앱으로 이동
    func jumpToTerminal(sessionID: String)
    /// 파일 열기 (기본 에디터)
    func openFile(path: String, line: Int?)
    /// 세션 고정 토글
    func togglePin(sessionID: String)
    /// 세션 선택 (포커스 변경)
    func focus(sessionID: String)
    /// 세션 목록에서 제거
    func dismiss(sessionID: String)
}
