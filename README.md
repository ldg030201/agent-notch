<div align="center">

# AgentNotch

**맥북 노치를 다이나믹 아일랜드처럼 넓혀서 Claude Code 세션이 지금 뭘 하는지 보여주는 메뉴바 앱**

![macOS](https://img.shields.io/badge/macOS-14+-3A72C4?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
[![Release](https://img.shields.io/github/v/release/ldg030201/agent-notch?label=release&color=3A72C4)](https://github.com/ldg030201/agent-notch/releases)
![Dependencies](https://img.shields.io/badge/dependencies-0-57CC85)
![License](https://img.shields.io/badge/license-미정-lightgrey)

</div>

---

어떤 파일을 고치는지, 미니 diff, 권한 요청, 완료 알림을 터미널로 돌아가지 않고 노치에서 바로 확인하고 처리해요.

- 노치가 없는 외부 모니터에서는 **메뉴바 안**에 들어가는 알약(pill) 모양으로 같은 내용을 보여줘요.
- 세션 내용은 전부 내 맥 안에서만 오가요. 네트워크 통신은 하루 한 번 새 버전 확인뿐이고, 설정에서 끌 수 있어요.

## ✨ 주요 기능

| 상태 | 언제 | 노치에 보이는 것 |
|---|---|---|
| **유휴** | 작업 중인 세션이 없을 때 | 오른쪽 날개에 세션 수만큼 점 (작업 중은 초록) |
| **작업 중** | 포커스 세션이 일하는 중 | 스피너 · 프로젝트명 / 지금 쓰는 툴 · `+N −M` |
| **수정 피크** | 파일을 고쳤을 때 | 몇 초 동안 살짝 펼쳐서 파일명 · 줄 번호 · 미니 diff · 응답 한 줄 |
| **권한 요청** | Claude 가 권한을 물을 때 | 다른 세션을 보고 있어도 바로 펼침. **허용 · 항상 허용 · 거부 · 터미널로**. 정할 때까지 유지 |
| **입력 필요** | 질문 · 계획 승인 · MCP 입력 요청 | 질문 내용 + 터미널로 |
| **완료 / 실패** | 턴이 끝났을 때 | 체크(또는 경고) · 걸린 시간 · 바뀐 파일 수 `+N −M` · 마지막 응답 한 줄. 잠시 뒤 자동으로 접힘 |
| **전체 펼침** | 아일랜드를 클릭 | 왼쪽: 세션 목록(우선순위순, 고정 가능) / 오른쪽: 포커스 세션 타임라인 · diff · 최근 응답 |

- **여러 세션 자동 포커스** — 권한 대기 → 입력 대기 → 실패 → 완료 순으로 주의가 필요한 세션이 먼저 떠요.
  없으면 직접 고른 세션, 고정한 세션, 가장 최근에 일한 세션 순서예요.
- **터미널로 이동** — 세션을 띄운 터미널을 앞으로 가져와요. iTerm2 는 해당 탭까지 찾아가요.
- **메뉴바 메뉴** — 세션 목록(클릭하면 포커스, `⌥` 를 누르면 고정/해제), 노치 펼치기, 데모, 훅 설치/제거, 설정.
- **데모 모드** — 훅을 설치하지 않아도 약 40초짜리 가짜 시나리오로 모든 상태를 미리 볼 수 있어요.
- **새 버전 알림과 앱 안 업데이트** — 설정 "버전" 탭에서 변경 내역을 보고 버튼 하나로 올려요.

## 📦 설치

```bash
brew tap ldg030201/agent-notch https://github.com/ldg030201/agent-notch && brew trust ldg030201/agent-notch && brew install -y agent-notch && cp -R "$(brew --prefix agent-notch)/AgentNotch.app" /Applications/ && open /Applications/AgentNotch.app
```

| 단계 | 하는 일 |
|---|---|
| `brew tap …` | 이 저장소를 tap 으로 추가 (저장소 뿌리의 `Formula/agent-notch.rb`) |
| `brew trust …` | 서드파티 tap 의 formula 를 Homebrew 가 불러올 수 있게 신뢰 |
| `brew install -y agent-notch` | 미리 빌드한 bottle 을 받거나, 없으면 내 맥에서 소스 빌드 |
| `cp -R … /Applications/` | 앱을 `/Applications` 에 복사 (심볼릭 링크는 Launchpad · Spotlight 가 앱으로 못 알아봐요) |

### 필요한 것

| | 최소 | 비고 |
|---|---|---|
| **macOS** | 14 (Sonoma) | 노치 없는 맥 · 외부 모니터도 지원 |
| **Claude Code** | 훅을 지원하는 버전 | 터미널 · IDE 확장 · 데스크톱 앱 |
| **Homebrew** | — | 설치 · 업데이트에 써요 |
| **미리 빌드한 결과물(bottle)** | Apple Silicon · macOS 15 / 26 | 그 외(macOS 14, Intel)는 소스에서 빌드해요 (조금 오래 걸릴 뿐 실패하지 않아요) |
| **Swift 툴체인** | 6.0 | **소스에서 빌드할 때만.** Command Line Tools 로 충분해요: `xcode-select --install` |
| **Xcode** | 필요 없음 | |
| **외부 의존성** | 없음 | Swift 패키지 0개 |

### 왜 cask 가 아니라 formula 인가요?

애플 개발자 계정이 없어서 앱을 서명 · 공증(notarization)할 수 없어요. cask 로 미리 빌드한 `.app` 을 내려받으면
quarantine 속성이 붙어 Gatekeeper 가 "확인되지 않은 개발자" 로 실행을 막아요.
formula 는 내 맥에서 소스를 빌드하거나 Homebrew 가 bottle 을 직접 풀기 때문에 quarantine 이 붙지 않고, ad-hoc 서명으로 바로 실행돼요.

## 🚀 처음 실행하기

1. 앱을 실행하면 메뉴바에 아이콘이 생기고, 훅을 설치할지 한 번 물어봐요.
   나중에 하려면 메뉴바 아이콘 → **Claude Code 훅 설치** 를 누르면 돼요.
2. 설치하면 이런 일이 일어나요.
   - `notch-hook` 을 `~/Library/Application Support/AgentNotch/bin/` 에 복사해요 (업데이트로 Homebrew 경로가 바뀌어도 훅이 깨지지 않게).
   - `~/.claude/settings.json` 을 `settings.json.agentnotch-backup-<날짜>` (0600) 로 백업한 뒤 AgentNotch 항목만 추가해요.
     **다른 훅과 설정은 그대로 둬요.**
3. 새로 시작하는 Claude Code 세션부터 노치에 나타나요. 이미 열려 있던 세션은 다시 시작해야 할 수 있어요.

훅 없이 먼저 구경하려면 메뉴의 **데모 재생** 을 누르거나 `open /Applications/AgentNotch.app --args --demo` 로 실행하세요.

## 🔄 업데이트

**앱 안에서** — 설정 → **버전** 탭에 새 버전이 뜨면 **업데이트** 를 누르세요.
앱이 `brew upgrade agent-notch` 를 직접 돌리면서 진행 로그를 보여주고, 다 받으면 **지금 다시 띄우기** 를 누를 때까지 기다려요.
누르면 앱이 잠깐 꺼졌다가 `/Applications` 사본을 새 버전으로 바꾸고 다시 떠요 (교체 기록: `~/Library/Application Support/AgentNotch/upgrade.log`).

**터미널에서**

```bash
# 1. 새 버전 받기
git -C "$(brew --repository ldg030201/agent-notch)" pull -q || brew update
brew upgrade agent-notch
# 2. 앱을 끄고 /Applications 사본을 바꾼 뒤 다시 띄우기
pkill -f /Applications/AgentNotch.app/Contents/MacOS/AgentNotch; sleep 1
rm -rf /Applications/AgentNotch.app && cp -R "$(brew --prefix agent-notch)/AgentNotch.app" /Applications/ && open /Applications/AgentNotch.app
```

> `git -C … pull` 은 이 tap 하나만 갱신해요 (금방 끝나요). `brew update` 는 Homebrew 와 모든 tap 을 갱신해서 오래 걸리므로 실패했을 때만 써요.
> `brew upgrade` 만 하면 `/Applications` 쪽은 옛 버전 그대로예요. 꼭 다시 복사해 주세요.

새 버전 확인은 하루 한 번이고, 설정 → 버전 → **하루에 한 번 새 버전 확인** 으로 끌 수 있어요.

## ⌨️ 키보드 단축키

아일랜드는 다른 앱의 키보드 포커스를 뺏지 않아요. 아일랜드를 **클릭한 뒤에만** 아래 단축키가 동작해요.

| 단축키 | 동작 |
|---|---|
| `⌘↩` | 허용 |
| `⌥⌘↩` | 항상 허용 (Claude Code 가 제안한 규칙을 저장) |
| `⌘⌫` | 거부 |
| `⎋` | 접기 (요청은 그대로 대기) |
| `⌃⌥⌘N` | 어디서든 노치 펼치기/접기 (전역) |

## 🎛️ 설정

메뉴바 아이콘 → **설정…** (`⌘,`), 또는 펼친 아일랜드의 톱니바퀴.

| 탭 | 내용 |
|---|---|
| **일반** | 권한 요청(터미널이 앞에 있으면 터미널로 넘기기, 대기 시간), Claude Code 훅 설치 · 제거, 로그인 시 실행 |
| **표시** | 표시 화면, 풀스크린 동작, 파일 수정 미리보기, 응답 스트리밍, 외부 모니터 표시, 노치 옆이 막혔을 때, 손쉬운 사용 권한 |
| **버전** | 지금 버전, 새 버전 확인 · 업데이트, 변경 내역 |

## 🖥️ 메뉴바 · 외부 모니터

노치 양옆 메뉴바는 다른 앱의 메뉴(왼쪽)와 상태 아이콘(오른쪽) 자리예요. 아일랜드는 **이것들을 덮지 않아요.**

**노치가 있는 화면**
- 양쪽이 비어 있으면 노치 양옆 날개에, 왼쪽이 막혔으면 오른쪽 날개 하나에 모아서 보여줘요.
- 양쪽 다 부족하면 노치 바로 아래 얇은 띠로 내려서 보여줘요 (설정에서 **선만** 으로 바꾸면 상태 색 선 하나).
- 다른 노치 앱이 노치를 쓰고 있으면 알아채고 노치 아래로 비켜요.

**노치가 없는 화면 (외부 모니터)**
- 접힌 아일랜드는 **메뉴바 안**의 빈 구간에 들어가는 알약이에요. 브라우저 탭이나 툴바를 가리지 않아요.
- 빈 구간이 좁으면 점 하나로 줄이고, 그것도 안 되면 접힌 상태는 숨겨요 (알림은 그대로 떠요).
- 메뉴바가 숨겨진 화면(자동 숨김 · 풀스크린)에서는 접힌 상태를 숨겨요.
- 설정 → 표시 → **외부 모니터 표시** 에서 메뉴바 아래 / 표시 안 함 으로 바꿀 수 있어요.

**공통**
- 펼친 카드는 메뉴바 아래로 내려와요. 미리보기 · 완료는 잠깐 보이고 접히고, 카드 밖을 클릭하거나 `⎋` 를 누르면 바로 접혀요.
  권한 카드도 접어 둘 수 있고(알약에 주황 점), 요청은 그대로 기다려요.
- 다른 앱의 메뉴 · 팝오버가 열리면 잠깐 숨고, 권한 요청은 메뉴가 닫힐 때까지 펼치기를 미뤄요.
- **손쉬운 사용 권한을 주면** 앱 메뉴와 메뉴바 아이콘 위치를 정확히 재서 남는 자리를 최대한 써요.
  권한이 없으면 막혀 있다고 보고 안전하게 비켜 가요 (설정 → 표시 → **손쉬운 사용 권한 요청**).
- 권한은 서명 신원에 묶여요. ad-hoc 서명으로 빌드된 앱(Homebrew 설치 포함)은 **업데이트한 뒤 다시 허용해야 할 수 있어요.**

**여러 모니터** — 화면마다 아일랜드가 하나씩 있어요. 접힌 상태는 모든 화면에, 잠깐 펼치는 알림(권한 요청 · 피크 · 완료)은
마우스가 있는 화면에만 보여요. 클릭해서 펼친 아일랜드는 그 화면에서만 펼쳐져요.

## 🔒 개인정보 · 보안

- **네트워크 통신은 새 버전 확인 하나뿐이에요.** 하루 한 번 GitHub 의 `docs/changelog.json` 을 받아요
  (보내는 건 `agent-notch/<버전>` User-Agent 정도). 설정에서 끌 수 있고, 받은 내용은 디스크에 저장하지 않아요. 분석 · 텔레메트리는 없어요.
- 업데이트 버튼을 누르면 그때만 Homebrew(`brew upgrade`)가 GitHub 에서 새 버전을 받아요.
- 헬퍼와 앱은 Unix 소켓으로만 통신해요. 소켓 폴더는 0700, 소켓은 0600 이고, 연결한 프로세스가 같은 사용자인지 확인해요.
- 훅 프로세스의 환경변수는 **허용 목록에 있는 것만** 넘겨요
  (`TERM_PROGRAM`, `ITERM_SESSION_ID`, `TERM_SESSION_ID`, `__CFBundleIdentifier`, `CLAUDE_CODE_ENTRYPOINT`, `TMUX_PANE`).
  API 키 같은 다른 환경변수는 앱으로 가지 않아요.
- 프롬프트 · 코드 · 응답은 메모리에만 두고 디스크에 쓰지 않아요. 오래된 세션은 자동으로 정리해요.
  로그는 `os.Logger` 로 남기고 내용이 들어가는 값은 `private` 으로 가려요.
- `~/.claude/settings.json` 을 바꾸기 전에 항상 백업하고, AgentNotch 항목만 추가 · 제거해요.
- 노치에서 파일을 열 때 실행될 수 있는 파일(앱, `.command` 등)은 열지 않고 Finder 에서 위치만 보여줘요.

## 🗑️ 제거

1. 메뉴바 아이콘 → **훅 제거** (settings.json 에서 AgentNotch 항목만 지워요). **앱을 지우기 전에 먼저 하세요.**
2. 로그인 시 실행을 켰다면 설정 → 일반 에서 끄세요.
3. 앱을 끄고 지우기

   ```bash
   pkill -f /Applications/AgentNotch.app/Contents/MacOS/AgentNotch
   brew uninstall agent-notch
   rm -rf /Applications/AgentNotch.app
   rm -rf ~/Library/"Application Support"/AgentNotch
   brew untap ldg030201/agent-notch                 # (선택)
   defaults delete com.ldg.agent-notch              # (선택) 설정값
   ```

훅을 지우지 않고 앱만 지웠다면 `~/.claude/settings.json` 에서 명령에 `AgentNotch/bin/notch-hook` 이 들어간 항목을 지우면 돼요.

## 🩺 문제 해결

**노치에 아무것도 안 떠요**
- 메뉴바 아이콘에서 훅 상태가 **설치됨** 인지 확인하세요. 설치 직후라면 Claude Code 세션을 새로 시작하세요.
- 앱이 이벤트를 받을 수 있는지 확인:
  `~/Library/"Application Support"/AgentNotch/bin/notch-hook --ping && echo OK`
- 세션이 하나도 없으면 아일랜드는 숨어 있어요. `⌃⌥⌘N` 으로 펼쳐 볼 수 있어요.

**권한 요청은 어떻게 처리되나요?**
- 노치에서 고른 결정이 Claude Code 에 그대로 전달돼요.
- **터미널로** 를 누르거나, 설정한 대기 시간(기본 120초)이 지나면 결정을 Claude Code 기본 권한 프롬프트로 넘겨요.
- 세션을 띄운 터미널이 이미 앞에 있으면(설정에서 끌 수 있음) 노치는 알려주기만 하고 바로 터미널 프롬프트로 넘겨요.

**iTerm2 제어 허용 창이 떠요 / 업데이트할 때마다 또 물어요**
- **터미널로** 를 처음 누르면 iTerm2 를 제어해도 되는지 묻는 창이 떠요. 세션이 있는 탭으로 이동하는 데만 써요.
- 거부했다면 시스템 설정 → 개인정보 보호 및 보안 → 자동화 에서 다시 켤 수 있어요.
- ad-hoc 서명이라 업데이트할 때마다 다시 물어볼 수 있어요 (손쉬운 사용 권한도 같아요).

**업데이트가 멈췄어요**
- 교체 중에 오래 멈춰 있으면 화면의 **강제 종료…** 로 끌 수 있어요. 기록은 `~/Library/Application Support/AgentNotch/upgrade.log` 에 있어요.
- 위의 **터미널에서** 명령으로 직접 올려도 돼요.

**"AgentNotch 가 이미 실행 중이에요"**
- 한 번에 하나만 실행돼요. 메뉴바 아이콘을 확인하세요.

**메뉴바 아이콘이 안 보여요**
- 메뉴바 아이콘이 많으면 노치 뒤로 밀려 가려질 수 있어요. `⌃⌥⌘N` 으로 아일랜드를 펼친 뒤 톱니바퀴로 설정을 열 수 있어요.

**더 자세한 로그**
```bash
log stream --level debug --predicate 'subsystem == "com.ldg.agent-notch" OR subsystem == "AgentNotch"'
AGENT_NOTCH_DEBUG=1 ~/Library/"Application Support"/AgentNotch/bin/notch-hook --ping   # 헬퍼 진단을 stderr 로 출력
```

## 🔧 동작 방식

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

- 훅이 실행될 때마다 작은 헬퍼(`notch-hook`)가 이벤트를 앱으로 넘기고 바로 끝나요.
  **권한 요청만** 노치에서 결정할 때까지 기다리고, 그 결정을 Claude Code 에 돌려줘요.
- 앱이 꺼져 있으면 헬퍼는 아무것도 하지 않고 조용히 끝나요. Claude Code 동작에는 영향이 없어요.

자세한 설계는 [docs/architecture.md](docs/architecture.md), 훅 이벤트 정리는 [docs/hook-events.md](docs/hook-events.md),
화면 목업은 [docs/ui-mockup.html](docs/ui-mockup.html) 을 참고하세요.

## 🛠️ 개발

```bash
git clone https://github.com/ldg030201/agent-notch.git && cd agent-notch
scripts/dev.sh                    # 테스트판(AgentNotch-Test) 빌드 후 다시 띄우기 · `scripts/dev.sh watch` 는 저장할 때마다
scripts/test.sh                   # 테스트 (Command Line Tools 용 swift test 래퍼)
VARIANT=test scripts/build.sh     # build/AgentNotch-Test.app 만 만들기
```

| 명령 | 하는 일 |
|---|---|
| `scripts/build.sh` | `build/AgentNotch.app` (정식판). 버전 세 곳이 다르면 멈춰요. 서명 인증서가 없으면 ad-hoc |
| `scripts/simulate-events.sh` | `Fixtures/events/*.json` 을 실행 중인 앱에 훅처럼 흘려요 (`~/.claude` 를 건드리지 않음) |
| `AgentNotch --render-island all <폴더> --style both` | 아일랜드 장면을 PNG 로 저장 (권한 불필요, 가짜 데이터) |
| `AgentNotch --demo` | 데모 시나리오로 시작 (`open <앱> --args --demo`) |
| `AgentNotch --dump-changelog [경로]` | 변경 내역 JSON (`source scripts/lib.sh && dump_changelog` 로 docs/changelog.json 갱신) |
| `AgentNotch --probe-upgrade` | brew 위치와 업데이트 스크립트 문법만 점검 (실행하지 않음) |
| `AgentNotch --version` | `agent-notch 0.1.0` |

- 테스트판은 번들 ID 가 `com.ldg.agent-notch-test` 라 설정을 정식판과 나눠 쓰고, 새 버전 확인 · 자체 업데이트를 하지 않아요.
- Command Line Tools 의 SDK 에는 SwiftUI 매크로 플러그인이 없어서 `@State`, `#Preview`, `@Entry` 를 쓰면 빌드가 깨져요. `@Observable` 모델을 써요.

| 모듈 | 역할 |
|---|---|
| `NotchShared` | 와이어 프로토콜(`HookEnvelope`, `HookReply`), `JSONValue` |
| `notch-hook` | 훅 헬퍼 실행 파일 |
| `NotchCore` | 세션 상태(`SessionStore`), 포커스 엔진, diff 계산, 툴 요약, 설정 |
| `NotchServices` | 소켓 서버, 훅 설치기, 터미널 이동, 로그인 시 실행, 업데이트 확인 · 업그레이드 |
| `NotchUI` | 노치 패널, 아일랜드 SwiftUI 뷰, 설정 화면 |
| `AgentNotch` | 앱 진입점, 메뉴바, 모듈 조립, 데모, 변경 내역 |

릴리스 절차 · 버전 규칙 · 변경 내역 쓰는 법 · 서명 인증서는 [docs/development.md](docs/development.md) 에 있어요.

## 📄 라이선스

미정
