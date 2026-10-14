import Foundation
import NotchCore
import NotchServices

/// 아일랜드 UI 동작 구현 (NotchUI → Services 연결)
@MainActor
final class AppActions: IslandActions {
    private let store: SessionStore
    private let terminalJumper: TerminalJumper
    private let fileOpener: FileOpener

    init(store: SessionStore, terminalJumper: TerminalJumper, fileOpener: FileOpener) {
        self.store = store
        self.terminalJumper = terminalJumper
        self.fileOpener = fileOpener
    }

    func resolvePermission(id: UUID, decision: PermissionDecision) {
        store.resolvePermission(id: id, decision: decision)
    }

    func handOff(requestID: UUID) {
        store.handOff(id: requestID)
    }

    func jumpToTerminal(sessionID: String) {
        guard let session = store.sessions[sessionID] else { return }
        terminalJumper.jump(to: session.terminal)
        store.markSeen(sessionID: sessionID)
    }

    func openFile(path: String, line: Int?) {
        fileOpener.open(path: path, line: line)
    }

    func togglePin(sessionID: String) {
        store.togglePin(sessionID: sessionID)
    }

    func focus(sessionID: String) {
        store.focus(sessionID: sessionID)
        store.markSeen(sessionID: sessionID)
    }

    func dismiss(sessionID: String) {
        store.dismiss(sessionID: sessionID)
    }
}
