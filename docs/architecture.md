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
- `PermissionRequest` 만 앱 응답을 기다린다. 나머지는 보내고 바로 종료(fire-and-forget).

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

## 4. 훅 이벤트 → 세션 상태

| 이벤트 | 처리 |
|---|---|
| `SessionStart` | 세션 생성(이미 있으면 갱신), phase `idle`, 신호 `sessionStarted` |
| `UserPromptSubmit` | phase `thinking`, 턴 요약 초기화, `lastPrompt`(200자 제한), `streamingText` 초기화, 미확인 완료 해제 |
| `PreToolUse` | phase `runningTool`, `currentActivity` 생성(툴 요약), 타임라인 추가. `AskUserQuestion` 이면 `waitingInput` + `needsInput` |
| `PostToolUse` | 해당 `tool_use_id` 활동 성공 처리, diff 계산(Edit/MultiEdit/Write/NotebookEdit/Bash `bashEditDiff`) → `lastDiff`, 턴 요약 누적, 신호 `edited` |
| `PostToolUseFailure` | 활동 실패 처리, phase `thinking` |
| `PermissionRequest` | `PermissionRequestInfo` 생성 → 대기열, phase `waitingPermission`, 신호 `permissionRequested`, 요청 ID 반환. 단 `AskUserQuestion` / `ExitPlanMode` 는 대기열에 넣지 않고 바로 결정 없음(Claude Code 가 `updatedInput` 없는 allow 를 무시하므로) → 입력 대기 카드 |
| `Notification` | `lastNotification` 갱신. `elicitation_dialog`/`agent_needs_input` → `waitingInput` + `needsInput`. `permission_prompt` 인데 해당 세션의 훅 대기 요청이 없으면 `waitingPermission` + `needsInput`. `idle_prompt` → 작업 중 · 훅 대기 없는 승인 대기 · 입력 대기를 `idle` 로 정리 (터미널에서 거부/Esc 한 경우 약 60초 뒤 복구) |
| `MessageDisplay` | `delta` 를 `streamingText` 뒤에 붙임(최근 2000자 유지) |
| `Stop` | phase `completed`, `lastAssistantMessage`, 미확인 완료 표시, 신호 `completed`, 해당 세션 남은 권한 대기 정리 |
| `StopFailure` | phase `failed`, `errorMessage`, 신호 `failed` |
| `SubagentStart` / `SubagentStop` | `activeSubagents` 증감 |
| `PreCompact` / `PostCompact` | `compacting` / 이전 상태 복귀 |
| `SessionEnd` | 세션 제거, 해당 세션 권한 대기 정리 |

- 처음 보는 `session_id` 의 이벤트가 오면(앱을 세션 도중 켠 경우) payload 의 `cwd` 로 세션을 즉석 생성한다.
- 오래된 권한 대기 정리: 다른 경로(터미널)에서 이미 답한 요청은 **같은 호출의** `PostToolUse` / `PostToolUseFailure`
  (같은 에이전트 · 툴 이름 · 입력)가 오면 결정 없음으로 풀어준다. 병렬 형제 툴이 있어서 `PreToolUse` 는 기준으로 쓰지 않는다.
  `UserPromptSubmit` · `Stop` · `StopFailure` · `SessionEnd` · `SubagentStop` 은 해당 범위의 대기를 모두 정리한다.
- 모든 payload 필드는 선택적으로 취급한다 (버전에 따라 필드가 없거나 늘어날 수 있음). 세부 스키마는 `docs/hook-events.md`.

## 5. 주로 볼 세션 (포커스) 규칙

1. **끼어들기** — 주의가 필요한 세션이 있으면 그 세션이 포커스.
   우선순위: 권한 대기(오래된 요청 먼저) → 입력 대기 → 실패(미확인) → 완료(미확인).
2. 끼어들기가 없으면 **사용자가 직접 선택한 세션**(`focus(sessionID:)`) → 없으면 **고정 세션**.
3. 그것도 없으면 **작업 중인 세션 중 가장 최근 이벤트**. 단, 현재 포커스 세션이 아직 작업 중이면 바꾸지 않는다
   (작업 중 세션끼리 자동 전환으로 인한 깜빡임 방지).
4. 작업 중인 세션도 없으면 가장 최근 이벤트가 있었던 세션.

`rankedSessions` 정렬: 끼어들기 대상(위 우선순위) → 고정 → 작업 중(최근순) → 나머지(최근순). 종료된 세션 제외.

## 6. 아일랜드 표시 모드

| 모드 | 트리거 | 내용 | 크기(대략, pt) |
|---|---|---|---|
| idle | 작업 중인 세션 없음 | 오른쪽 날개에 세션 수만큼 점 (작업 중=초록, 나머지=회색) | 노치폭+50 × 노치높이 |
| working | 포커스 세션 작업 중 | 왼쪽: 스피너 + 프로젝트명 / 오른쪽: 현재 툴 + `+N −M` | 노치폭+200 × 노치높이 |
| peek | `edited` 신호 (설정 on) | 파일명·줄번호, 미니 diff 3줄, 스트리밍 텍스트 한 줄 | 460 × 160 |
| permission | `permissionRequested` | 툴 · 명령어, [허용] [항상 허용] [거부] [접기] [터미널로]. 해결될 때까지 유지 (아래 "권한 카드 안전 규칙") | 480 × 170 |
| needsInput | `needsInput` | 질문 메시지 + [터미널로] | 440 × 110 |
| done / failed | `completed` / `failed` | 체크(또는 경고) + 소요 시간, 변경 파일 수 `+N −M`, 마지막 응답 한 줄. 일정 시간 후 접힘 | 430 × 105 |
| expanded | 아일랜드 클릭 | 왼쪽: 세션 목록(우선순위순, 고정 핀) / 오른쪽: 포커스 세션 타임라인 · diff · 최근 응답 | 620 × 300 |

- 접힌 상태(idle/working)는 노치 양옆 "날개"에만 내용을 둔다. 가운데 노치 폭만큼은 비워 카메라를 가리지 않는다.
- 펼친 상태의 내용은 노치 높이 아래부터 시작한다.
- 노치 없는 화면(외부 모니터): 접힌 상태는 **메뉴바 안**의 빈 공간에 들어가는 알약 (8-1 의 "노치 없는 화면" 참고). 한 줄 (스피너 + 프로젝트 · 툴 + `+N −M`).
- 전환 애니메이션: `spring(response: 0.42, dampingFraction: 0.82)`, 내용은 크기 변경 후 페이드인.
- 우선순위: permission > needsInput > expanded(사용자가 연 경우) > done/failed > peek > working > idle.
- 아일랜드는 활성화하지 않는 패널(non-activating)이라 알림이 와도 다른 앱의 키보드 포커스를 뺏지 않는다.
  사용자가 아일랜드를 클릭해 키 윈도우가 됐을 때만 단축키가 동작한다:
  `⌘↩` 허용, `⌥⌘↩` 항상 허용, `⌘⌫` 거부, `⎋` 접기(요청은 대기 유지).

### 권한 카드 안전 규칙

- 명령의 안 보이는 문자를 드러낸다: 줄바꿈 `⏎`, 9개 이상 연속 공백 `␣×N`, 제어 · bidi · 폭 0 문자 `\u{…}`. MCP 툴은 인자 JSON 을 보여준다.
- 상세가 카드에 다 안 보이면(4줄 초과, 글자 수 제한, 헬퍼의 payload 축소) **노치에서 허용 · 항상 허용을 막고** "터미널로" 를 강조한다.
  거부 · 접기는 가능. (여러 줄 heredoc 명령도 막히므로 줄 수 한도는 사용해 보며 조정)
- "항상 허용" 이 가능할 때는 저장될 규칙과 범위(`permission_suggestions` 요약)를 카드에 표시한다.
- 보이는 요청이 바뀌면 키 윈도우를 반납하고, 새 요청이 뜬 뒤 0.5초 안의 단축키 · 키 반복 입력은 무시한다.

### 색상 (아일랜드는 항상 검정 배경 — 라이트/다크 공통)

| 용도 | 값 |
|---|---|
| 배경 | `#0B0B0B` |
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

노치 양옆 메뉴바는 다른 앱의 상태 아이콘(오른쪽)과 앞 앱의 메뉴(왼쪽)가 쓰는 자리다. 아일랜드는 **절대 이것들을 덮지 않는다.**

### 빈 공간 측정 (`MenuBarSpaceMonitor`)

- 화면마다 노치 왼쪽/오른쪽의 **빈 폭**을 계산한다.
  - **손쉬운 사용 권한이 있으면** 정확히 잰다: 왼쪽은 앞 앱의 `AXMenuBar` 항목(앱 변경 시 + 5초마다),
    오른쪽은 SystemUIServer 등의 `AXExtrasMenuBar` 상태 아이템(10초마다).
  - **권한이 없으면 막혀 있다고 가정**한다 (가리는 것보다 안전). macOS 27 에서는 상태 아이템이
    `CGWindowListCopyWindowInfo` 에 나오지 않아 창 목록만으로는 오른쪽을 잴 수 없다 → 노치 화면은 노치 아래 띠/선으로 표시.
  - 창 목록(`CGWindowList`, 메인 스레드 밖, 약 0.3ms)은 메뉴바 창 높이·표시 여부와 팝업 메뉴 감지에 쓴다.
- 다시 계산하는 시점: 앞 앱 변경(`NSWorkspace.didActivateApplicationNotification`), 화면 구성 변경, 1초 주기(가벼운 폴링, 접힌 상태일 때만).
- 여백 8pt 를 남긴다.

### 노치 화면 표시 방식 (`NotchStyle`)

사용자가 두 방식 중 고른다 (설정 > 표시 > 노치 화면 표시).

- **노치 양옆 (날개, 기본)** — 카메라(노치)를 가운데 두고 양옆 메뉴바 자리를 날개로 쓴다 (목업 기본형).
  - **날개 위 메뉴바 아이콘 (손쉬운 사용 권한이 있을 때):** 노치 옆 상태 아이콘 · 앱 메뉴 위치를 AX 로 읽어 검은 날개의
    그 자리만 둥글게 뚫는다 → 진짜 아이콘이 날개 안에 박힌 것처럼 보이고, 클릭 · 호버 · 실시간 변화도 그대로 동작(구멍은 클릭 통과).
    날개 안 내용은 구멍을 피해 노치와 첫 아이콘 사이 빈 구간에 두고, 모자라면 반대쪽 날개 → 노치 아래 띠로 옮긴다.
    아이콘을 반만 자르지 않도록 오른쪽 날개는 걸친 아이콘까지 넓힌다(최대 200pt).
  - **권한이 없을 때:** 날개가 아이콘을 덮되, **마우스를 날개 위에 두면(약 120ms) 그쪽 날개가 노치 안으로 들어가**
    아래 아이템을 클릭할 수 있고, 마우스가 떠나면(약 0.6초 뒤) 다시 나온다. 노치(카메라) 가운데는 항상 클릭 가능(펼치기).
  - 손쉬운 사용 권한이 있으면 앞 앱 메뉴를 재서 왼쪽 날개가 메뉴를 덮지 않게 줄이고 내용을 오른쪽으로 옮긴다.
  - 다른 노치 앱이 감지되면 노치 아래 방식으로 바꾼다.
- **노치 아래** — 아래 "접힌 상태 레이아웃 선택" 규칙대로, 메뉴바를 전혀 가리지 않는다.

#### macOS 27 메뉴바 아이콘 접기 (확인 결과)

- macOS 27 은 상태 아이콘이 넘치면 노치 쪽 아이콘부터 `«` 버튼 뒤로 **자동으로 접는다** (⌘-드래그로 순서 변경, 고를 수는 없음).
- 메뉴바 전체가 MenuBarAgent 창 하나로 그려져서, 예전 Bartender · Ice 처럼 넓은 상태 아이템으로 다른 아이콘을 밀어내는 방식이 안 된다.
  직접 실험해 보니 폭 넓은 상태 아이템을 추가하면 **우리 아이템이 가장 먼저 접혔다.** → 다른 앱 아이콘을 접게 만들 공개 API 는 없다.
- 메뉴바보다 낮은 레벨(23)에 검은 창을 깔면(창 위치 제한 `constrainFrameRect` 를 꺼야 메뉴바 자리에 놓인다) 투명한 메뉴바 뒤로
  비쳐 보이고 아이콘은 그 위에 그려지지만, **아이콘 색은 배경화면 밝기를 따라가서** 밝은 배경화면이면 검은 바탕 위에서 안 보인다.
  → 날개는 메뉴바 위에 두고, 아이콘 자리만 뚫는 방식을 쓴다.
- 아이콘을 캡처해 흰색으로 다시 그리는 방법은 화면 기록 권한과 상시 녹화 표시가 필요해서 쓰지 않는다.
- 아이콘 자체를 줄이려면 시스템 설정 > 메뉴 막대에서 숨긴다.

### 접힌 상태 레이아웃 선택

1. **양쪽 날개** — 양쪽 빈 폭이 모두 충분하면 (목업 기본형).
2. **오른쪽 날개만** — 왼쪽이 막혔으면 상태 아이콘 · 프로젝트 · 툴 · `+N −M` 을 오른쪽 날개 하나에 모은다 (필요 없는 요소부터 생략: 프로젝트명 → 툴 이름).
3. **노치 아래 띠** — 양쪽 다 부족하면 날개를 쓰지 않고, 노치 바로 아래로 22pt 높이의 띠를 내려 그 안에 표시한다
   (메뉴바 아이템과는 겹치지 않고, 창 제목 표시줄 일부만 덮음. 마우스가 없으면 클릭 통과).
4. **최소 표시** — 설정에서 고르면 띠 대신 노치 아래 가장자리에 상태 색 선(3pt)만 표시.

설정 `CompactOverlapStyle`: `belowNotch`(기본) / `minimal`.
노치 없는 화면의 알약은 메뉴바 아래에 뜨므로 이 계산이 필요 없다.

### 노치 없는 화면 (외부 모니터)

노치가 없으니 아일랜드를 메뉴바 **아래**에 두면 브라우저 탭 · 툴바 · 앱 메뉴 바로 아래를 가린다. 그래서 접힌 상태는 **메뉴바 안**에 넣는다.

- `ExternalDisplayStyle` 설정: `inMenuBar`(기본) / `belowMenuBar`(예전 방식) / `hidden`.
- `inMenuBar`:
  - 알약 높이 = 메뉴바 높이 − 4pt, 메뉴바 띠 안에서 세로 가운데.
  - 가로 위치: 앱 메뉴 오른쪽 끝과 상태 아이템 왼쪽 끝 사이의 빈 구간을 구하고, 화면 가운데가 그 안에 들어가면 가운데,
    아니면 가장 넓은 빈 구간의 가운데. 폭은 빈 구간 − 여백 16pt 이내로 줄이고 내용도 그에 맞게 생략.
  - 앱 메뉴 끝·상태 아이템 시작은 손쉬운 사용 권한이 있으면 AX 로 정확히, 없으면 앱 메뉴는 **왼쪽 45% (최대 900pt)**,
    상태 아이템은 **오른쪽 40% (최대 760pt)** 를 차지한다고 가정.
  - 빈 구간이 최소 폭(80pt)보다 좁으면 12pt 점 하나로 줄이고, 그것도 안 되면 접힌 상태는 숨긴다(알림은 표시).
  - 메뉴바가 숨겨진 화면(자동 숨김 · 풀스크린)에서는 접힌 상태를 숨긴다. 메뉴바 표시 여부는 창 목록의 메인 메뉴 레벨 창으로
    판단한다 (외부 모니터에서 메뉴바가 보이는데도 `visibleFrame == frame` 인 경우가 있어서 `visibleFrame` 은 보조로만 사용).
  - 카드는 메뉴바 알약을 "목"으로 삼아 아래로 내려온다 (알약 폭이 좁으면 목은 빈 검정 탭으로 보임 — 사용해 보며 조정).
- 펼친 카드(peek / permission / done / expanded)는 메뉴바 알약에서 아래로 내려온다. 화면 아래 내용을 덮으므로:
  - peek · done 은 짧게 보이고 자동으로 접힌다.
  - 카드 밖을 클릭하거나 `⎋` 를 누르면 즉시 접힌다.
  - 권한 카드는 "접기" 로 알약(주황 점 깜빡임)으로 줄일 수 있고, 알약을 클릭하면 다시 펼친다. 요청은 그대로 대기.
  - 카드 폭은 460pt 이내.
- 내장(노치) 화면에서도 펼친 카드가 메뉴바 아래를 덮는 것은 같으므로 위 규칙(자동 접힘, 바깥 클릭/⎋ 로 접기, 권한 카드 접기)을 똑같이 적용한다.

### 펼친 상태

- 펼친 상태(peek / permission / done / expanded)는 메뉴바 아래로 내려오는 형태라 메뉴바 아이템을 가리지 않는다.
  다만 노치 높이 구간의 가로 폭이 날개보다 넓어지지 않도록, 펼친 아일랜드 윗부분(메뉴바 높이)은 노치 폭 + 허용된 날개 폭으로 제한하고
  그 아래부터 넓어지는 모양으로 그린다.

### 열린 메뉴 · 팝오버와 겹침

- 다른 앱의 메뉴(드롭다운), 상태 아이템 팝오버, 컨트롤 센터 등이 열리면 (`CGWindowList` 에서 팝업 메뉴 레벨 이상의 창이
  아일랜드 영역과 겹침) **일시적 펼침(peek/done)을 접고**, 아일랜드 영역과 겹치는 동안은 접힌 상태도 투명하게 숨긴다.
  메뉴가 닫히면 원래 상태로 복귀.
- 권한 요청은 숨기지 않고 **메뉴가 닫힐 때까지 펼침을 미룬다** (접힌 상태에서 주황 점만 표시).
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
  SwiftUI 그림으로 대체한다. 아일랜드 안에는 AppKit 기반 컨트롤을 넣지 않는다.

## 9. 보안 · 개인정보 원칙 (GitHub 공개 저장소)

- 비밀 정보(API 키, 토큰, 개인 경로 등)를 코드·픽스처·로그에 넣지 않는다. 경로는 `homeDirectoryForCurrentUser` 로 계산.
- 훅 헬퍼는 **화이트리스트 환경변수만** 전달한다 (`NotchWire.forwardedEnvironmentKeys`).
- 소켓 디렉터리 0700, 소켓 0600, 연결 시 `getpeereid` 로 같은 사용자만 허용.
- 프롬프트·코드·응답 내용을 디스크에 기록하지 않는다. 메모리에만 두고 오래된 세션은 정리한다.
  디버그 로그는 `os.Logger` + `privacy: .private`.
- 네트워크 통신은 **업데이트 확인 하나뿐** — 하루 한 번 GitHub 의 `docs/changelog.json` (raw) 을 받는다. 설정에서 끌 수 있다.
  분석/텔레메트리 없음.
- `~/.claude/settings.json` 수정 전 타임스탬프 백업(0600). AgentNotch 항목만 추가/제거하고 다른 훅(예: iTerm2 `cc-status`)은 보존.
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
  자동화(iTerm2 AppleScript) · 손쉬운 사용 권한은 서명 신원에 묶이므로, ad-hoc 이면 업데이트마다 권한을 다시 물을 수 있다.
- `scripts/release.sh <버전>`: 버전 반영 → 빌드 검증 → 변경 내역 날짜 기록 → 태그 `v<버전>` → tarball sha256 → formula 갱신 → GitHub 릴리스.
  **릴리스(버전 자리 결정 · 태그)는 사용자에게 먼저 묻고 진행한다.**
- 업데이트 확인: 하루 한 번 `https://raw.githubusercontent.com/ldg030201/agent-notch/main/docs/changelog.json` 을 받아 비교
  (날짜가 있는 항목만 "나간 버전"). 설정 "버전" 탭과 펼친 아일랜드 헤더에 새 버전 표시. 끄기 가능.
- 업데이트 실행: 앱이 `brew upgrade agent-notch` 를 직접 실행(진행 로그 표시) → 사용자가 "다시 띄우기" 를 누르면
  분리된 스크립트가 앱을 종료 · `/Applications` 사본 교체 · 재실행.
- 로그인 시 실행: `SMAppService.mainApp` (시스템 설정의 로그인 항목과 항상 일치).
- 훅 헬퍼는 앱이 "훅 설치" 시 `~/Library/Application Support/AgentNotch/bin/notch-hook` 으로 복사해 경로를 고정한다
  (brew 업그레이드로 Cellar 경로가 바뀌어도 훅이 깨지지 않게). 업데이트 후 첫 실행 때 헬퍼가 다르면 다시 복사한다.
