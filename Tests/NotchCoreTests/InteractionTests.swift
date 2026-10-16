import Foundation
import Testing
@testable import NotchCore
import NotchShared

/// 노치에서 답하는 질문 · 계획 승인 (AskUserQuestion · ExitPlanMode 의 PreToolUse)
@MainActor
@Suite struct InteractionTests {
    let clock = TestClock()

    /// 공식 문서 예시와 같은 질문 (답 JSON 비교용)
    let frameworkInput = #"{"questions":[{"question":"Which framework?","header":"Framework","options":[{"label":"React","description":"Component library"},{"label":"Vue","description":"Progressive framework"}],"multiSelect":false}]}"#
    let checksInput = #"{"questions":[{"question":"어떤 검사를 돌릴까?","header":"검사","multiSelect":true,"options":[{"label":"린트"},{"label":"타입 검사"},{"label":"단위 테스트"}]}]}"#
    let twoQuestionsInput = #"{"questions":[{"question":"어느 환경?","header":"환경","options":[{"label":"프로덕션"},{"label":"스테이징"}]},{"question":"알림은?","header":"알림","multiSelect":true,"options":[{"label":"메일"},{"label":"슬랙"}]}],"annotations":{"source":"plan"}}"#
    let planInput = ##"{"plan":"# 배포 계획\n\n1. 빌드\n2. 스테이징 배포\n3. 프로덕션 배포","planFilePath":"/Users/dev/.claude/plans/deploy.md"}"##

    /// 지금 훅 설정의 PreToolUse (헬퍼가 `--reply-timeout` 으로 답을 기다림)
    private func waiting(_ tool: String, _ input: String, id: String = "q1", session: String = "s1") -> HookEnvelope {
        var envelope = hook("PreToolUse", session: session, #"{"tool_name":"\#(tool)","tool_use_id":"\#(id)","tool_input":\#(input)}"#)
        envelope.expectsReply = NotchWire.expectsReply(event: "PreToolUse", toolName: tool, hasReplyTimeout: true)
        return envelope
    }

    private func ask(_ store: SessionStore, _ input: String, tool: String = "AskUserQuestion", id: String = "q1", session: String = "s1") -> UUID? {
        store.ingest(hook("UserPromptSubmit", session: session, #"{"prompt":"배포해줘"}"#))
        clock.advance()
        return store.ingest(waiting(tool, input, id: id, session: session))
    }

    // MARK: - 헬퍼가 기다리는 호출

    @Test func helperWaitsOnlyForInteractiveToolsWithReplyTimeout() {
        // PermissionRequest 는 늘 기다린다
        #expect(NotchWire.expectsReply(event: "PermissionRequest", toolName: "Bash", hasReplyTimeout: false))
        #expect(NotchWire.expectsReply(event: "PermissionRequest", toolName: nil, hasReplyTimeout: true))
        // 질문 · 계획 승인 툴의 PreToolUse 는 지금 훅 설정(--reply-timeout)일 때만
        #expect(NotchWire.expectsReply(event: "PreToolUse", toolName: "AskUserQuestion", hasReplyTimeout: true))
        #expect(NotchWire.expectsReply(event: "PreToolUse", toolName: "ExitPlanMode", hasReplyTimeout: true))
        #expect(!NotchWire.expectsReply(event: "PreToolUse", toolName: "AskUserQuestion", hasReplyTimeout: false))
        // 다른 툴 · 다른 이벤트는 바로 끝낸다
        #expect(!NotchWire.expectsReply(event: "PreToolUse", toolName: "Bash", hasReplyTimeout: true))
        #expect(!NotchWire.expectsReply(event: "PreToolUse", toolName: nil, hasReplyTimeout: true))
        #expect(!NotchWire.expectsReply(event: "PostToolUse", toolName: "AskUserQuestion", hasReplyTimeout: true))
        #expect(!NotchWire.expectsReply(event: "Notification", toolName: nil, hasReplyTimeout: true))
        #expect(!NotchWire.expectsReply(event: "MessageDisplay", toolName: nil, hasReplyTimeout: true))
    }

    // MARK: - 대기열

    @Test func recommendedOptionIsMarkedButAnswerKeepsLabel() {
        let recommended = QuestionOption(label: "공개 (Recommended)", description: "brew 설치에 필요")
        #expect(recommended.isRecommended)
        #expect(recommended.displayLabel == "공개")
        #expect(QuestionOption(label: "MIT (recommended) ").displayLabel == "MIT")
        #expect(QuestionOption(label: "둘째 줄로 (권장)").displayLabel == "둘째 줄로")
        #expect(QuestionOption(label: "고치기(추천)").isRecommended)
        // 이름 가운데 있거나 표시만 있는 경우는 그대로
        #expect(!QuestionOption(label: "Recommended 설정 보기").isRecommended)
        #expect(QuestionOption(label: "(Recommended)").displayLabel == "(Recommended)")
        // 답은 원래 이름 그대로
        #expect(QuestionAnswer(labels: [recommended.label]).labels == ["공개 (Recommended)"])
    }

    @Test func questionIsQueued() throws {
        let store = makeStore(clock)
        let id = try #require(ask(store, frameworkInput))
        let info = try #require(store.pendingPermissions.first)
        #expect(info.id == id)
        #expect(info.toolName == "AskUserQuestion")
        #expect(info.toolUseID == "q1")
        #expect(info.isInteraction)
        #expect(info.kind == .question([QuestionItem(
            question: "Which framework?",
            header: "Framework",
            options: [
                QuestionOption(label: "React", description: "Component library"),
                QuestionOption(label: "Vue", description: "Progressive framework"),
            ],
            multiSelect: false
        )]))
        let session = try #require(store.sessions["s1"])
        #expect(session.phase == .waitingInput)
        #expect(session.currentActivity?.id == "q1")
        #expect(store.latestSignal?.signal == .needsInput(sessionID: "s1", message: "Which framework?"))
        #expect(store.focusedSessionID == "s1")
    }

    @Test func planIsQueued() throws {
        let store = makeStore(clock)
        _ = try #require(ask(store, planInput, tool: "ExitPlanMode", id: "p1"))
        let info = try #require(store.pendingPermissions.first)
        guard case let .plan(plan) = info.kind else {
            Issue.record("계획 승인이 아님: \(info.kind)")
            return
        }
        #expect(plan.filePath == "/Users/dev/.claude/plans/deploy.md")
        #expect(plan.previewLines(max: 3) == ["배포 계획", "1. 빌드", "2. 스테이징 배포"])
        #expect(plan.lineCount == 4)
        #expect(info.title == "계획 승인")
        #expect(store.sessions["s1"]?.phase == .waitingInput)
    }

    @Test func oldSettingsDoNotQueue() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"배포해줘"}"#))
        // 예전 훅 설정(헬퍼가 기다리지 않음): 입력 대기 카드만
        let id = store.ingest(hook("PreToolUse", #"{"tool_name":"AskUserQuestion","tool_use_id":"q1","tool_input":\#(frameworkInput)}"#))
        #expect(id == nil)
        #expect(store.pendingPermissions.isEmpty)
        #expect(store.sessions["s1"]?.phase == .waitingInput)
        #expect(store.latestSignal?.signal == .needsInput(sessionID: "s1", message: "Which framework?"))
    }

    @Test(arguments: [
        // 선택지 없음 · 5개 · 질문 5개 · 같은 질문 두 번 · 빈 질문 · 빈 선택지 이름 · 질문 목록 없음
        #"{"questions":[{"question":"A?"}]}"#,
        #"{"questions":[{"question":"A?","options":[{"label":"1"},{"label":"2"},{"label":"3"},{"label":"4"},{"label":"5"}]}]}"#,
        #"{"questions":[{"question":"1?","options":[{"label":"a"}]},{"question":"2?","options":[{"label":"a"}]},{"question":"3?","options":[{"label":"a"}]},{"question":"4?","options":[{"label":"a"}]},{"question":"5?","options":[{"label":"a"}]}]}"#,
        #"{"questions":[{"question":"A?","options":[{"label":"a"}]},{"question":"A?","options":[{"label":"b"}]}]}"#,
        #"{"questions":[{"question":"  ","options":[{"label":"a"}]}]}"#,
        #"{"questions":[{"question":"A?","options":[{"label":""}]}]}"#,
        #"{}"#,
    ])
    func unanswerableQuestionsGoToDialog(input: String) throws {
        let store = makeStore(clock)
        // 노치에서 답할 수 없는 모양: 대기열에 넣지 않고 nil (훅은 바로 결정 없음 → 다이얼로그)
        #expect(ask(store, input) == nil)
        #expect(store.pendingPermissions.isEmpty)
        #expect(store.sessions["s1"]?.phase == .waitingInput)
    }

    @Test func planWithoutContentGoesToDialog() {
        let store = makeStore(clock)
        #expect(ask(store, #"{"planFilePath":"/Users/dev/.claude/plans/x.md"}"#, tool: "ExitPlanMode") == nil)
        #expect(ask(store, #"{"plan":"  \n "}"#, tool: "ExitPlanMode") == nil)
        #expect(store.pendingPermissions.isEmpty)
    }

    @Test func shrunkPayloadGoesToDialog() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"배포해줘"}"#))
        // 헬퍼가 큰 payload 를 줄였으면 원래 입력을 그대로 돌려줄 수 없다
        var envelope = hook("PreToolUse", #"{"tool_name":"ExitPlanMode","tool_use_id":"p1","tool_input":\#(planInput),"_agent_notch_truncated":true}"#)
        envelope.expectsReply = true
        #expect(store.ingest(envelope) == nil)
        #expect(store.pendingPermissions.isEmpty)
    }

    @Test func queuesAcrossSessionsWithPermissions() throws {
        let store = makeStore(clock)
        let question = try #require(ask(store, frameworkInput, session: "s1"))
        clock.advance()
        store.ingest(hook("UserPromptSubmit", session: "s2", cwd: otherCwd, #"{"prompt":"정리해줘"}"#))
        let permission = try #require(store.ingest(hook("PermissionRequest", session: "s2", cwd: otherCwd, #"{"tool_name":"Bash","tool_input":{"command":"rm -rf dist"}}"#)))
        #expect(store.pendingPermissions.map(\.id) == [question, permission])
        // 오래된 요청 먼저
        #expect(store.focusedSessionID == "s1")
        #expect(store.sessions["s1"]?.phase == .waitingInput)
        #expect(store.sessions["s2"]?.phase == .waitingPermission)

        store.resolvePermission(id: question, decision: .answer([QuestionAnswer(labels: ["React"])]))
        #expect(store.focusedSessionID == "s2")
    }

    @Test func pendingQuestionKeepsInputWaitWhileSiblingFinishes() throws {
        let store = makeStore(clock)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"배포해줘"}"#))
        store.ingest(hook("PreToolUse", #"{"tool_name":"Read","tool_use_id":"r1","tool_input":{"file_path":"/Users/dev/projects/api-server/a.ts"}}"#))
        _ = try #require(store.ingest(waiting("AskUserQuestion", frameworkInput)))
        // 함께 돌던 툴이 끝나도 질문 대기는 승인 대기로 바뀌지 않는다
        store.ingest(hook("PostToolUse", #"{"tool_name":"Read","tool_use_id":"r1","tool_input":{"file_path":"/Users/dev/projects/api-server/a.ts"},"tool_response":{}}"#))
        #expect(store.sessions["s1"]?.phase == .waitingInput)
        #expect(store.pendingPermissions.count == 1)

        // 아직 노치 답을 기다리면 idle_prompt 로 정리하지 않는다
        store.ingest(hook("Notification", #"{"notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#))
        #expect(store.sessions["s1"]?.phase == .waitingInput)
        #expect(store.pendingPermissions.count == 1)
    }

    // MARK: - 답 JSON

    @Test func singleAnswerMatchesDocumentedOutput() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        let id = try #require(ask(store, frameworkInput))

        store.resolvePermission(id: id, decision: .answer([QuestionAnswer(labels: ["React"])]))
        let (info, decision) = try #require(recorder.calls.first)
        let output = try #require(PermissionReplyBuilder.output(for: info, decision: decision))
        // 공식 문서 예시 그대로: 원래 questions 를 돌려주고 answers 에 질문 원문 → 답
        let expected = json(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"questions":[{"question":"Which framework?","header":"Framework","options":[{"label":"React","description":"Component library"},{"label":"Vue","description":"Progressive framework"}],"multiSelect":false}],"answers":{"Which framework?":"React"}}}}"#)
        #expect(output == expected)
        #expect(store.pendingPermissions.isEmpty)
        // 답을 받으면 툴이 실행된다
        #expect(store.sessions["s1"]?.phase == .runningTool)
    }

    @Test func multiSelectJoinsLabelsWithCommas() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        let id = try #require(ask(store, checksInput))

        store.resolvePermission(id: id, decision: .answer([QuestionAnswer(labels: ["린트", "단위 테스트"], otherText: "  보안 검사 ")]))
        let (info, decision) = try #require(recorder.calls.first)
        let output = try #require(PermissionReplyBuilder.output(for: info, decision: decision))
        #expect(output["hookSpecificOutput"]?["updatedInput"]?["answers"] == json(#"{"어떤 검사를 돌릴까?":"린트, 단위 테스트, 보안 검사"}"#))
    }

    @Test func otherTextIsTheAnswer() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        let id = try #require(ask(store, frameworkInput))

        store.resolvePermission(id: id, decision: .answer([QuestionAnswer(otherText: "Svelte")]))
        let (info, decision) = try #require(recorder.calls.first)
        #expect(decision == .answer([QuestionAnswer(otherText: "Svelte")]))
        let output = try #require(PermissionReplyBuilder.output(for: info, decision: decision))
        #expect(output["hookSpecificOutput"]?["updatedInput"]?["answers"] == json(#"{"Which framework?":"Svelte"}"#))
    }

    @Test func multipleQuestionsKeepOtherInputFields() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        let id = try #require(ask(store, twoQuestionsInput))
        guard case let .question(questions)? = store.pendingPermissions.first?.kind else {
            Issue.record("질문이 아님")
            return
        }
        #expect(questions.map(\.multiSelect) == [false, true])

        store.resolvePermission(id: id, decision: .answer([
            QuestionAnswer(labels: ["스테이징"]),
            QuestionAnswer(labels: ["메일", "슬랙"]),
        ]))
        let (info, decision) = try #require(recorder.calls.first)
        let output = try #require(PermissionReplyBuilder.output(for: info, decision: decision))
        let updated = try #require(output["hookSpecificOutput"]?["updatedInput"])
        #expect(updated["answers"] == json(#"{"어느 환경?":"스테이징","알림은?":"메일, 슬랙"}"#))
        // 입력 전체를 바꾸므로 원래 필드는 그대로 둔다
        #expect(updated["questions"] == json(twoQuestionsInput)["questions"])
        #expect(updated["annotations"] == json(#"{"source":"plan"}"#))
    }

    @Test func incompleteAnswersBecomePassthrough() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        let id = try #require(ask(store, twoQuestionsInput))
        let info = try #require(store.pendingPermissions.first)

        // 답 개수가 다름 · 빈 답 · 한 개 고르는 질문에 둘 · 답 없이 허용
        #expect(PermissionReplyBuilder.output(for: info, decision: .answer([QuestionAnswer(labels: ["스테이징"])])) == nil)
        #expect(PermissionReplyBuilder.output(for: info, decision: .answer([QuestionAnswer(labels: ["스테이징"]), QuestionAnswer(otherText: " ")])) == nil)
        #expect(PermissionReplyBuilder.output(for: info, decision: .answer([QuestionAnswer(labels: ["프로덕션", "스테이징"]), QuestionAnswer(labels: ["메일"])])) == nil)
        #expect(PermissionReplyBuilder.output(for: info, decision: .answer([QuestionAnswer(labels: ["스테이징"], otherText: "둘 다"), QuestionAnswer(labels: ["메일"])])) == nil)
        #expect(PermissionReplyBuilder.output(for: info, decision: .allow) == nil)
        #expect(PermissionReplyBuilder.output(for: info, decision: .deny(message: nil)) == nil)

        // 훅에는 결정 없음으로 전달되고, 다이얼로그에서 답해야 하므로 입력 대기 유지
        store.resolvePermission(id: id, decision: .answer([QuestionAnswer(labels: ["스테이징"])]))
        #expect(recorder.calls.first?.1 == .passthrough)
        #expect(store.sessions["s1"]?.phase == .waitingInput)
    }

    @Test func answerOnPermissionIsPassthrough() {
        let info = pending("s1", at: 0)
        #expect(PermissionReplyBuilder.output(for: info, decision: .answer([QuestionAnswer(labels: ["a"])])) == nil)
        #expect(PermissionReplyBuilder.effectiveDecision(for: info, decision: .answer([])) == .passthrough)
        #expect(PermissionReplyBuilder.effectiveDecision(for: info, decision: .allow) == .allow)
    }

    @Test func answerValues() {
        #expect(QuestionAnswer().value == nil)
        #expect(QuestionAnswer(otherText: " \n").value == nil)
        #expect(QuestionAnswer(labels: ["a"]).value == "a")
        #expect(QuestionAnswer(labels: ["a", "b"]).value == "a, b")
        #expect(QuestionAnswer(labels: ["a"], otherText: " c ").value == "a, c")
    }

    @Test func planApprovalEchoesInput() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        let id = try #require(ask(store, planInput, tool: "ExitPlanMode", id: "p1"))
        let info = try #require(store.pendingPermissions.first)
        #expect(PermissionReplyBuilder.output(for: info, decision: .deny(message: nil)) == nil)
        #expect(PermissionReplyBuilder.output(for: info, decision: .allowAlways) == nil)

        store.resolvePermission(id: id, decision: .allow)
        let (resolved, decision) = try #require(recorder.calls.first)
        let output = try #require(PermissionReplyBuilder.output(for: resolved, decision: decision))
        // 승인: Claude Code 가 넣어 준 입력(계획 · 경로)을 그대로 돌려준다
        let expected: JSONValue = .object(["hookSpecificOutput": .object([
            "hookEventName": .string("PreToolUse"),
            "permissionDecision": .string("allow"),
            "updatedInput": json(planInput),
        ])])
        #expect(output == expected)
        #expect(store.sessions["s1"]?.phase == .runningTool)
    }

    // MARK: - 넘김 · 시간 초과 · 끊김

    @Test func passthroughKeepsInputCard() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        let id = try #require(ask(store, frameworkInput))
        // 터미널을 보고 있어 바로 넘김: 다이얼로그에서 답해야 하므로 입력 대기 (입력 대기 카드로 안내)
        store.resolvePermission(id: id, decision: .passthrough)
        #expect(recorder.calls.first?.1 == .passthrough)
        #expect(store.pendingPermissions.isEmpty)
        #expect(store.sessions["s1"]?.phase == .waitingInput)
        #expect(!store.isInputHandedOff("s1"))
    }

    @Test func timeoutKeepsInputCard() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        let id = try #require(ask(store, frameworkInput))
        // 노치에서 기다리는 시간이 지남 (SocketServer 가 이미 결정 없음으로 응답) → Claude Code 다이얼로그가 이어서 뜬다
        store.expirePermission(id: id)
        #expect(recorder.calls.isEmpty)
        #expect(store.pendingPermissions.isEmpty)
        #expect(store.sessions["s1"]?.phase == .waitingInput)
        #expect(store.sessions["s1"]?.currentActivity?.id == "q1")
    }

    @Test func disconnectClearsQuestion() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        let id = try #require(ask(store, frameworkInput))
        // Claude Code 가 기다리던 훅을 끊음 (Esc · 중단): 다이얼로그도 뜨지 않는다 → 카드 · 입력 대기 모두 정리
        store.cancelPermission(id: id)
        #expect(recorder.calls.isEmpty)
        #expect(store.pendingPermissions.isEmpty)
        let session = try #require(store.sessions["s1"])
        #expect(session.phase == .idle)
        #expect(session.currentActivity == nil)
        #expect(session.activities.first { $0.id == "q1" }?.status == .failed)
    }

    @Test func handOffDoesNotShowDuplicateCard() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        let id = try #require(ask(store, frameworkInput))

        // "터미널로": 결정 없이 풀고, 그 다이얼로그에 답할 때까지 입력 대기 카드를 다시 띄우지 않는다
        store.handOff(id: id)
        #expect(recorder.calls.first?.1 == .passthrough)
        #expect(store.pendingPermissions.isEmpty)
        #expect(store.sessions["s1"]?.phase == .waitingInput)
        #expect(store.isInputHandedOff("s1"))
        let seq = store.latestSignal?.seq

        // 같은 호출의 PermissionRequest (다이얼로그 직전): 대기열에 넣지 않고 새 신호도 없다
        #expect(store.ingest(hook("PermissionRequest", #"{"tool_name":"AskUserQuestion","tool_input":\#(frameworkInput)}"#)) == nil)
        #expect(store.latestSignal?.seq == seq)
        #expect(store.isInputHandedOff("s1"))
        // 약 6초 뒤 다이얼로그 알림도 카드로 띄우지 않는다
        store.ingest(hook("Notification", #"{"notification_type":"permission_prompt","message":"Claude needs your input"}"#))
        #expect(store.sessions["s1"]?.phase == .waitingInput)
        #expect(store.latestSignal?.seq == seq)
        #expect(store.isInputHandedOff("s1"))

        // 다이얼로그에서 답함 → 툴 실행 끝 → 다시 평소대로
        store.ingest(hook("PostToolUse", #"{"tool_name":"AskUserQuestion","tool_use_id":"q1","tool_response":{}}"#))
        #expect(store.sessions["s1"]?.phase == .thinking)
        #expect(!store.isInputHandedOff("s1"))
    }

    @Test func passedThroughQuestionStaysInputOnDialogNotification() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        let id = try #require(ask(store, frameworkInput))

        // 세션 앱을 보고 있어 노치에서 정하지 않고 바로 넘김 (사용자가 "Claude로"를 누른 것이 아님)
        store.resolvePermission(id: id, decision: .passthrough)
        #expect(recorder.calls.first?.1 == .passthrough)
        #expect(store.sessions["s1"]?.phase == .waitingInput)
        #expect(!store.isInputHandedOff("s1"))
        let seq = store.latestSignal?.seq

        // 같은 호출의 PermissionRequest 와 다이얼로그 알림(permission_prompt)이 와도 질문의 입력 대기다.
        // 예전에는 알림이 승인 대기로 덮어써 카드가 "Claude 앱에서 승인 필요"로 바뀌었다
        #expect(store.ingest(hook("PermissionRequest", #"{"tool_name":"AskUserQuestion","tool_input":\#(frameworkInput)}"#)) == nil)
        store.ingest(hook("Notification", #"{"notification_type":"permission_prompt","message":"Claude needs your permission to use AskUserQuestion"}"#))
        #expect(store.sessions["s1"]?.phase == .waitingInput)
        #expect(store.latestSignal?.seq == seq)

        // 앱에서 답함 → 다시 평소대로
        store.ingest(hook("PostToolUse", #"{"tool_name":"AskUserQuestion","tool_use_id":"q1","tool_response":{}}"#))
        #expect(store.sessions["s1"]?.phase == .thinking)

        // 질문이 없을 때의 다이얼로그 알림은 그대로 승인 대기
        store.ingest(hook("PreToolUse", #"{"tool_name":"Bash","tool_use_id":"b1","tool_input":{"command":"rm -rf build"}}"#))
        store.ingest(hook("Notification", #"{"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}"#))
        #expect(store.sessions["s1"]?.phase == .waitingPermission)
    }

    @Test func newQuestionAfterHandOffShowsAgain() throws {
        let store = makeStore(clock)
        let id = try #require(ask(store, frameworkInput))
        store.handOff(id: id)
        #expect(store.isInputHandedOff("s1"))
        // 다른 질문이 새로 오면 다시 노치에서 답한다
        _ = try #require(store.ingest(waiting("AskUserQuestion", checksInput, id: "q2")))
        #expect(!store.isInputHandedOff("s1"))
        #expect(store.pendingPermissions.count == 1)
    }

    @Test func permissionHandOffIsPassthrough() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"정리해줘"}"#))
        let id = try #require(store.ingest(hook("PermissionRequest", #"{"tool_name":"Bash","tool_input":{"command":"rm -rf dist"}}"#)))
        store.handOff(id: id)
        #expect(recorder.calls.first?.1 == .passthrough)
        // 권한 요청은 예전처럼 승인 대기 카드로 안내한다
        #expect(store.sessions["s1"]?.phase == .waitingPermission)
        #expect(!store.isInputHandedOff("s1"))
    }

    @Test func nextPromptReleasesPendingQuestion() throws {
        let store = makeStore(clock)
        let recorder = ResolutionRecorder()
        recorder.attach(to: store)
        _ = try #require(ask(store, frameworkInput))
        store.ingest(hook("UserPromptSubmit", #"{"prompt":"그냥 진행해"}"#))
        #expect(store.pendingPermissions.isEmpty)
        #expect(recorder.calls.first?.1 == .passthrough)
        #expect(store.sessions["s1"]?.phase == .thinking)
    }
}
