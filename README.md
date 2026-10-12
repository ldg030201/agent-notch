# AgentNotch

맥북 노치를 다이나믹 아일랜드처럼 넓혀서 **Claude Code 세션이 지금 뭘 하는지** 보여주는 macOS 메뉴바 앱이에요.
어떤 파일을 고치는지, 미니 diff, 권한 요청, 완료 알림을 터미널로 돌아가지 않고 노치에서 바로 확인하고 처리할 수 있어요.

- 노치가 없는 외부 모니터에서는 메뉴바 아래에 뜨는 알약(pill) 모양으로 같은 내용을 보여줘요.
- 모든 데이터는 내 맥 안에서만 오가요. 네트워크 통신, 텔레메트리, 디스크 기록이 없어요.

> macOS 14 Sonoma 이상 · Claude Code (터미널, IDE 확장, 데스크톱 앱)

## 주요 기능

| 상태 | 언제 | 노치에 보이는 것 |
|---|---|---|
| **유휴** | 작업 중인 세션이 없을 때 | 오른쪽 날개에 세션 수만큼 점 (작업 중은 초록) |
| **작업 중** | 포커스 세션이 일하는 중 | 스피너 · 프로젝트명 / 지금 쓰는 툴 · `+N −M` |
| **수정 피크** | 파일을 고쳤을 때 | 몇 초 동안 살짝 펼쳐서 파일명 · 줄 번호 · 미니 diff · 응답 한 줄 |
| **권한 요청** | Claude 가 권한을 물을 때 | 다른 세션을 보고 있어도 바로 펼침. **허용 · 항상 허용 · 거부 · 터미널로**. 정할 때까지 유지 |
| **입력 필요** | 질문 · 계획 승인 · MCP 입력 요청 | 질문 내용 + 터미널로 |
| **완료 / 실패** | 턴이 끝났을 때 | 체크(또는 경고) · 걸린 시간 · 바뀐 파일 수 `+N −M` · 마지막 응답 한 줄. 잠시 뒤 자동으로 접힘 |
| **전체 펼침** | 아일랜드를 클릭 | 왼쪽: 세션 목록(우선순위순, 고정 가능) / 오른쪽: 포커스 세션 타임라인 · diff · 최근 응답 |

- **여러 세션 자동 포커스**: 권한 대기 → 입력 대기 → 실패 → 완료 순으로 주의가 필요한 세션이 먼저 떠요.
  없으면 직접 고른 세션, 고정한 세션, 가장 최근에 일한 세션 순서예요.
- **터미널로 이동**: 세션을 띄운 터미널을 앞으로 가져와요. iTerm2 는 해당 탭까지 찾아가요.
- **메뉴바 메뉴**: 세션 목록(클릭하면 포커스, `⌥` 를 누르면 고정/해제), 노치 펼치기, 데모, 훅 설치/제거, 설정.
- **데모 모드**: 훅을 설치하지 않아도 약 40초짜리 가짜 시나리오로 모든 상태를 미리 볼 수 있어요.

## 동작 방식

```
Claude Code ── 훅(command) ──▶ notch-hook                     ~/Library/Application Support/AgentNotch/bin
                                  │ stdin JSON + 허용된 환경변수만
                                  ▼
                       Unix 소켓 notch.sock (0600, 같은 사용자만)
                                  ▼
                       AgentNotch.app ── SessionStore ──▶ 노치 UI (화면마다 패널 하나)
                                  ▲                               │
                                  └────── 권한 결정 (허용/거부) ◀──┘
```

- 훅이 실행할 때마다 작은 헬퍼(`notch-hook`)가 이벤트를 앱으로 넘기고 바로 끝나요.
  **권한 요청만** 노치에서 결정할 때까지 기다리고, 그 결정을 Claude Code 에 돌려줘요.
- 앱이 꺼져 있으면 헬퍼는 아무것도 하지 않고 조용히 끝나요. Claude Code 동작에는 영향이 없어요.

자세한 설계는 [docs/architecture.md](docs/architecture.md), 훅 이벤트 정리는 [docs/hook-events.md](docs/hook-events.md),
화면 목업은 [docs/ui-mockup.html](docs/ui-mockup.html) 을 참고하세요.

## 설치 (Homebrew)

```bash
brew tap OWNER/tap
brew install agent-notch
agent-notch                       # 앱 실행
brew services start agent-notch   # (선택) 로그인할 때 자동 실행
```

**왜 cask 가 아니라 formula(소스 빌드)인가요?**
애플 개발자 계정이 없어서 앱을 서명 · 공증(notarization)할 수 없어요. 미리 빌드한 `.app` 을 내려받으면
quarantine 속성이 붙어 Gatekeeper 가 실행을 막아요. formula 는 내 맥에서 소스를 직접 빌드하기 때문에
quarantine 이 붙지 않고, ad-hoc 서명으로 바로 실행돼요.

- 빌드에는 Xcode 없이 **Command Line Tools (Swift 6 이상)** 만 있으면 돼요: `xcode-select --install`
- 앱은 `$(brew --prefix)/opt/agent-notch/AgentNotch.app` 에 설치돼요. `agent-notch --demo` 처럼 인자를 넘길 수도 있어요.

## 소스에서 빌드

```bash
git clone https://github.com/OWNER/agent-notch.git
cd agent-notch
scripts/build-app.sh              # → build/AgentNotch.app (ad-hoc 서명)
open build/AgentNotch.app
```

`scripts/build-app.sh` 옵션: `--debug`, `--version 0.2.0`, `--output DIR`. `SWIFT_BUILD_FLAGS` 환경변수는 `swift build` 에 그대로 붙어요.

## 처음 실행하기

1. 앱을 실행하면 메뉴바에 아이콘이 생기고, 훅을 설치할지 한 번 물어봐요.
   나중에 하려면 메뉴바 아이콘 → **Claude Code 훅 설치** 를 누르면 돼요.
2. 설치하면 이런 일이 일어나요.
   - `notch-hook` 을 `~/Library/Application Support/AgentNotch/bin/` 에 복사해요 (brew 업그레이드로 경로가 바뀌어도 훅이 깨지지 않게).
   - `~/.claude/settings.json` 을 `settings.json.agentnotch-backup-<날짜>` (0600) 로 백업한 뒤 AgentNotch 항목만 추가해요.
     **다른 훅과 설정은 그대로 둬요.**
3. 새로 시작하는 Claude Code 세션부터 노치에 나타나요. 이미 열려 있던 세션은 다시 시작해야 할 수 있어요.

훅 없이 먼저 구경하려면 메뉴의 **데모 재생** 을 누르거나 `agent-notch --demo` 로 실행하세요.

## 키보드 단축키

아일랜드는 다른 앱의 키보드 포커스를 뺏지 않아요. 아일랜드를 **클릭한 뒤에만** 아래 단축키가 동작해요.

| 단축키 | 동작 |
|---|---|
| `⌘↩` | 허용 |
| `⌥⌘↩` | 항상 허용 (Claude Code 가 제안한 규칙을 저장) |
| `⌘⌫` | 거부 |
| `⎋` | 접기 (요청은 그대로 대기) |
| `⌃⌥⌘N` | 어디서든 노치 펼치기/접기 (전역) |

## 설정

메뉴바 아이콘 → **설정…** (`⌘,`), 또는 펼친 아일랜드의 톱니바퀴.

- **표시 화면**: 모든 화면 / 마우스가 있는 화면 / 내장 화면만
- **풀스크린에서**: 전부 표시 / 알림만 (기본) / 숨김
- **파일 수정 시 미리보기**, 미리보기 · 완료 표시 시간, **응답 스트리밍 표시**
- **권한 요청**: 터미널이 앞에 있으면 노치에서 기다리지 않고 터미널 프롬프트로 바로 넘기기, 노치에서 기다리는 최대 시간
- **Claude Code 훅** 설치 · 다시 설치 · 제거, **로그인 시 실행**, 버전

## 여러 모니터

- 화면마다 아일랜드가 하나씩 있어요. 노치가 있는 화면은 노치 양옆 날개에, 없는 화면은 메뉴바 아래 알약 모양으로 그려요.
- **모든 화면**: 접힌 상태는 모든 화면에, 잠깐 펼치는 알림(권한 요청, 피크, 완료)은 **마우스가 있는 화면**에만 보여요.
- 클릭해서 펼친 아일랜드는 클릭한 화면에서만 펼쳐져요.
- 화면을 연결하거나 해상도를 바꾸면 자동으로 다시 배치해요.

## 개인정보 · 보안

- **네트워크 통신이 없어요.** 분석 · 텔레메트리도 없어요.
- 헬퍼와 앱은 Unix 소켓으로만 통신해요. 소켓 폴더는 0700, 소켓은 0600 이고, 연결한 프로세스가 같은 사용자인지 확인해요.
- 훅 프로세스의 환경변수는 **허용 목록에 있는 것만** 넘겨요
  (`TERM_PROGRAM`, `ITERM_SESSION_ID`, `TERM_SESSION_ID`, `__CFBundleIdentifier`, `CLAUDE_CODE_ENTRYPOINT`, `TMUX_PANE`).
  API 키 같은 다른 환경변수는 앱으로 가지 않아요.
- 프롬프트 · 코드 · 응답은 메모리에만 두고 디스크에 쓰지 않아요. 오래된 세션은 자동으로 정리해요.
  로그는 `os.Logger` 로 남기고 내용이 들어가는 값은 `private` 으로 가려요.
- `~/.claude/settings.json` 을 바꾸기 전에 항상 백업하고, AgentNotch 항목만 추가 · 제거해요.
- 노치에서 파일을 열 때 실행될 수 있는 파일(앱, `.command` 등)은 열지 않고 Finder 에서 위치만 보여줘요.

## 제거

1. 메뉴바 아이콘 → **훅 제거** (settings.json 에서 AgentNotch 항목만 지워요)
2. `brew services stop agent-notch`
3. `brew uninstall agent-notch` (필요하면 `brew untap OWNER/tap`)
4. 남은 파일 정리

   ```bash
   rm -rf ~/Library/"Application Support"/AgentNotch
   rm -f ~/Library/LaunchAgents/dev.agentnotch.AgentNotch.plist   # 설정에서 '로그인 시 실행'을 켰던 경우
   defaults delete dev.agentnotch.AgentNotch                       # 설정값
   ```

훅을 지우지 않고 앱만 지웠다면 `~/.claude/settings.json` 에서 명령에 `AgentNotch/bin/notch-hook` 이 들어간 항목을 지우면 돼요.

## 문제 해결

**노치에 아무것도 안 떠요**
- 메뉴바 아이콘에서 훅 상태가 **설치됨** 인지 확인하세요. 설치 직후라면 Claude Code 세션을 새로 시작하세요.
- 앱이 이벤트를 받을 수 있는지 확인:
  `~/Library/"Application Support"/AgentNotch/bin/notch-hook --ping && echo OK`
- 세션이 하나도 없으면 아일랜드는 숨어 있어요. `⌃⌥⌘N` 으로 펼쳐 볼 수 있어요.

**권한 요청은 어떻게 처리되나요?**
- 노치에서 고른 결정이 Claude Code 에 그대로 전달돼요.
- **터미널로** 를 누르거나, 설정한 대기 시간(기본 120초)이 지나면 결정을 Claude Code 기본 권한 프롬프트로 넘겨요.
- 세션을 띄운 터미널이 이미 앞에 있으면(설정에서 끌 수 있음) 노치는 알려주기만 하고 바로 터미널 프롬프트로 넘겨요.
- 노치가 기다리는 동안 터미널의 권한 다이얼로그가 같이 보이는지는 Claude Code 버전에 따라 다를 수 있어요.

**iTerm2 제어 허용 창이 떠요**
- **터미널로** 를 처음 누르면 AgentNotch 가 iTerm2 를 제어해도 되는지 묻는 창이 떠요. 세션이 있는 탭으로 이동하는 데만 써요.
- 거부했다면 시스템 설정 → 개인정보 보호 및 보안 → 자동화 에서 다시 켤 수 있어요.
- ad-hoc 서명이라 업데이트할 때마다 다시 물어볼 수 있어요.

**"AgentNotch 가 이미 실행 중이에요"**
- 한 번에 하나만 실행돼요. 메뉴바 아이콘을 확인하세요.

**메뉴바 아이콘이 안 보여요**
- 메뉴바 아이콘이 많으면 노치 뒤로 밀려 가려질 수 있어요. `⌃⌥⌘N` 으로 아일랜드를 펼친 뒤 톱니바퀴로 설정을 열 수 있어요.

**더 자세한 로그**
```bash
log stream --level debug --predicate 'subsystem == "dev.agentnotch.AgentNotch"'
AGENT_NOTCH_DEBUG=1 ~/Library/"Application Support"/AgentNotch/bin/notch-hook --ping   # 헬퍼 진단을 stderr 로 출력
```

## 개발

```bash
swift build                       # 전체 빌드
scripts/test.sh                   # 테스트 (swift test 래퍼)
swift run AgentNotch --demo       # 번들 없이 데모로 실행
```

- Command Line Tools 만 있으면 `swift test` 가 Swift Testing 매크로 플러그인을 못 찾아요.
  `scripts/test.sh` 가 플러그인 경로(`-plugin-path`)를 붙여서 실행해요.
- CLT 의 SDK 에는 SwiftUI 매크로 플러그인이 없어서 `@State`, `#Preview`, `@Entry` 를 쓰면 빌드가 깨져요.
  `@Observable` 모델 객체를 대신 써요.

**훅 없이 이벤트 흘려 보기** (`~/.claude` 를 건드리지 않아요)

```bash
export AGENT_NOTCH_SOCKET=/tmp/agent-notch-dev.sock
build/AgentNotch.app/Contents/MacOS/AgentNotch &      # 같은 소켓으로 앱 실행
scripts/simulate-events.sh                            # Fixtures/events/*.json 을 순서대로 전송
```

`--fast` 는 대기 시간을 줄이고, `--keep` 은 마지막 `SessionEnd` 를 보내지 않아요. 권한 요청 단계에서는 노치에서 고른 결정이 터미널에 출력돼요.

| 모듈 | 역할 |
|---|---|
| `NotchShared` | 와이어 프로토콜(`HookEnvelope`, `HookReply`), `JSONValue` |
| `notch-hook` | 훅 헬퍼 실행 파일 |
| `NotchCore` | 세션 상태(`SessionStore`), 포커스 엔진, diff 계산, 툴 요약, 설정 |
| `NotchServices` | 소켓 서버, 훅 설치기, 터미널 이동, 사운드, 로그인 시 실행 |
| `NotchUI` | 노치 패널, 아일랜드 SwiftUI 뷰, 설정 화면 |
| `AgentNotch` | 앱 진입점, 메뉴바, 모듈 조립, 데모 |

Homebrew formula 는 [packaging/homebrew/agent-notch.rb](packaging/homebrew/agent-notch.rb) 에 있어요.
릴리스할 때 태그와 `sha256` 을 갱신해서 tap 저장소의 `Formula/` 로 복사하면 돼요.

## 라이선스

TBD
