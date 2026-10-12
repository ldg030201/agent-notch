# Claude Code 훅 이벤트 레퍼런스 (구현용)

조사 시점: 2026-10 (Claude Code 2.1.29x). 출처: <https://code.claude.com/docs/en/hooks>, hooks-guide, settings, env-vars, headless, agent-sdk/hooks.
Claude Code 업그레이드 후 재확인 필요. **(추정)** 표시는 문서에 직접 나오지 않는 내용.

> 원칙: 모든 필드는 선택적으로 파싱한다. 버전에 따라 필드가 없거나 추가될 수 있다.

---

## 1. settings.json 훅 설정 형식

```jsonc
{
  "hooks": {
    "PreToolUse": [                       // hooks.<Event> = matcher 그룹 배열
      {
        "matcher": "*",                   // 그룹 단위. 생략 / "" / "*" = 전체 매치
        "hooks": [
          {
            "type": "command",            // command | http | mcp_tool | prompt | agent
            "command": "'/path/to/notch-hook'",
            "timeout": 10,                // 초
            "async": false,               // command 전용. true 면 결정(decision) 반환 불가
            "onFailure": "continue"       // continue(기본) | block (v2.1.295+)
          }
        ]
      }
    ]
  }
}
```

- `args: []` 가 있으면 exec 형식(셸 없이 `command` 를 실행 파일로 실행). 구버전 호환을 위해 AgentNotch 는 **셸 형식 + 작은따옴표 경로**를 쓴다.
- 훅 항목은 settings 레벨 간에 병합된다 (덮어쓰지 않음).
- matcher 지원 이벤트에만 matcher 의미가 있다. 지원하지 않는 이벤트의 matcher 는 무시된다.

| matcher 필드 | 이벤트 |
|---|---|
| 툴 이름 | PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, PermissionDenied |
| `startup` `resume` `clear` `compact` `fork` | SessionStart |
| `clear` `resume` `logout` `prompt_input_exit` `other` | SessionEnd |
| `notification_type` | Notification |
| `agent_type` | SubagentStart, SubagentStop |
| `manual` `auto` | PreCompact, PostCompact |
| `error` 타입 | StopFailure |
| **matcher 없음** | UserPromptSubmit, PostToolBatch, Stop, MessageDisplay, TaskCreated, TaskCompleted, … |

### 여러 훅의 실행

- "All matching hooks run in parallel." 실행 순서는 문서화되지 않음.
- 모든 훅이 끝난 뒤 결과를 병합한다.
- **PermissionRequest 결정이 여러 훅에서 올 때의 병합 규칙은 문서화되지 않음.**
  호스트 세션(데스크톱 앱 등 `canUseTool`)에서는 "the hooks run alongside your host, and whichever decides first applies."

### 기본 타임아웃

| 대상 | 기본값 |
|---|---|
| command / http (대부분 이벤트) | 600초 |
| UserPromptSubmit | 30초 |
| MessageDisplay | 10초 |
| SessionEnd | 모든 훅 합산 1.5초 (훅별 `timeout` 으로 최대 60초까지) |
| `async: true` | 강제하지 않음 |

타임아웃 시 출력은 버려지고 결정 없음으로 처리된다.

### 종료 코드

| 코드 | 의미 |
|---|---|
| 0 | 성공. stdout 전체가 JSON 객체 하나일 때만 JSON 으로 파싱 |
| 2 | 차단 가능한 이벤트에서 차단 (PermissionRequest 에서는 무시) |
| 그 외 | 비차단 에러. 동작은 진행되고 "hook error" 알림 표시 |

command 훅은 제어 터미널이 없어 `/dev/tty` 를 열 수 없다.

---

## 2. 공통 stdin 필드

| 필드 | 타입 | 비고 |
|---|---|---|
| `session_id` | string | |
| `transcript_path` | string | 비동기로 기록되어 늦을 수 있음 |
| `cwd` | string | Claude 의 `cd`, worktree 전환을 따라감 |
| `hook_event_name` | string | |
| `prompt_id` | string | 첫 입력 전에는 없음 |
| `permission_mode` | string | `default` `plan` `acceptEdits` `auto` `dontAsk` `bypassPermissions`. 일부 이벤트에만 |
| `effort` | object | `{"level": "..."}` |
| `agent_id`, `agent_type` | string | 서브에이전트 안에서 발생한 경우 |

`model` 은 SessionStart 에만 (없을 수도 있음).

---

## 3. 이벤트별 스키마

### SessionStart
- stdin: `source` (`startup` `resume` `clear` `compact` `fork`), `model`?, `session_title`?
- 예: `{"hook_event_name":"SessionStart","source":"startup","model":"claude-opus-5"}`

### SessionEnd
- stdin: `reason` (`clear` `resume` `logout` `prompt_input_exit` `other`)
- 시간 예산 1.5초 (헬퍼는 즉시 종료해야 함)

### UserPromptSubmit
- stdin: `prompt` (붙여넣은 내용은 `<pasted_content id="...">` 로 감싸져 있을 수 있음), `session_title`?
- 예약 작업, `/loop`, 백그라운드 서브에이전트 보고 등에서도 발생

### PreToolUse
- stdin: `tool_name`, `tool_input`, `tool_use_id`, `mcp_server`? (`{name, source}`)
- 파일 경로는 항상 절대 경로
- `tool_input` 형태:
  - `Bash`: `command`, `description`?, `timeout`?, `run_in_background`?
  - `Write`: `file_path`, `content`
  - `Edit`: `file_path`, `old_string`, `new_string`, `replace_all`
  - `Read`: `file_path`, `offset`?, `limit`?
  - `Glob`: `pattern`, `path`?
  - `Grep`: `pattern`, `path`?, `glob`?, `output_mode`?
  - `WebFetch`: `url`, `prompt`
  - `WebSearch`: `query`
  - `Agent`: `prompt`, `description`, `subagent_type`, `model`?
  - `AskUserQuestion`: `questions`, `answers`?
  - `ExitPlanMode`: `plan`, `planFilePath`
  - MCP 툴 이름: `mcp__<server>__<tool>`
  - `MultiEdit`, `NotebookEdit` 은 문서화되지 않음 → 방어적으로 파싱 (`edits: [{old_string, new_string}]`, `notebook_path` 등 **(추정)**)

### PermissionRequest
- 권한을 물으려는 순간 발생. **`tool_use_id` 없음.**
- stdin: `tool_name`, `tool_input`, `mcp_server`?, `permission_suggestions`? (권한 업데이트 항목 배열)
- 예:
  ```json
  {"hook_event_name":"PermissionRequest","tool_name":"Bash",
   "tool_input":{"command":"rm -rf node_modules","description":"Remove node_modules directory"},
   "permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}],"behavior":"allow","destination":"localSettings"}]}
  ```
- stdout: `hookSpecificOutput.decision`
  - 허용: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
  - 항상 허용: `decision` 에 `"updatedPermissions": <permission_suggestions>` 추가
  - 거부: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"..."}}}` (`interrupt: true` 면 Claude 중단)
  - `allow` 는 deny 규칙을 덮어쓰지 못함
- **아무것도 출력하지 않고 exit 0 → 결정 없음 → 기본 권한 흐름 계속** (추정, "leaves the permission flow unchanged")
- exit 2 는 무시됨. 타임아웃 / 기타 에러 → 결정 없음
- 결정은 반드시 동기(`async: false`) 훅이 JSON 객체 하나만 출력해야 함
- 권한 업데이트 항목: `addRules`/`replaceRules`/`removeRules` (`rules`, `behavior`, `destination`), `setMode` (`mode`, `destination`), `addDirectories`/`removeDirectories`. `destination`: `session` `localSettings` `projectSettings` `userSettings`

> ⚠️ **터미널에서 훅이 대기하는 동안 권한 다이얼로그가 동시에 표시되는지는 문서화되지 않음.**
> 데스크톱 앱(호스트 세션)은 "먼저 결정한 쪽 적용". 실측으로 확인해야 한다
> (다이얼로그가 훅 종료까지 보류된다면, 노치 대기 시간 동안 터미널에서 응답할 수 없음).

### PostToolUse
- 성공한 툴 호출 뒤 발생 (실패는 PostToolUseFailure)
- stdin: `tool_name`, `tool_input`, `tool_response`, `tool_use_id`, `duration_ms`?
- 예: `{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"/path/to/file.txt","content":"file content"},"tool_response":{"filePath":"/path/to/file.txt","type":"create"},"tool_use_id":"toolu_01ABC123","duration_ms":12}`

### PostToolUseFailure
- stdin: `tool_name`, `tool_input`, `tool_use_id`, `error` (Bash 는 `Exit code N` 으로 시작), `is_interrupt`?, `duration_ms`?

### Notification
- stdin: `message`, `title`?, `notification_type`
- `notification_type`: `permission_prompt` `idle_prompt` `auth_success` `elicitation_dialog` `elicitation_url_dialog` `elicitation_complete` `elicitation_response` `agent_needs_input` `agent_completed` `quota_auto_resume_fired` `quota_auto_resume_stale` `quota_auto_resume_disabled`
- `permission_prompt` 는 터미널에서 약 6초간 입력이 없을 때 발생 (즉시 신호는 PermissionRequest). 데스크톱 등 호스트는 요청 약 6초 후
- `idle_prompt` 는 완료 후 약 60초간 입력이 없을 때

### MessageDisplay
- 어시스턴트 텍스트가 스트리밍될 때 발생. 텍스트 없는 메시지는 발생 안 함
- stdin: `turn_id`, `message_id`, `index` (0부터), `final` (메시지당 정확히 한 번 true), `delta` (새로 완성된 줄들, 줄바꿈 포함. 마지막 배치는 줄 중간에서 끝나거나 비어 있을 수 있음)
- 인터랙티브: 완성된 줄 묶음마다 발생하고 **훅이 끝날 때까지 렌더링을 멈춘다** → 헬퍼는 즉시 종료해야 함
- `-p` / Agent SDK: 메시지 완료 후 한 번 (`index: 0`, `final: true`, `delta` 에 전체 텍스트)
- 타임아웃 10초. 실패 시 원본 텍스트 표시

### Stop
- 메인 에이전트 응답 완료 시. 사용자 인터럽트 시엔 발생 안 함. API 에러는 StopFailure
- stdin: `stop_hook_active`, `last_assistant_message`, `background_tasks`, `session_crons`

### StopFailure
- stdin: `error` (`rate_limit` `overloaded` `authentication_failed` `billing_error` `invalid_request` `model_not_found` `server_error` `max_output_tokens` `unknown` …), `error_details`?, `last_assistant_message` (API 에러 문구)

### SubagentStart / SubagentStop
- Start: `agent_id`, `agent_type`
- Stop: `agent_id`, `agent_type`, `agent_transcript_path`, `last_assistant_message`, `stop_hook_active`

### PreCompact / PostCompact
- Pre: `trigger` (`manual` `auto`), `custom_instructions`
- Post: `trigger`, `compact_summary`

---

## 4. tool_response 형태와 diff

- **`structuredPatch` 는 문서화되지 않음.** 다만 실제 트랜스크립트(`toolUseResult`)에는 Edit/Write 결과에
  `structuredPatch` (hunk 배열: `oldStart` `oldLines` `newStart` `newLines` `lines`(`"-…"`, `"+…"`, `" …"`)),
  `originalFile`, `filePath`, `type` 이 들어 있는 것을 확인함. PostToolUse `tool_response` 에도 있으면 우선 사용하고,
  없으면 `tool_input` 으로 직접 계산한다.
- Write: 문서상 `{"filePath": "...", "type": "create"}`. 다른 `type` 값(예: `update`) 미문서화
- Edit: `tool_response` 형태 미문서화 → `old_string`/`new_string` 으로 계산
- Bash: `{stdout, stderr, interrupted, isImage}` + 선택적 `bashEditDiff`

### bashEditDiff (v2.1.269+, 베타, best effort)

`tool_response.bashEditDiff`:

| 필드 | 타입 | 의미 |
|---|---|---|
| `changedFiles` | string[] | 절대 경로, 최대 200 |
| `files` | object[] | 최대 5개: `{filePath, hunks: [...], created?, deleted?}` (hunk 형태 미문서화 → structuredPatch 형태로 추정 파싱) |
| `moreFiles` | number | diff 없이 바뀐 파일 수 |
| `unavailable` / `skipped` / `shared` | bool | diff 불완전 / 미수집 / 다른 Bash 와 겹침 |

기본적으로 auto / bypassPermissions 모드에서만 기록된다 (`bashEditDiffEnabled` 설정 시 항상).

---

## 5. 훅 프로세스 환경변수

- 부모 환경을 상속 (`OTEL_*` 제외). `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` 이면 자격 증명 변수 제거.
  → **API 키 등 비밀 정보가 환경에 있을 수 있으므로 헬퍼는 화이트리스트 키만 전달한다.**
- Claude Code 가 설정: `CLAUDE_PROJECT_DIR`, `CLAUDE_EFFORT`, `CLAUDE_CODE_REMOTE`(클라우드) 등
- `CLAUDE_CODE_ENTRYPOINT` 는 문서화되지 않음 (있으면 사용)

---

## 6. 어떤 세션에서 `~/.claude/settings.json` 훅이 실행되나

- 터미널, IDE 확장, **데스크톱 앱**: "Claude Code fires the same hook events wherever it runs" — 같은 설정 파일을 읽음
- 인터랙티브 세션은 폴더 신뢰(trust) 다이얼로그를 수락하기 전까지 훅을 보류
- 클라우드 세션은 로컬 `~/.claude/settings.json` 을 읽지 않음
- Agent SDK / `claude -p`: 기본적으로 사용자 설정 훅 실행 (`--bare` 제외)
- `"disableAllHooks": true` 로 전체 비활성화 가능
