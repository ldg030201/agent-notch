# AgentNotch 아키텍처

맥북 노치를 다이나믹 아일랜드처럼 확장해서 Claude Code 세션의 **현재 작업 / 미니 diff / 권한 요청 / 완료**를
실시간으로 보여주는 메뉴바 앱. 노치가 없는 외부 모니터에서는 메뉴바 아래 떠 있는 알약(pill) 형태로 같은 내용을 보여준다.

## 1. 전체 흐름

```
Claude Code (CLI · 데스크톱 앱)
  └─ hook (type: command) ─▶ notch-hook  (앱이 설치 시 ~/Library/Application Support/AgentNotch/bin 에 복사)
        │  stdin 의 훅 JSON + 화이트리스트 환경변수 → HookEnvelope
        ▼
  Unix 소켓  ~/Library/Application Support/AgentNotch/notch.sock  (디렉터리 0700, 소켓 0600)
        ▼
  AgentNotch.app
    SocketServer ─▶ SessionStore.ingest() ─▶ 포커스 계산 · 신호(latestSignal)
         ▲                     │
         │ HookReply           ▼
         └──── 권한 결정 ◀── NotchUI (화면별 NSPanel + SwiftUI 아일랜드)
```

- 앱이 꺼져 있으면 `notch-hook` 은 소켓 연결 실패 → **조용히 exit 0** (Claude Code 동작에 영향 없음).
- 앱 응답을 기다리는 건 `PermissionRequest` 와 질문 · 계획 승인 툴(`AskUserQuestion` · `ExitPlanMode`)의 `PreToolUse` 뿐이다
  (3장 "응답을 기다리는 호출"). 나머지는 보내고 바로 종료(fire-and-forget) — 다른 툴의 `PreToolUse` 도 마찬가지.

## 2. 모듈 구성 (SwiftPM)

| 타깃 | 역할 | 의존 |
|---|---|---|
| `NotchShared` | 와이어 프로토콜(`HookEnvelope`, `HookReply`, `NotchWire`), `JSONValue` | - |
| `notch-hook` | 훅 헬퍼 실행 파일 | NotchShared |
| `NotchCore` | 모델, `SessionStore`, 이벤트 해석, 포커스 엔진, diff 계산, 툴 요약, 설정(`AppPreferences`), `IslandActions` 프로토콜 | NotchShared |
| `NotchServices` | 소켓 서버, 훅 설치/제거, 터미널 점프, 앞에 있는 앱 감지, 로그인 시 실행, 업데이트 확인 · 업그레이드 | NotchShared, NotchCore |
| `NotchUI` | 노치 기하 계산, `NSPanel`, 화면 관리, 표시 모드 컨트롤러, 아일랜드 SwiftUI 뷰, 설정 화면 | NotchCore |
| `AgentNotch` | 앱 진입점, 메뉴바 아이템, 모듈 조립, 데모 모드 | 전부 |

`NotchUI` 는 `NotchServices` 에 의존하지 않는다. UI 동작은 `IslandActions` 프로토콜로 App 이 주입한다.

## 3. 와이어 프로토콜

- 줄바꿈으로 끝나는 JSON 한 줄. 헬퍼 → 앱: `HookEnvelope`, 앱 → 헬퍼: `HookReply` (응답이 필요한 이벤트만).
- `HookReply.output` 이 있으면 헬퍼는 그 JSON 을 stdout 에 그대로 출력하고 exit 0. 없으면 아무것도 출력하지 않는다.
- 헬퍼의 응답 대기 시간은 훅 `timeout` 보다 짧아야 한다. 앱이 `AppPreferences.permissionTimeout` 이 지나면 `output: null` 로 응답한다.
- 소켓 경로는 `AGENT_NOTCH_SOCKET` 환경변수로 덮어쓸 수 있다 (테스트용). `sun_path` 길이 제한(104바이트)에 주의.
- 응답 없이 끝난 대기는 이유와 함께 알린다 (`SocketServer.PendingEnd`): 연결 끊김 → `SessionStore.cancelPermission`,
  앱의 대기 시간 초과(`output: null` 로 응답함) → `expirePermission`, 서버 정지 → `cancelPermission`.

### 응답을 기다리는 호출

헬퍼가 기다릴지는 `NotchWire.expectsReply(event:toolName:hasReplyTimeout:)` 가 정한다 (NotchShared, 테스트 있음).

| 호출 | 훅 명령 (`HookInstaller`) | 훅 timeout | 앱 응답 (`PermissionReplyBuilder`) |
|---|---|---|---|
| `PermissionRequest` | `notch-hook PermissionRequest --reply-timeout 590` | 600 | `hookSpecificOutput.decision` (allow · 항상 허용 · deny) |
| `PreToolUse` — `AskUserQuestion` · `ExitPlanMode` | `notch-hook PreToolUse --reply-timeout 590` | 600 | `permissionDecision: "allow"` + `updatedInput` |
| `PreToolUse` — 그 밖의 툴 | (같은 명령) | 600 | 기다리지 않고 바로 종료 |
| 나머지 이벤트 | `notch-hook <Event>` | 10 (MessageDisplay 5, SessionEnd 2) | 없음 |

- `PreToolUse` 는 **명령에 `--reply-timeout` 이 있을 때만** 기다린다. 예전 버전이 설치한 설정(timeout 10, 대기 시간 없음)으로 불리면
  Claude Code 가 10초 만에 훅을 끊으므로 기다리지 않고 예전처럼 입력 대기 카드 → 다이얼로그로 답한다.
- 공식 문서(hooks "Tools that require user interaction"): 두 툴은 `"allow"` 만으로는 실행되지 않고 답을 담은 `updatedInput` 이 함께 있어야 한다.
  - `AskUserQuestion`: 원래 입력을 그대로 두고(`questions` · 그 밖의 필드) `answers` 에 질문 원문 → 답. 여러 개 고른 답은 선택지 이름을
    쉼표로 잇는다(`"린트, 단위 테스트"`). "기타" 에 쓴 글자는 그대로 답이 된다 (여러 개 고르는 질문이면 선택지 뒤에 이어 붙임).
  - `ExitPlanMode`: Claude Code 가 넣어 준 입력(`plan` · `planFilePath`)을 그대로 돌려주면 승인. 거부 · 다른 승인 방식은 노치에서 하지 않는다.
  - 답이 빠졌거나 모양이 맞지 않는 결정은 `SessionStore` 가 결정 없음(`.passthrough`)으로 바꿔 전달한다 (`effectiveDecision`).
- 예전 설정 고치기: 앱이 켜질 때 `AppSettingsProvider.refreshHelperIfNeeded` 가 헬퍼를 다시 복사한 뒤
  `HookInstaller.updateInstalledHooks()` 로 **이미 설치된 AgentNotch 항목만** 지금 형태(명령 · timeout)로 그 자리에서 고친다.
  우리 항목이 없거나 이미 최신이면 아무것도 하지 않고, 빠진 이벤트를 새로 넣거나 다른 훅 · 설정을 건드리지 않는다.
  바꾸기 전에 타임스탬프 백업(0600). Claude Code 는 설정 파일을 감시해 실행 중인 세션도 바뀐 훅을 대개 바로 다시 읽는다 (감시가 놓치면 재시작해야 함).

## 4. 훅 이벤트 → 세션 상태

| 이벤트 | 처리 |
|---|---|
| `SessionStart` | 세션 생성(이미 있으면 갱신), phase `idle`, 신호 `sessionStarted` |
| `UserPromptSubmit` | phase `thinking`, 턴 요약 초기화, `lastPrompt`(200자 제한), 스트리밍 텍스트 초기화, 미확인 완료 해제 |
| `PreToolUse` | phase `runningTool`, `currentActivity` 생성(툴 요약), 타임라인 추가. `AskUserQuestion` · `ExitPlanMode` 면 `waitingInput` + `needsInput`. 헬퍼가 답을 기다리고(지금 훅 설정) 노치에서 답할 수 있는 입력이면 요청 대기열에 넣고 요청 ID 반환 (질문 · 계획 승인 카드, 아래 "질문 · 계획 승인 카드") |
| `PostToolUse` | 해당 `tool_use_id` 활동 성공 처리, diff 계산(Edit/MultiEdit/Write/NotebookEdit/Bash `bashEditDiff`) → `lastDiff`, 턴 요약 누적, 신호 `edited` |
| `PostToolUseFailure` | 활동 실패 처리, phase `thinking` |
| `PermissionRequest` | `PermissionRequestInfo` 생성 → 대기열, phase `waitingPermission`, 신호 `permissionRequested`, 요청 ID 반환. 단 `AskUserQuestion` / `ExitPlanMode` 는 대기열에 넣지 않고 바로 결정 없음(Claude Code 가 `updatedInput` 없는 allow 를 무시하므로) → 입력 대기 카드 |
| `Notification` | `lastNotification` 갱신. `elicitation_dialog`/`agent_needs_input` → `waitingInput` + `needsInput`. `permission_prompt` 인데 해당 세션의 훅 대기 요청이 없으면 `waitingPermission` + `needsInput` (단 노치에서 "터미널로" 넘긴 질문 · 계획 승인 다이얼로그면 무시). `idle_prompt` → 작업 중 · 훅 대기 없는 승인 대기 · 입력 대기를 `idle` 로 정리 (터미널에서 거부/Esc 한 경우 약 60초 뒤 복구) |
| `MessageDisplay` | `delta` 를 세션과 따로 둔 `SessionStore.streamingTexts` 뒤에 붙임(최근 2000자 유지). 세션 · 포커스는 건드리지 않아 delta 마다 모든 화면이 다시 계산되지 않는다 (글을 보여주는 미리보기 · 완료 · 펼친 상세만 갱신) |
| `Stop` | phase `completed`, `lastAssistantMessage`, 미확인 완료 표시, 신호 `completed`, 해당 세션 남은 권한 대기 정리. `background_tasks` 로 백그라운드 작업 수(서브에이전트 포함)를 맞춤 |
| `StopFailure` | phase `failed`, `errorMessage`, 신호 `failed` |
| `SubagentStart` / `SubagentStop` | `activeSubagents` 증감. `SubagentStop` 의 `background_tasks` 로 셸 · 기타 백그라운드 수를 맞춤 |
| `PreCompact` / `PostCompact` | `compacting` / 이전 상태 복귀 |
| `SessionEnd` | 세션 제거, 해당 세션 권한 대기 정리 |

- 처음 보는 `session_id` 의 이벤트가 오면(앱을 세션 도중 켠 경우) payload 의 `cwd` 로 세션을 즉석 생성한다.
- 앱을 새로 띄우면 세션 목록이 비어서, 긴 Bash 처럼 툴이 도는 동안엔 다음 이벤트까지 그 세션이 보이지 않았다.
  그래서 켤 때 최근 대화 기록 끝부분으로 세션을 되살린다 (`SessionRestorer` → `TranscriptTail` → `SessionStore.restore`,
  설정 "앱을 켤 때 돌고 있던 세션 바로 보여주기", 기본 켬, 데모에서는 안 함).
  - `~/.claude/projects/<프로젝트>/<세션>.jsonl` 중 30분 안에 바뀐 것(최근 40개)의 끝 256KB 만 읽는다. 서브에이전트 기록은 보지 않는다.
  - 메인 대화 줄로 상태를 고른다: 결과 없는 마지막 `tool_use` → 툴 실행 중(질문 · 계획 승인이면 입력 대기),
    `stop_hook_summary` · `end_turn` · 사용자 중단 → 끝남(15분 안에 끝난 것만), 그 밖 → 응답 중. `entrypoint` 로 데스크톱 앱 세션을 알아본다.
  - 알림은 띄우지 않고, 이벤트로 먼저 알게 된 세션은 건드리지 않는다. 되살린 툴은 같은 `tool_use_id` 의 `PostToolUse` 로 끝난다.
- 오래된 권한 대기 정리: 다른 경로(터미널)에서 이미 답한 요청은 **같은 호출의** `PostToolUse` / `PostToolUseFailure`
  (같은 에이전트 · 툴 이름 · 입력)가 오면 결정 없음으로 풀어준다. 병렬 형제 툴이 있어서 `PreToolUse` 는 기준으로 쓰지 않는다.
  `UserPromptSubmit` · `Stop` · `StopFailure` · `SessionEnd` · `SubagentStop` 은 해당 범위의 대기를 모두 정리한다.
- 백그라운드 작업 수 (`backgroundTaskCount` = 서브에이전트 + 셸 + 기타):
  - 서브에이전트는 `SubagentStart` 로 본 `agent_id` 집합으로 센다 (`SessionStore.runningSubagents`).
    시작을 못 본 `SubagentStop` 은 무시한다: Claude 데스크톱 앱은 턴이 끝날 때마다 약 2초 뒤 시작 이벤트 없는 `SubagentStop`
    (내부 보조 작업)을 보내는데, 이걸 세면 도는 백그라운드 에이전트 수가 0 이 되고 타임라인에 가짜 "Agent" 가 붙고
    그 이벤트의 목록으로 셸 수까지 지워졌다 (라이브 로그로 확인).
  - 셸은 `PostToolUse` 의 Bash `run_in_background: true`, 기타는 `Monitor` 툴로 늘린다. 끝났다는 훅은 오지 않으므로
    턴이 끝날 때(`Stop` · `SubagentStop`) 오는 `background_tasks`(아직 도는 작업 목록, 끝난 상태 항목은 뺌)로 종류별 수를 다시 맞춘다.
  - `SubagentStop` 목록에는 지금 끝나는 서브에이전트가 남아 있을 수 있어서 서브에이전트 수는 `Stop` 에서만 맞춘다.
    `Stop` 목록의 서브에이전트 작업 ID 가 시작을 본 `agent_id` 와 같으면 그 ID 로 남기고(이후 `SubagentStop` 으로 끝낼 수 있게),
    모르는 작업은 `task:<id>` 로 세어 다음 `Stop` 에서 다시 맞춘다. 훅 헬퍼는 항목마다 `id` · `type` · `status` 만 넘긴다.
    목록이 없으면(작업 목록을 못 읽었거나 payload 를 줄임) 그대로 둔다.
  - 훅 헬퍼는 `background_tasks` 항목마다 `type` · `status` 만 남기고(명령 · 설명은 보내지 않음) `session_crons` 는 뺀다.
    payload 를 4 · 5단계로 줄여도 이 작은 목록은 남긴다.
  - **보이는 단계는 한 곳(`SessionStore.finalize`)에서 정한다.** 핸들러는 메인 턴 단계(`AgentSession.mainPhase`) · `mainTurnEnded` ·
    대기 목록(`waits`: 훅 요청 · 세션 앱 다이얼로그 대기, 주인 에이전트 · 호출 · 넘김 표시)만 바꾸고, 모든 진입점(ingest · 결정 · 넘김 ·
    끊김 · 시간 초과 · 멈춘 툴 확인 · 되살리기 · 확인 처리) 끝에서 finalize 가 승인 대기 > 입력 대기 > 앱 확인 대기(턴 진행 중) >
    메인 단계(끝난 턴이면 끝난 단계) 순으로 `phase` 를 정한다. 예전처럼 단계를 썼다가 가드로 되돌리지 않는다.
  - 메인 턴이 끝났다는 사실은 단계와 따로 기억한다 (`mainTurnEnded`: Stop · StopFailure · 중단 · idle_prompt ·
    끝난 채로 되살린 세션에서 true, UserPromptSubmit · SessionStart · 메인 에이전트의 툴 이벤트에서 false).
    턴이 끝난 뒤 서브에이전트(`agent_id` 있음)의 이벤트 · 결정은 메인 단계를 바꾸지 않는다 (`resumeTurn`). 턴 진행 중의 서브에이전트 툴은 턴의 작업으로 본다.
    앱을 새로 띄운 뒤 처음 보는 세션(턴 모름)은 서브에이전트 툴 호출이어도 작업 중으로 보여준다 (메인이 서브에이전트를 기다리는 중일 수 있음).
  - SubagentStart 를 못 봤어도(앱 재시작 등) `agent_id` 가 붙은 다른 이벤트가 오면 그 서브에이전트가 돈다고 센다.
    Stop 목록으로만 안 `task:X` 는 X 의 이벤트가 오면 X 로 바꾸고, `SubagentStop`(X) 이 `task:X` 도 지운다. 시작 없는 SubagentStop 은 여전히 무시.
  - Stop · UserPromptSubmit 은 아직 도는 서브에이전트의 활동(`ActivityItem.agentID`)을 닫지 않는다.
  - 이런 세션은 상태 문구를 "백그라운드 N개 작업 중" 으로 보여주고, 세션 상태 요약에서 진행 중(초록)으로 센다
    (`SessionStatusSummary.group(for: session)`).
  - 표시: 접힌 상태는 끝 요소(`+N −M` · 상태 문구) 뒤에 배지 "⧉ N"(0 이면 숨김, 폭은 `CompactMetrics.badge`).
    날개 · 한쪽 날개 · 알약은 끝 요소에 이어 센다(`trailingWithBadge`). 노치 아래 띠는 배지가 제목 줄에 함께 안 들어가면
    둘째 줄로 내리고(요약과 함께), 제목 줄 요소는 배지 없이 골라 메뉴바 알약과 같은 제목을 보여준다 (6장).
    펼친 화면은 세션 줄에 배지, 상세 머리에 "⧉ 3 서브에이전트 2 · 셸 1" (한 종류뿐이면 이름만).
- 모든 payload 필드는 선택적으로 취급한다 (버전에 따라 필드가 없거나 늘어날 수 있음). 세부 스키마는 `docs/hook-events.md`.

## 5. 주로 볼 세션 (포커스) 규칙

1. **끼어들기** — 주의가 필요한 세션이 있으면 그 세션이 포커스.
   우선순위: 권한 대기(오래된 요청 먼저) → 입력 대기 → 실패(미확인) → 완료(미확인).
2. 끼어들기가 없으면 **사용자가 직접 선택한 세션**(`focus(sessionID:)`) → 없으면 **고정 세션**.
3. 그것도 없으면 **작업 중인 세션 중 가장 최근 이벤트**. 단, 현재 포커스 세션이 아직 작업 중이면 바꾸지 않는다
   (작업 중 세션끼리 자동 전환으로 인한 깜빡임 방지).
4. 작업 중인 세션도 없으면 가장 최근 이벤트가 있었던 세션.

`rankedSessions` 정렬: 끼어들기 대상(위 우선순위) → 고정 → 작업 중(최근순) → 나머지(최근순). (SessionEnd 를 받은 세션은 목록에서 지운다)

## 6. 아일랜드 표시 모드

| 모드 | 트리거 | 내용 | 크기(대략, pt) |
|---|---|---|---|
| idle | 작업 중인 세션 없음 | 모든 세션 상태 요약 `● N` (아래 "세션 상태 요약"). 양쪽 날개면 왼쪽엔 작은 점, 오른쪽에 요약 | 노치폭+50 × 노치높이 |
| working | 포커스 세션 작업 중 | 왼쪽: 스피너 + 프로젝트명 / 오른쪽: 현재 툴 짧은 이름 + `+N −M`. 세션이 여럿이면 모든 세션 상태 요약도 | 노치폭+200 × 노치높이 |
| peek | `edited` 신호 (설정 on) | 파일명·줄번호, 미니 diff 3줄, 스트리밍 텍스트 한 줄 | 460 × 160 |
| permission | 훅 대기 요청 (`pendingPermissions`) | 권한 요청: 툴 · 명령어, [허용] [항상 허용] [거부] [접기] [터미널로]. 해결될 때까지 유지 (아래 "권한 카드 안전 규칙"). 질문 · 계획 승인도 같은 모드 · 대기열의 다른 카드 (아래 "질문 · 계획 승인 카드") | 480 × 170 (질문은 선택지 수만큼) |
| needsInput | `needsInput` | 질문 메시지 + [터미널로] | 440 × 110 |
| done / failed | `completed` / `failed` | 체크(또는 경고) + 소요 시간, 변경 파일 수 `+N −M`, 마지막 응답 한 줄. 일정 시간 후 접힘 | 430 × 105 |
| expanded | 아일랜드 클릭 | 머리: "세션 N" + 모든 세션 상태 요약 / 왼쪽: 세션 목록(우선순위순, 고정 핀) / 오른쪽: 포커스 세션 타임라인 · diff · 최근 응답 | 620 × 300 |

- 접힌 상태(idle/working)는 노치 양옆 "날개"에만 내용을 둔다. 가운데 노치 폭만큼은 비워 카메라를 가리지 않는다.
- 펼친 상태의 내용(상단 행 포함)은 모두 부분 2(카드 몸통) 안, 부분 1(접힌 모양) 아래에 둔다.
- 노치 없는 화면(외부 모니터): 접힌 상태는 **메뉴바 안**의 빈 공간에 들어가는 알약 (8-1 의 "노치 없는 화면" 참고). 한 줄 (스피너 + 프로젝트 · 툴 + `+N −M`).
- 접힌 상태(날개 · 노치 아래 띠 · 알약 · 한쪽 날개)의 툴은 어디서나 **짧은 이름**만: `Bash` · `Edit` · `Read` · `Grep` · `Agent`,
  MCP 툴은 서버 이름(`Claude_Browser`). `ToolSummarizer` 가 `ToolSummary.label` → `ActivityItem.label` 로 넘기고
  (`IslandFormat.shortToolTitle`), 폭 측정(`CompactMetrics.tool`) · 요소 고르기 · 폭 붙잡기도 이 이름 폭을 쓴다.
  명령 · 경로 · MCP 툴 이름은 펼친 타임라인과 카드(피크는 파일, 권한 카드는 전체 명령)에서 보여준다.
- 노치 아래 띠와 메뉴바 알약은 **같은 규칙으로 요소를 고른다** (`IslandLayoutEngine.lineItems`: 같은 후보 순서 `pillVariants` ·
  같은 제목 최소 폭 `pillProjectMin` 40pt · `pillToolMin` 64pt, 틀 `LineChrome` 만 다름). 그래서 두 화면이 같은 세션 상태면
  자리가 되는 한 같은 내용이다 (예: 둘 다 "agent-notch · 생각 중"). 띠 폭은 노치 폭 그대로이고 백그라운드 배지 · 요약은 둘째 줄로
  내릴 수 있다. 띠의 제목 줄 요소는 배지 · 요약 없이 고르므로(`LineChrome.wraps`) 배지가 있어도 두 화면 제목이 같다
  (예: 알약 "api-server · Bash +12 −3 ⧉ 3 ● 2", 띠 첫 줄 "api-server · Bash +12 −3" · 둘째 줄 "⧉ 3 ● 2").
  모두 줄이지 않은 제목 줄 한 줄에 들어가면 한 줄 그대로다 (`stripWraps`).
- 전환 애니메이션 (접힘 ↔ 펼침 깨짐 · 분리 · 울렁임 수정 후):
  - 모드가 바뀌는 크기 전환은 `spring(response: 0.4, dampingFraction: 0.9)`, 같은 모드 안 크기 조정은 `spring(response: 0.32, dampingFraction: 1.0)`.
    노치에 붙는 모양이 넘쳐서(overshoot) 하드웨어 노치가 삐져나오거나 노치 옆이 드러나지 않게 한다. 동작 줄이기 설정이면 바로 바뀐다.
  - 아일랜드는 어느 프레임에서도 **하나의 이어진 검은 모양**이다. 접힌 모양도 "목 + 몸통" 구조로 그려서 펼칠 때 모양 구조가 바뀌지 않고,
    항상 노치 사각형을 덮으며 화면 위 끝에 붙어 있다. 몸통은 메뉴바 아래에서만 넓어진다.
  - 검정 모양 · 잘라내기 · 클릭 모양은 **패널 전체 기준으로 스펙 하나(`IslandPanelShape`)에서** 그린다.
    원점 · 크기(`frameWidth` · `frameHeight`)까지 모양 스펙의 `animatableData` 로 함께 보간한다.
    예전처럼 프레임 크기 · `.offset` 을 따로 애니메이션하면 계산상 같은 곡선이어도 실제 SwiftUI 에서는 빠르게 다시 누를 때(스프링 재조준) ·
    프레임이 밀릴 때 모양 보간과 어긋나, 접을 때 부분 1 이 오른쪽으로 튀었다 돌아오거나 넓어져 보였다
    (레이아웃 로그로는 부분 1 값이 그대로였고 실제 화면에서만 보였다).
  - 내용은 모양이 대부분 자리잡은 뒤(약 220ms) 바뀐다. 사라지는 내용은 그 내용을 배치한 레이아웃 자리에 그대로 머문 채 흐려진다.
  - **부분 1 은 접힌 모양 그대로, 부분 2 만 자라고 줄어든다**: 접힌 모양(노치 화면의 띠 · 노치 아래 띠 · 선,
    노치 없는 화면의 메뉴바 알약 · 점 · 메뉴바 아래 알약)을 부분 1, 그 아래로 펼쳐지는 카드 몸통을 부분 2 라 한다.
    펼친 카드의 부분 1 은 직전에 그린 접힌 모양 그대로다 (자리 · 폭 · 높이 · 귀 · 위 · 아래 반경, `IslandShapeSpec.part1`).
    펼치고 접는 동안 부분 1 은 조금도 바뀌지 않고(양 끝 값이 같아 보간해도 그대로), 부분 2 만 부분 1 아래에서 나왔다가 그리로 들어간다.
    - 카드 상단 행은 부분 1 안에 두지 않는다 (예전처럼 넓은 띠 · 알약 안에 상단 행을 두면 부분 1 이 카드의 일부처럼 보여
      접을 때 부분 1 이 부분 2 크기를 따라가는 것처럼 보였다). 카드가 열려 있는 동안 부분 1 은 빈 검정이다.
    - 부분 2 는 부분 1 아래끝에서 나온다. 낮을 때(펼치기 시작 · 접히기 끝)는 부분 1 아래 모서리 안쪽으로 좁아
      부분 1 의 둥근 아래 모서리가 그대로 드러나고, 메뉴바 아래 넓어질 자리가 생기는 높이에서 부분 1 폭을 지나 넓어진다
      (`IslandShape.emergeLimit`). 넓어지는 쪽은 처음부터 12pt 넓게 두어, 몸통이 부분 1 과 옆면을 맞댄 채 늘어나
      부분 1 이 커져 보이는 순간이 없다.
    - 메뉴바 안 점처럼 아래 변이 없는 부분 1 은 몸통이 아래 모서리 안쪽에 숨을 폭이 없어 폭 0 으로 좁아진다. 몸통이 폭 0 인 순간
      (펼치기 시작 · 접히기 끝)은 몸통이 점 안에 숨는다.
    - **불리언 연산을 쓰지 않는다.** 주 외곽선과 부분 1 은 한 경로의 하위 경로로 넣고 nonzero 로 칠한다 (`IslandShape.filledPath`).
      예전 CG 합집합은 목 · 부분 1 이 겹치거나 한 점에서 맞닿는 곳에 넓이 0 조각을 덧붙여, 몸통 숨기기(`hidesBody`) ·
      조각 정리(`removingSlivers`) 같은 덧대기가 필요했다.
    - SwiftUI 래스터는 겹친 하위 경로의 가장자리 덮임을 더한다 (같은 원 둘이면 가장자리가 최대 107/255 진해짐).
      그래서 부분 1 과 함께 그리는 주 외곽선은 귀를 빼고 둥근 위 모서리를 현으로 깎는다 (`path(_:underPart1:)`).
      빼고 깎은 자리는 부분 1 안이라 합친 모양은 같고, 곡선 가장자리는 접힌 상태와 똑같이 그려진다.
    - 클릭 모양(`IslandHitShape`)도 그린 모양에 클릭 영역(`hitRects`)을 `addRect` 로 이어 붙인다 (불리언 연산 없음).
    - 카드가 열려 있는 동안엔 그 띠를 접힌 날개 이력으로 기억해 띠가 그대로이고, 접을 때도 같은 띠에서 시작한다.
    - 카드의 부분 1 은 지금 접힌 내용이 아니라 **직전에 그린 접힌 내용**(`LayoutHistory.compactContent`, 화면별)으로 그린다.
      카드를 여는 순간(펼치면 완료 확인 → 쉬는 중, 권한 요청으로 보여주는 세션이 바뀜) · 열린 동안(다른 세션 요약 · 보여주는 세션 ·
      툴 이름이 바뀜) 접힌 내용이 바뀌어도 부분 1 의 자리 · 폭 · 모양이 그대로다 (날개 폭 · 노치 아래 띠 높이 · 메뉴바 아래 알약 폭도).
      접힌 상태를 그리지 않고(숨김) 연 카드만 그때 내용으로 새로 계산하고, 그 내용을 카드가 열린 동안 쓴다.
    - 카드가 열려 있는 동안 접힌 내용이 바뀌었으면 접히는 동안에도 카드의 부분 1 을 그대로 붙잡고(`LayoutHistory.collapseHold`,
      모양이 자리 잡는 450ms. 아래 반경 · 띠 높이 · 날개 · 메뉴바 안 알약 · 메뉴바 아래 알약 폭도 그대로, 알약 요소만 지금 내용으로),
      그 뒤 접힌 상태 안의 변화(adjust)로 새 접힌 모양이 된다 (실제로 내용이 바뀐 만큼만 움직인다). 메뉴바가 바뀌어 카드 띠가
      더 이상 맞지 않으면 붙잡지 않는다.
    - **화면 상태는 관찰 패스의 커밋 한 곳에서만 바뀐다.** `PresentationController` 의 `mode` · `layout` · `compactContent` 는
      스토어 · 설정 · 화면 · 시각 · 커밋된 배치 이력(`LayoutHistory`)만 읽는 순수 계산이다. 모드가 바뀌며 일어날 일
      (카드 띠 붙잡기 · 놓기 · 만료)은 `LayoutHistory.advance` 가 계산 안에서 미리 적용해 커밋 전후가 같은 값이다.
      `ScreenManager` 관찰 패스가 `frames` 를 계산 → `commit`(이력 저장 · 사라진 화면 정리 · 띠 놓기 예약 · 접힌 폭 안정화 ·
      피크 높이 · 로그) → 패널 적용 순으로 돌고, 스냅숏도 같은 커밋 단계(`commitScreens`)를 쓴다.
      예전엔 getter 가 그리면서 이력 · 붙잡은 폭 · 타이머를 바꿔, 계산 순서에 따라 결과가 달라질 수 있었다.
    - 디버그 로그: 화면의 레이아웃이 바뀔 때만 `Presentation` 카테고리 `.debug` 로 숫자만 남긴다 (화면 ID · 모드 종류 · 크기 · 원점 ·
      부분 1 사각형 · 접힌 자리 종류, 세션 이름 · 내용 없음).
      `log stream --level debug --predicate 'subsystem == "com.ldg.agent-notch" && category == "Presentation"'`
  - 카드 몸통 폭 = 카드 폭 이상, 부분 1 위 조각(띠 · 알약)보다 쪽마다 12pt 이상 넓게(`bodySnap`), 되도록 노치(알약) 가운데.
    몸통이 부분 1 과 옆면을 맞대거나 거의 겹친 이음매가 생기지 않는다.
  - 이음매: 목 · 몸통 끝 차이 d 가 있는 쪽은 목 쪽 모서리 + 몸통 쪽 모서리(오목 + 볼록) 반경 합이 d 를 넘지 않게 비율대로 줄여
    하나의 S 곡선으로 잇는다. d 가 1pt 미만이면 모서리 없는 곧은 옆면 (1 → 2pt 에서 이어서 벌어짐).
    목 아래 볼록 모서리와 몸통 위 볼록 모서리는 한쪽에 함께 생기지 않는다 (맞물려 안으로 물린 모양 없음).
    메뉴바 아래 몸통 높이가 모자란 펼치기 시작 · 접히기 끝에는 넓어지는 폭을 줄여 S 곡선이 옆면 안에 다 들어가게 한다.
    몸통이 부분 1 보다 좁을 때 부분 1 쪽 볼록 모서리는 부분 1 아래 반경을 넘지 않는다 (그 너머는 부분 1 아래 변이 그대로 드러남).
  - 울렁임 방지: 접힌 폭은 바뀐 뒤 약 4초 동안 유지하고(줄어드는 쪽만 늦춤), 날개 배치는 이력을 두어 내용 폭이 문턱 근처를
    오가도 뒤집히지 않는다. 상태 아이템 시작(메뉴바 안 알약 자리)의 2pt 미만 측정 흔들림은 무시한다.
  - 전환별 프레임은 `--render-island 'anim-<전>-<후>'` 로 24장 시트를 그려 확인하고, 모양 검사 · 이음매 검사 위반을 출력한다
    (8-1 "검증: 스냅숏 렌더링").
- 세션 상태 요약 (`SessionStatusSummary`, `SessionSummaryChips`):
  - 묶음: **기다리는 중**(주황, 권한 · 입력 대기 · 실패) → **진행 중**(초록, 추론 · 툴 실행 · 압축) → **끝남**(회색, 완료 · 유휴).
    0 인 묶음은 뺀다.
  - 모양: 묶음마다 `● N` (6pt 점은 묶음 색, 숫자는 11pt 고정폭 보조 글자색 — `+N −M` 과 헷갈리지 않게). 늘 통째로 그린다.
  - 무엇을 세는지: 어디서나 모든 세션 (합계가 펼친 머리의 "세션 N" 과 같다). 접힌 working 도 보여주는 세션을 함께 센다
    (`PresentationController.compactSummary`). 예전엔 보여주는 세션을 빼고 세서 같은 순간에도 접힌 상태 "● 1" · 펼친 머리 "● 2" 처럼
    개수가 달라 보였고, 보여주는 세션이 바뀔 때마다 개수가 바뀌었다. 세션이 보여주는 세션 하나뿐이면 접힌 상태엔 요약을 그리지 않는다.
  - 접힌 상태에서 놓는 자리 (요약은 끝까지 남기고 툴 이름 → 프로젝트명 순으로 줄인다):
    - 양쪽 날개: 왼쪽 프로젝트명 뒤 → 오른쪽 날개 노치 쪽(툴 · `+N −M` 은 바깥 끝) → 툴 이름 빼고 오른쪽 →
      프로젝트명 줄이고 왼쪽 → 프로젝트명 빼고 왼쪽. 요약 때문에 날개는 한쪽 최대 40pt 더 넓어진다.
    - 한쪽 날개: 상태 + (프로젝트) + 요약 + (툴) + `+N −M`. 알약: 상태 + (프로젝트 · 툴) + `+N −M` + 요약.
    - 노치 아래 띠: 알약과 같은 요소. 백그라운드 배지 · 요약이 줄이지 않은 제목 줄에 함께 안 들어가면 띠를 14pt 높여
      배지 · 요약을 둘째 줄에 둔다 (폭은 노치 폭 그대로, `stripWraps`).
    - 최소 표시(선)에는 넣지 않는다.
  - 펼친 머리: "세션 N" 옆. 자리가 모자라면 요약만 남긴다.
  - 출렁임 방지: 요약 폭은 자릿수로만 정해져 개수가 한 자리 안에서 바뀌면 폭이 같다. 툴 이름처럼 `CompactMetricsHold` 로 붙잡고,
    요약을 새로 넣거나 반대쪽 날개로 옮길 때는 8pt 여유가 더 있어야 한다. 오른쪽 날개의 요약은 노치 쪽에 고정해
    툴 이름 · diff 자릿수가 바뀌어도 움직이지 않는다.
  - 읽어 주기: "전체 세션 기다리는 중 1개, 진행 중 1개, 끝남 2개".
- 우선순위: permission > needsInput > expanded(사용자가 연 경우) > done/failed > peek > working > idle.
- 아일랜드는 활성화하지 않는 패널(non-activating)이라 알림이 와도 다른 앱의 키보드 포커스를 뺏지 않는다.
  사용자가 아일랜드를 클릭해 키 윈도우가 됐을 때만 단축키가 동작한다:
  `⌘↩` 허용, `⌥⌘↩` 항상 허용, `⌘⌫` 거부, `⎋` 접기(요청은 대기 유지).
  질문 카드: `1`–`4` 선택지, `↩` · `⌘↩` 다음 · 보내기 ("기타" 입력란에 커서가 있으면 숫자 · `↩` 는 입력란이 받고 `↩` 는 입력란에서 보내기).
  계획 카드: `↩` · `⌘↩` 승인. 질문 · 계획 카드의 행 · 버튼을 누르면 그 패널이 키 윈도우가 된다 (카드가 뜨기만 해서는 포커스를 뺏지 않음).

### 질문 · 계획 승인 카드 (AskUserQuestion · ExitPlanMode)

Claude 의 객관식 질문과 계획 승인을 다이얼로그 대신 노치에서 답한다. 권한 요청과 **같은 대기열 · 같은 모드(`permission`) · 같은 카드 레이아웃**
(`PresentationController` 의 카드 경로, 부분 1 규칙 · 노치 화면 · 외부 모니터 알약 모두 같음)을 쓰고 `PermissionRequestInfo.kind` 로 구분한다.

- 대기열에 넣는 조건: 헬퍼가 답을 기다리는 `PreToolUse`(지금 훅 설정), payload 를 줄이지 않음(원래 입력을 그대로 돌려줘야 함),
  해석 가능한 입력(`InteractionParser`: 질문 1–4개 · 선택지 1–4개 · 질문 원문이 비지 않고 겹치지 않음, 계획은 내용이 있을 때).
  아니면 nil → 훅은 바로 결정 없음 → Claude Code 다이얼로그 + 입력 대기 카드 (예전과 같음).
- 질문 카드: 상단 행 "답변 필요" (대기열이 여럿이면 " · N"), 머리말 칩 + 질문(2줄까지), 선택지 행(번호 · 이름 · 한 줄 설명),
  "기타" 직접 입력 행, [이전] … [접기] [터미널로 · Claude로] [다음 · 보내기 ↩].
  - 권장 선택지: 이름 끝의 "(Recommended)" · "(권장)" · "(추천)" 을 떼고 이름 옆에 초록 "권장" 배지 (Claude 앱 질문 창과 같은 정보).
    답은 원래 이름 그대로 보낸다 (`QuestionOption.isRecommended` · `displayLabel`).
  - 한 개만 고르는 질문: 행을 누르면 그 질문의 답 → 다음 쪽(아직 답하지 않은 질문 먼저). 마지막 쪽에서 모두 답했으면 바로 보낸다.
    카드가 나타난 지 0.5초(`shortcutSettleDelay`) 안의 클릭은 고르기만 하고 보내지 않는다 (카드가 뜨는 순간의 잘못된 클릭).
  - 여러 개 고르는 질문: 행을 켜고 끈 뒤 [다음] · [보내기]. "기타" 에 글자를 쓰면 기타를 고른 것 (한 개 고르는 질문이면 선택지 대신).
  - 여러 질문은 쪽 넘김 "1/2". 카드 높이는 모든 질문 중 가장 큰 쪽에 맞춰(`QuestionCardModel`) 쪽을 넘겨도 카드 크기가 바뀌지 않는다.
  - 고르는 중인 답(`QuestionDraft`)은 요청마다 메모리에만 두고, 접었다 펼쳐도 남는다. 요청이 대기열에서 빠지면 지운다.
  - "기타" 입력란은 아일랜드 안의 유일한 AppKit 컨트롤(TextField)이다. 스냅숏에서는 같은 자리의 글자 그림으로 대신한다.
- 계획 카드: 상단 행 "승인 필요", "계획" 칩 + 제목(첫 줄), 다음 5줄 미리보기, 계획 파일 이름 · 줄 수 · [파일 열기], [접기] [터미널로] [승인 ⌘↩].
  계획은 카드에 다 들어가지 않으므로 파일 열기로 전체를 본다 (권한 카드처럼 승인을 막지는 않는다: 승인해도 이후 툴 호출은 권한 규칙을 따른다).
- 권한 요청과 같은 정책: 대기 시간 `permissionTimeout`(기본 120초)이 지나면 결정 없이 넘겨 다이얼로그가 뜬다(입력 대기 카드로 안내),
  세션의 터미널 · 앱이 이미 앞에 있으면(`passthroughWhenTerminalFrontmost`) 바로 넘긴다(입력 대기 카드), 대기열 · 포커스 우선순위도 같다.
- 훅 연결이 응답 전에 끊기면(Claude Code 에서 Esc · 중단 · 종료) 카드를 내리고 입력 대기도 푼다 (그 툴은 실패, 세션은 쉬는 중).
- [터미널로 · Claude로] (`SessionStore.handOff`): 결정 없이 넘기고 세션 앱으로 이동한다. 같은 호출로 이어서 오는 `PermissionRequest` ·
  `permission_prompt` 알림에 입력 대기 카드를 다시 띄우지 않는다 (넘김 표시는 넘긴 그 질문의 대기에 붙고, 그 대기가 끝나면 같이 풀림).
  권한 요청의 [터미널로] 는 예전처럼 "터미널에서 승인 필요" 카드로 안내한다.
- 접힌 상태는 입력 대기(주황 점), 툴 이름은 `질문` · `Plan`. 질문 카드가 열려 있거나 접혀 있는 동안 같은 세션의 입력 대기 카드는 띄우지 않는다.
- 개인정보: 질문 · 답 · 계획 글자는 메모리에만 두고 디스크 · 로그에 남기지 않는다 (로그는 "질문 답 전달" 같은 문구만).

### 권한 카드 안전 규칙

- 명령의 안 보이는 문자를 드러낸다: 줄바꿈 `⏎`, 9개 이상 연속 공백 `␣×N`, 제어 · bidi · 폭 0 문자 `\u{…}`. MCP 툴은 인자 JSON 을 보여준다.
- 상세가 카드에 다 안 보이면(4줄 초과, 글자 수 제한, 헬퍼의 payload 축소) **노치에서 허용 · 항상 허용을 막고** "터미널로" 를 강조한다.
  거부 · 접기는 가능. (여러 줄 heredoc 명령도 막히므로 줄 수 한도는 사용해 보며 조정)
- "항상 허용" 이 가능할 때는 저장될 규칙과 범위(`permission_suggestions` 요약)를 카드에 표시한다.
- 보이는 요청이 바뀌면 키 윈도우를 반납한다. **승인(허용 · 항상 허용 · 계획 승인 · 답 보내기)은 클릭이든 단축키든 그 요청이 카드에 보인 지
  0.5초가 지나야 전달한다** (요청 ID 마다, 가려지거나 접었다 다시 보이면 다시 잰다). 거부 · 접기 · 터미널로는 바로.
  시계는 모드를 계산한 때가 아니라 `IslandContainer` 가 내용 교체를 끝내 그 카드가 실제로 나타난 때 시작한다
  (`contentWillChange` 로 지우고 `contentDidAppear` 로 시작). 예전엔 교체 지연(0.22 · 0.34초)만큼 보호가 줄어 실제로는 0.28 · 0.16초였다.
  대기열의 다음 요청은 이전 카드가 흐려진 뒤 나타난다 (같은 높이 카드에서 더블클릭이 다음 요청까지 승인하던 문제).
- Bash 요청에 `dangerouslyDisableSandbox` 가 켜져 있으면 제목 "· 샌드박스 해제" 와 경고 줄, `run_in_background` 면 제목 "· 백그라운드".
- 훅 대기 없이 터미널 · Claude 앱에서 기다리는 승인 · 입력 대기(터미널로 넘김, 시간 초과, `permission_prompt` 알림, 넘긴 질문)는
  주인(에이전트 · 호출)을 기억해 다른 에이전트의 툴 이벤트로 지워지지 않는다 (대기 목록 `waits`, 지우는 규칙은 `releaseWaits` 하나).
  Stop · UserPromptSubmit · StopFailure 는 메인 에이전트의 훅 요청만 푼다 (백그라운드 서브에이전트 요청은 남김).
- 권한 요청 훅 연결이 끊기면(Esc · 중단, Claude 앱 창에서 먼저 답함) 승인 대기에서 빠져나온다 (Claude 앱이면 실행 · 생각 중, 터미널이면 쉬는 중).
- Claude 데스크톱 앱 자체 확인 창(화면 제어 · 폴더 · 사이트 승인)은 훅으로 오지 않아, 확인 창을 띄우는 툴이 안 끝나면 "Claude 앱에서 확인이 필요할 수
  있어요" 카드로 추정한다 (`AppConsentHeuristic`, **허용 목록**): computer-use `request_access` · `request_full_control` ·
  `request_teach_access`, 디렉터리 `request_directory` · `change_directory`, 브라우저 `navigate` · 브라우저 선택은 2.5초,
  첫 방문 사이트 승인을 띄울 수 있는 브라우저 페이지 툴(computer · find · form_input · get_page_text · javascript_tool · read_page)은 8초,
  나머지(앱 실행 · 스크린샷 · 일괄 실행 등)는 보지 않는다. 예전엔 접두사 아래 모든 툴을 보고 느린 호출이 가짜 카드로 포커스를 가져갔다.

### 색상 (아일랜드는 항상 검정 배경 — 라이트/다크 공통)

| 용도 | 값 |
|---|---|
| 배경 | `#000000` (하드웨어 노치와 이음매 없이) |
| 기본 텍스트 | `#F1EFE8` |
| 보조 텍스트 | `#B4B2A9` |
| 흐린 텍스트 | `#888780` |
| 진행/추가 (초록) | `#97C459`, diff 배경 `rgba(99,153,34,0.2)` |
| 삭제/실패 (빨강) | `#F09595`, diff 배경 `rgba(226,75,74,0.2)` |
| 주의 (주황) | `#EF9F27` |
| 행 배경/버튼 | `#2C2C2A` |

## 7. 멀티 모니터

- `NSScreen.screens` 마다 패널 하나. `NSApplication.didChangeScreenParametersNotification` 으로 재구성.
- 노치 감지: `safeAreaInsets.top > 0`. 노치 폭 = `frame.width − auxiliaryTopLeftArea.width − auxiliaryTopRightArea.width`,
  노치 높이 = `safeAreaInsets.top`.
- `DisplayPolicy`
  - `allScreens`: 접힌 상태는 모든 화면, 일시적 펼침(peek/permission/done 등)은 **마우스가 있는 화면**에서만.
  - `activeScreen`: 마우스가 있는 화면에서만 표시.
  - `builtInOnly`: 내장(노치) 화면에서만 표시.
- 사용자가 직접 펼친(expanded) 아일랜드는 클릭한 화면에서만 펼친다.
- `FullscreenBehavior` (풀스크린 감지는 best-effort: 해당 화면 앞 앱의 창이 화면 전체를 덮고 메뉴바가 숨겨진 경우)
  - `showAll` / `alertsOnly`(permission·needsInput 만) / `hide`.

## 8. 패널(창) 동작

- `NSPanel`, `styleMask: [.borderless, .nonactivatingPanel]`, 투명 배경, 그림자 없음.
- `level`: 메뉴바 위 (`.statusBar` 보다 높게). `collectionBehavior: [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`.
- 패널은 최대 크기로 고정해 두고(아일랜드가 커져도 창 크기를 애니메이션하지 않음), 마우스가 아일랜드 영역 밖이면
  `ignoresMouseEvents = true` 로 클릭을 아래 앱에 통과시킨다 (전역/로컬 mouseMoved 모니터).

## 8-1. 메뉴바 · 다른 앱과의 겹침 처리

노치 양옆 메뉴바는 다른 앱의 상태 아이콘(오른쪽)과 앞 앱의 메뉴(왼쪽)가 쓰는 자리다. 노치 아래 방식은 이것들을 덮지 않고,
넓은 노치 방식은 덮되 마우스를 올리면 비켜준다.

### 메뉴바 측정 (`MenuBarSpaceMonitor`)

- 창 목록(`CGWindowList`, 권한 불필요, 메인 스레드 밖, 1ms 미만)으로 화면마다 메뉴바 높이 · 보임 여부와
  상태 아이템 창의 왼쪽 끝을 잰다. 2pt 미만 흔들림은 이전 값을 둔다.
  - 앞 앱 메뉴는 잴 수 없다. macOS 27 은 상태 아이템이 창 목록에 나오지 않아 상태 아이템 시작도 못 잰다
    → 노치 없는 화면은 추정값을 쓴다 (아래 "노치 없는 화면").
  - 손쉬운 사용(AX) 권한으로 앱 메뉴 · 상태 아이콘 위치를 재던 기능은 없앴다. ad-hoc 서명이라 빌드 · 업데이트마다 권한이 풀리고,
    macOS 27 에서는 사실상 동작하지 않았다.
- 다시 재는 시점: 앞 앱 변경 · 앱 실행/종료(`NSWorkspace` 알림), 화면 구성 변경, 1초 주기(가벼운 폴링, 접힌 상태일 때만).
- 여백 8pt 를 남긴다.

### 노치 화면 표시 방식 (`NotchStyle`)

사용자가 두 방식 중 고른다 (설정 > 표시 > 노치 화면 표시).

- **노치 양옆 (날개, 기본)** — 카메라(노치)를 가운데 두고 양옆 메뉴바 자리를 날개로 쓴다 (목업 기본형).
  - 날개는 메뉴바 아이콘 · 앱 메뉴를 덮는다. **마우스를 날개 위에 두면(약 120ms) 그쪽 날개가 노치 안으로 들어가**
    아래 아이템을 클릭할 수 있고, 마우스가 떠나면(약 0.6초 뒤) 다시 나온다 (`WingRetractTracker`). 노치(카메라) 가운데는 항상 클릭 가능(펼치기).
  - 한쪽 날개는 화면의 노치 옆 영역(여백 8pt 제외)까지 쓸 수 있다 (`wingLimit`).
  - 다른 노치 앱이 감지되면 노치 아래 방식으로 바꾼다.
- **노치 아래** — 아래 "노치 아래 방식" 대로, 메뉴바를 전혀 가리지 않는다.

#### macOS 27 메뉴바 아이콘 접기 (확인 결과)

- macOS 27 은 상태 아이콘이 넘치면 노치 쪽 아이콘부터 `«` 버튼 뒤로 **자동으로 접는다** (⌘-드래그로 순서 변경, 고를 수는 없음).
- 메뉴바 전체가 MenuBarAgent 창 하나로 그려져서, 예전 Bartender · Ice 처럼 넓은 상태 아이템으로 다른 아이콘을 밀어내는 방식이 안 된다.
  직접 실험해 보니 폭 넓은 상태 아이템을 추가하면 **우리 아이템이 가장 먼저 접혔다.** → 다른 앱 아이콘을 접게 만들 공개 API 는 없다.
- 메뉴바보다 낮은 레벨(23)에 검은 창을 깔면(창 위치 제한 `constrainFrameRect` 를 꺼야 메뉴바 자리에 놓인다) 투명한 메뉴바 뒤로
  비쳐 보이고 아이콘은 그 위에 그려지지만, **아이콘 색은 배경화면 밝기를 따라가서** 밝은 배경화면이면 검은 바탕 위에서 안 보인다.
  → 날개는 메뉴바 위에 두고 아이콘을 덮되, 마우스를 올리면 비켜준다.
- 아이콘을 캡처해 흰색으로 다시 그리는 방법은 화면 기록 권한과 상시 녹화 표시가 필요해서 쓰지 않는다.
- 아이콘 자체를 줄이려면 시스템 설정 > 메뉴 막대에서 숨긴다.

### 노치 아래 방식

노치 아래 방식(또는 다른 노치 앱이 노치를 쓸 때)은 노치 옆 메뉴바와 관계없이 늘 노치 아래에 표시한다
(메뉴바 아이템과는 겹치지 않고, 창 제목 표시줄 일부만 덮음. 마우스가 없으면 클릭 통과).

1. **노치 아래 띠** — 노치 바로 아래로 22pt 높이의 띠를 내려 그 안에 표시한다.
   요소는 메뉴바 알약과 같은 규칙 (상태 + 프로젝트 · 짧은 툴 이름 + `+N −M`, 6장 참고).
2. **최소 표시** — 설정(노치 아래 표시 > 선만)에서 고르면 띠 대신 노치 아래 가장자리에 상태 색 선(3pt)만 표시.

설정 `CompactOverlapStyle`: `belowNotch`(기본) / `minimal`. 예전엔 손쉬운 사용으로 잰 노치 옆 빈 곳에 날개(양쪽 · 한쪽)를 두기도 했지만 없앴다.

### 노치 없는 화면 (외부 모니터)

노치가 없으니 아일랜드를 메뉴바 **아래**에 두면 브라우저 탭 · 툴바 · 앱 메뉴 바로 아래를 가린다. 그래서 접힌 상태는 **메뉴바 안**에 넣는다.

- `ExternalDisplayStyle` 설정: `inMenuBar`(기본) / `belowMenuBar`(예전 방식) / `hidden`.
- `inMenuBar`:
  - 알약 높이 = 메뉴바 높이 − 4pt, 메뉴바 띠 안에서 세로 가운데.
  - 가로 위치: 앱 메뉴 오른쪽 끝과 상태 아이템 왼쪽 끝 사이의 빈 구간을 구하고, 화면 가운데가 그 안에 들어가면 가운데,
    아니면 가장 넓은 빈 구간의 가운데. 폭은 빈 구간 − 여백 16pt 이내로 줄이고 내용도 그에 맞게 생략.
  - 앱 메뉴는 잴 수 없어 **왼쪽 45% (최대 900pt)** 를 차지한다고 가정한다 (`estimatedAppMenuEnd`).
    상태 아이템 시작은 창 목록으로 잰 값을 쓰고, 못 재면(macOS 27) **오른쪽 40% (최대 760pt)** 를 차지한다고 가정.
  - 빈 구간이 최소 폭(80pt)보다 좁으면 12pt 점 하나로 줄이고, 그것도 안 되면 접힌 상태는 숨긴다(알림은 표시).
  - 메뉴바가 숨겨진 화면(자동 숨김 · 풀스크린)에서는 접힌 상태를 숨긴다. 메뉴바 표시 여부는 창 목록의 메인 메뉴 레벨 창으로
    판단한다 (외부 모니터에서 메뉴바가 보이는데도 `visibleFrame == frame` 인 경우가 있어서 `visibleFrame` 은 보조로만 사용).
  - 카드는 메뉴바 알약(부분 1) 아래로 내려온다. 카드가 열려 있는 동안 알약은 빈 검정이고, 상단 행은 알약 아래 카드 몸통 안에 둔다.
    부분 1 알약은 직전에 그린 알약 그대로다 (`lastPill` · `lastPart1`: 아직 빈 구간 안이면 그 자리 · 폭 · 모양,
    빈 구간이 줄었으면 들어가는 만큼만 줄임). 펼치고 접는 동안 알약은 크기 · 자리 · 반경이 조금도 바뀌지 않고, 카드 몸통만
    알약 아래에서 나왔다가 들어간다. 접히는 동안에도 카드의 알약을 붙잡았다가 모양이 자리 잡은 뒤 지금 내용 폭으로 바뀐다.
    카드를 여는 순간 · 열린 동안 접힌 내용이 바뀌어도 알약은 직전 접힌 내용으로 그린다 (`LayoutHistory.compactContent`, 6장).
    메뉴바 아래 알약(`belowMenuBar`)도 같다 (쉬는 중 ↔ 작업 중으로 폭이 바뀌는 내용이어도 카드가 열린 동안 · 접히는 동안 그대로).
    메뉴바 안 점 · 메뉴바 아래 알약도 같다 (점은 그대로 두고 메뉴바 아래에서 카드가 넓어진다).
- 펼친 카드(peek / permission / done / expanded)는 메뉴바 알약에서 아래로 내려온다. 화면 아래 내용을 덮으므로:
  - peek · done 은 짧게 보이고 자동으로 접힌다.
  - 카드 밖을 클릭하거나 `⎋` 를 누르면 즉시 접힌다.
  - 권한 카드는 "접기" 로 알약(주황 점 깜빡임)으로 줄일 수 있고, 알약을 클릭하면 다시 펼친다. 요청은 그대로 대기.
  - 카드 폭은 460pt 이내.
- 내장(노치) 화면에서도 펼친 카드가 메뉴바 아래를 덮는 것은 같으므로 위 규칙(자동 접힘, 바깥 클릭/⎋ 로 접기, 권한 카드 접기)을 똑같이 적용한다.

### 펼친 상태

- 펼친 상태(peek / permission / done / expanded)는 메뉴바 아래로 내려오는 형태라 메뉴바 아이템을 가리지 않는다.
  펼친 아일랜드 위쪽은 **접힌 모양(부분 1) 그대로다**: 넓은 노치면 접힌 날개 양끝 · 귀 · 아래 모서리 그대로,
  노치 아래 띠 · 선이면 그 모양 그대로. 카드 몸통(부분 2)은 부분 1 아래에서 나와 메뉴바 아래에서만 넓어진다
  (6장 "부분 1 은 접힌 모양 그대로, 부분 2 만 자라고 줄어든다").
- 노치 없는 화면은 직전 메뉴바 알약(점 · 메뉴바 아래 알약)이 부분 1 이다 (위 "노치 없는 화면").

### 열린 메뉴 · 팝오버와 겹침

- 다른 앱의 메뉴(드롭다운), 상태 아이템 팝오버, 컨트롤 센터 등이 열리면 (`CGWindowList` 에서 팝업 메뉴 레벨 이상의 창이
  아일랜드 + 카드가 펼쳐질 자리와 겹침) **일시적 펼침(peek/done)을 접고** 알림 펼침을 미룬다.
  접힌 상태를 투명하게 숨기는 건 메뉴가 **아일랜드 자체(메뉴바 아래끝 + 6pt 까지)에 닿을 때만**이다
  (카드 자리 아래쪽에 뜬 툴팁 · 팝업엔 숨지 않는다). 메뉴가 닫히면 원래 상태로 복귀.
- 권한 요청은 숨기지 않고 **메뉴가 닫힐 때까지 펼침을 미룬다** (접힌 상태에서 주황 점만 표시).
- 깜빡임 방지 (`OverlapScanner` · `OverlapMonitor.classify`):
  - 보지 않는 창: 투명도 0.05 미만, 한 변이라도 8pt 미만, 화면 넓이 80% 이상을 덮거나 화면 폭 90% 이상 ·
    맨 위부터 높이 90% 이상 걸친 오버레이(화면 테두리 띠 · 가림막), 우리 앱 창(우리 메뉴를 여는 동안만 예외).
  - 다른 앱 창은 같은 창이 연달아 두 번 · 0.2초 이상 보여야 **새로** 겹침으로 본다. 이미 겹친(숨긴) 화면은 창이 바뀌어도
    (메뉴바에서 옆 메뉴로 옮겨 열면 창 번호가 바뀐다) 겹친 창이 있는 동안 그대로 두고, 겹친 창이 없어지면 바로 푼다.
  - 우리 메뉴는 바로 반영한다.
  - 접힌 상태를 새로 숨기는 건 모양이 바뀐 뒤 450ms 동안 · 마우스가 아일랜드 위일 때 미룬다 (이미 숨긴 건 유지).
  - 전환 시트 출력의 "겹침 감지 검사" 가 이 규칙들을 순서대로 돌려 확인한다.
- 감시는 아일랜드가 보이는 동안 0.25초 주기 폴링 (CGWindowList 조회는 1ms 미만).
- 우리 앱 메뉴(상태 아이템 메뉴)는 `NSMenu.didBeginTracking` / `didEndTracking` 으로 직접 감지.

### 다른 노치 앱과 겹침

- 노치 영역에 다른 앱의 오버레이 창(우리보다 높거나 같은 레벨, 노치 사각형과 교차)이 있으면 그 앱이 노치를 쓰는 중으로 보고
  자동으로 **노치 아래 띠** 레이아웃으로 바꾼다. 설정 화면에 "다른 노치 앱 감지됨: <앱 이름>" 을 표시.

### 우리 메뉴바 아이콘이 노치에 가려질 때

- 메뉴바 아이콘이 많으면 우리 상태 아이템이 노치 뒤로 밀려 안 보일 수 있다. 그래도 모든 기능에 접근할 수 있게:
  - 아일랜드 클릭 → 펼침 → 톱니바퀴로 설정.
  - 전역 단축키 `⌃⌥⌘N` (Carbon `RegisterEventHotKey`, 권한 불필요) 로 펼치기/접기.

### 검증: 스냅숏 렌더링

- `AgentNotch --render-island <장면|all> <폴더> [--style notch|menubar|both]` 로 실제 뷰를 PNG 로 그린다
  (화면 기록 권한 불필요, 가짜 데이터). 파일 이름 `<장면>-<notch|menubar>.png`.
- 오프스크린 렌더링은 AppKit 기반 컨트롤(Picker, Slider, 스위치, ScrollView 등)을 그리지 못하므로 스냅숏에서만 같은 모양의
  SwiftUI 그림으로 대체한다. 아일랜드 안에는 AppKit 기반 컨트롤을 넣지 않는다 (질문 카드 "기타" 입력란만 예외 — 스냅숏은 글자 그림).
- 질문 · 계획 카드 장면: `question` (한 개 고르기) · `question-multi` (여러 개) · `question-pages` (질문 두 개, 1/2) ·
  `question-other` ("기타" 입력) · `plan` (계획 승인) · `menubar-question` (메뉴바 알약 아래). 전환 시트 `anim-working-question` ·
  `anim-question-working` · `anim-working-question-pages` · `anim-working-plan` · `anim-plan-working` · `anim-menubar-working-menubar-question` ·
  `anim-menubar-question-menubar-working`.
- 전환 시트(`anim-<전>-<후>`): 실제 패널과 같은 스프링으로 24프레임을 그리고 프레임마다 모양 검사(모양 조각 · 자기 교차 ·
  노치 드러남 · 양 끝 상태 밖 반경 · 전환 중에만 가려지는 메뉴바 아이콘 · 글자)를, 스프링 값 0 → 최대값을 촘촘히 훑어 불연속을 출력한다.
  카드를 펼치기 전엔 접힌 상태를 한 번 그려(실제 앱처럼) 카드의 부분 1 이 접힌 모양을 이어받게 한다.
  `-release` 시트는 카드를 접은 뒤 붙잡은 띠를 놓는 단계(접힌 상태 안의 변화)를 따로 그린다.
- 이어서 계산하는 전환 (`anim-seq-<seen|permission|focus>-<wings|strip|pill|below|dot>-<open|change|close|release>`,
  `SnapshotSequence`): 한 표시 상태로 접힌 상태 → 카드 → 접힌 상태를 이어서 계산한다. 접힌 내용이 카드를 여는 순간
  (펼치면 완료 확인 → 쉬는 중, 쉬는 중 → 권한 요청) · 열린 동안(다른 세션이 긴 명령 실행, 다른 세션을 고름) 바뀐다.
  `change` 는 카드 → 카드 (전 카드의 부분 1 그대로인지). 넓은 노치 · 노치 아래 띠 ·
  메뉴바 안 알약 · 메뉴바 아래 알약 · 메뉴바 안 점(빈 곳이 좁은 메뉴바). 점 ↔ 카드는 `anim-menubar-dot-menubar-permission` ·
  `anim-menubar-permission-menubar-dot` 도 있다.
- 부분 1 검사 (`SnapshotPart1Check`, 카드 ↔ 접힌 상태 · 이어서 계산하는 카드 → 카드 전환 시트의 프레임 · 촘촘한 훑기):
  - 그린 부분 1 층의 자리 · 폭 · 높이 · 귀 · 위 반경 · 아래 반경이 접힌 상태와 0.5pt 넘게 다르면 위반. 부분 2 를 그리는 목이
    부분 1 위 조각과 다른 가로 자리면 위반 (부분 1 이 커져 보임).
  - 카드 상단 행이 부분 1 안에 있으면 위반.
  - 부분 2 가 부분 1 과 옆면을 맞댄 채(1pt 미만) 부분 1 아래로 2pt 넘게 이어지는 구간이 16ms(한 프레임)보다 길면 위반
    ("부분 1 늘어나 보임" — 접을 때 부분 1 이 부분 2 크기를 따라가는 것처럼 보이는 것).
- 노치 아래 띠 요소 검사 (`SnapshotStripCheck`): 같은 측정값이면 띠(노치 폭)와 메뉴바 알약이 같은 요소를 고르는지
  (둘 다 들어가면 같은 첫 후보, 띠는 `lineItems` 그대로, 줄인 프로젝트명이 들어가면 상태 아이콘만 남기지 않음, 두 줄 높이 규칙).
  백그라운드 배지(없음 · 한 자리 · 두 자리)도 훑는다: 배지가 있어도 띠 제목이
  알약 제목과 같고("api-server · Bash +12 −3 ⧉ 3"), 띠 제목 줄 요소가 배지 없는 같은 내용과 같으며, 배지 · 요약이 제목 줄에
  함께 들어갈 때만 한 줄, 둘째 줄이 띠 안이고, 알약 · 양쪽 날개 · 한쪽 날개는 배지를 끝 요소에 그대로 센다.
- 모양 조각 검사: 칠한 래스터의 덩어리 수를 센다. 프레임마다 이음매 래스터로, 그리고 주 외곽선과 부분 1 을 함께 그리는 동안
  위쪽 띠 영역을 스프링 값 0.001 간격으로 촘촘히 훑어(`SnapshotShapeCheck.denseFragments`) 모양이 여러 조각으로 갈라지는 순간을 찾는다
  (시트 프레임 사이에서만 생기기도 한다). 불리언 연산이 없어 경로 하위 경로 수는 더 이상 조각 수가 아니다.
- 불연속 검사: 몸통 끝은 입력보다 최대 12배 가파르게 움직이므로(부분 2 가 나오는 폭 6배 × 1 → 2pt 곧은 옆면 풀림 2배)
  한 칸 이동이 입력 최대 이동의 12배 × 1.1 (최소 1pt) 를 넘을 때만 불연속으로 본다.
- 이음매 검사 (`SnapshotSeamCheck`, 전환 시트 프레임 · 촘촘한 훑기 · 정지 장면 모두):
  - 래스터: 모양(내용 없이 같은 `IslandShape` 경로)을 2배로 칠해 열마다 띠 ↔ 몸통 사이 **끊김**, 쪽마다 바깥 윤곽이
    위 · 아래 줄보다 1pt 넘게 안으로 들어간 **물림**을 찾는다 (귀는 빼고 본다).
  - 치수: 목 끝 · 몸통 끝이 1–6pt 로 거의 겹친 이음매에서 오목 + 볼록 반경이 차이를 다 채우지 못해 남은 **턱**,
    카드 ↔ 접힌 상태 전환 중 목(노치 화면의 띠 · 메뉴바 알약) 끝이 **움직이며** 몸통 끝과 맞닿는 것.
  - 자체 검사: 일부러 끊고 물린 모양 · 떨어진 두 덩어리를 찾아내는지, 이어진 모양 · 겹친 두 하위 경로를 문제로 보지 않는지 시트마다 확인한다.

## 9. 보안 · 개인정보 원칙 (GitHub 공개 저장소)

- 비밀 정보(API 키, 토큰, 개인 경로 등)를 코드·픽스처·로그에 넣지 않는다. 경로는 `homeDirectoryForCurrentUser` 로 계산.
- 훅 헬퍼는 **화이트리스트 환경변수만** 전달한다 (`NotchWire.forwardedEnvironmentKeys`).
- 소켓 디렉터리 0700, 소켓 0600, 연결 시 `getpeereid` 로 같은 사용자만 허용.
- 프롬프트·코드·응답 내용을 디스크에 기록하지 않는다. 메모리에만 두고 오래된 세션은 정리한다.
- **앱은 프로젝트 폴더를 읽지 않는다.** 앱이 읽으면 문서 · 데스크탑 같은 보호 폴더에서 "AgentNotch 가 '문서' 폴더에 접근하려고 합니다" 창이
  뜨고, ad-hoc 서명이라 빌드 · 업데이트마다 다시 묻는다. 브랜치는 훅 헬퍼가 `SessionStart` · `UserPromptSubmit` 때만 cwd 의 HEAD 를 읽어
  `_agent_notch_git_branch`(`NotchWire.gitBranchKey`, 줄인 payload 에도 남김)로 보낸다 — 헬퍼는 Claude Code 프로세스 안에서 돌아
  이미 그 폴더를 쓰는 터미널 · Claude 앱의 권한으로 읽는다. 키가 없으면(예전 헬퍼) `~/.claude` 아래 대화 기록의 `gitBranch` 를 쓴다.
  사용자가 직접 누른 "파일 열기" 만 그 파일을 확인한다.
- 대화 기록 끝부분은 `TranscriptTail.readTail` 하나로만 읽는다: 일반 파일만(lstat · `O_NOFOLLOW` · `O_NONBLOCK` · fstat), 최대 바이트까지만
  (훅이 준 `transcript_path` 가 FIFO · `/dev/zero` 여도 멈추거나 메모리를 먹지 않게).
- 파일 열기는 **허용 목록**: 실행 비트 · 앱 · `.command` · `.term` · 구성 프로필 · 위치 파일(`.vncloc` 등) · `.wflow` · `.jnlp` 는 Finder 에서
  위치만, 텍스트 · 소스 · JSON · YAML · XML · 이미지 · PDF · 오디오/비디오만 기본 앱으로, 나머지(스크립트 · HTML · 모르는 형식)는
  기본 앱이 알려진 코드 편집기(VS Code · Cursor · JetBrains · Xcode · Zed 등)면 그 앱, 아니면 텍스트 편집기로 연다 (`FileOpener`).
- 훅 payload 의 짝 없는 UTF-16 서로게이트 이스케이프는 `\uFFFD` 로 바꿔 다시 해석한다 (payload 전체가 `{}` 가 되지 않게).
  사용자 `settings.json` 은 바꾸지 않고 그대로 읽는다.
- 메인 스레드를 오래 막는 일은 하지 않는다: 모달 알림은 GCD 메인 큐 블록이 아니라 런루프에서 띄우고(`AppDelegate.presentModal`,
  모달 동안 소켓 전달이 멈추지 않게), iTerm2 AppleScript 는 전용 큐에서 `with timeout of 5 seconds` 로, brew 찾기는 백그라운드에서
  사용자 로그인 셸(`$SHELL`)로 8초 제한, 정밀 diff 는 3,000줄 예산(넘으면 근사) 안에서만 한다.
- 앱을 켤 때만 최근 Claude Code 대화 기록 끝부분을 **읽는다** (세션 되살리기, 설정에서 끌 수 있음). 쓰지 않고, 상태 · 툴 요약만 메모리에 둔다.
  디버그 로그는 `os.Logger` + `privacy: .private`. 레이아웃 변화 로그(`Presentation`)만 숫자 · 모드 종류 · 자리 종류를 `.public` 으로 남긴다.
- 네트워크 통신은 **업데이트 확인 하나뿐** — 하루 한 번 GitHub 의 `docs/changelog.json` (raw) 을 받는다. 설정에서 끌 수 있다.
  분석/텔레메트리 없음.
- `~/.claude/settings.json` 수정 전 타임스탬프 백업(0600). AgentNotch 항목만 추가/제거하고 다른 훅(예: iTerm2 `cc-status`)은 보존.
  앱 업데이트 후 예전 형태의 우리 항목을 고칠 때(`updateInstalledHooks`)도 같은 규칙 (우리 항목만 그 자리에서, 백업 후).
- 테스트 픽스처는 가짜 데이터만 사용 (`/Users/dev/projects/api-server` 같은 예시 경로).

## 10. 배포 · 업데이트 (dong-csu 방식)

애플 개발자 계정 없이 배포하므로 **Homebrew formula (소스 빌드 + bottle)** 방식을 쓴다. 저장소 자체가 tap 이다.

```bash
brew tap ldg030201/agent-notch https://github.com/ldg030201/agent-notch && brew trust ldg030201/agent-notch \
  && brew install -y agent-notch && cp -R "$(brew --prefix agent-notch)/AgentNotch.app" /Applications/ && open /Applications/AgentNotch.app
```

- cask 로 빌드된 .app 을 배포하면 quarantine 속성 때문에 공증되지 않은 앱이 Gatekeeper 에 막힌다.
  formula 는 사용자 맥에서 빌드(또는 CI 가 만든 bottle 을 설치)하므로 quarantine 이 붙지 않는다.
- `Formula/agent-notch.rb` (저장소 루트), `.github/workflows/bottle.yml` 이 릴리스마다 macOS 판별 bottle 을 올리고 formula 에 기록.
- `scripts/build.sh` 가 `.app` 번들을 만든다. 버전은 `Sources/AgentNotch/Version.swift` 의 `agentNotchVersion`,
  `Resources/Info.plist`, `notch-hook` 의 버전 상수 세 곳에 있고, 다르면 빌드 실패. `agent-notch --version` → `agent-notch 0.1.0`.
- 번들 ID `com.ldg.agent-notch` (테스트판 `AgentNotch-Test` / `com.ldg.agent-notch-test`, `scripts/dev.sh`).
  두 판은 소켓·헬퍼 경로를 같이 쓰므로 동시에 띄우려면 `AGENT_NOTCH_SOCKET` 으로 소켓을 나눈다.
- 서명: 자체 서명 인증서(`scripts/make-signing-cert.sh`)가 있으면 그걸로, 없으면 ad-hoc.
  자동화(iTerm2 AppleScript) 권한은 서명 신원에 묶이므로, ad-hoc 이면 업데이트마다 권한을 다시 물을 수 있다.
- `scripts/release.sh <버전>`: 버전 반영 → 빌드 검증 → 변경 내역 날짜 기록 → 태그 `v<버전>` → tarball sha256 → formula 갱신 → GitHub 릴리스.
  **릴리스(버전 자리 결정 · 태그)는 사용자에게 먼저 묻고 진행한다.**
- 업데이트 확인: 하루 한 번 `https://raw.githubusercontent.com/ldg030201/agent-notch/main/docs/changelog.json` 을 받아 비교
  (날짜가 있는 항목만 "나간 버전"). 설정 "버전" 탭과 펼친 아일랜드 헤더에 새 버전 표시. 끄기 가능.
- 업데이트 실행: 앱이 `brew upgrade agent-notch` 를 직접 실행(진행 로그 표시) → 사용자가 "다시 띄우기" 를 누르면
  분리된 스크립트가 앱을 종료 · `/Applications` 사본 교체 · 재실행.
- 로그인 시 실행: `SMAppService.mainApp` (시스템 설정의 로그인 항목과 항상 일치).
- 첫 실행 안내(`offerFirstLaunchSetupIfNeeded`): 훅 설치 · 로그인 시 실행을 체크박스(처음부터 켬) 한 창에서 한 번만 묻는다.
  이미 된 항목은 빼고, 할 게 없으면 묻지 않는다. 실패한 항목만 따로 알린다.
- 설정 초기화(`AppPreferences.resetToDefaults`): 저장된 설정 키를 지우고 처음 값으로 되돌린다. 훅 · 로그인 항목은 건드리지 않는다.
- 훅 헬퍼는 앱이 "훅 설치" 시 `~/Library/Application Support/AgentNotch/bin/notch-hook` 으로 복사해 경로를 고정한다
  (brew 업그레이드로 Cellar 경로가 바뀌어도 훅이 깨지지 않게). 업데이트 후 첫 실행 때 헬퍼가 다르면 다시 복사하고,
  예전 버전이 설치한 훅 항목(예: 응답 대기 없는 PreToolUse)이 있으면 지금 형태로 고친다 (3장 "응답을 기다리는 호출").
