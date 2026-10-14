# 개발 · 릴리스

[← README](../README.md) · 사용법은 [usage.md](usage.md) · 설계는 [architecture.md](architecture.md)

## 빠르게 시작

```bash
git clone https://github.com/ldg030201/agent-notch.git && cd agent-notch
scripts/dev.sh                    # 테스트판(AgentNotch-Test) 빌드 후 다시 띄우기 · `scripts/dev.sh watch` 는 저장할 때마다
scripts/test.sh                   # 테스트 (Command Line Tools 용 swift test 래퍼)
VARIANT=test scripts/build.sh     # build/AgentNotch-Test.app 만 만들기
```

| 명령 | 하는 일 |
|---|---|
| `scripts/build.sh` | `build/AgentNotch.app` (정식판). 버전 세 곳이 다르면 멈춘다. 서명 인증서가 없으면 ad-hoc |
| `scripts/run.sh` | 빌드된 정식판을 다시 띄운다 (켜져 있으면 끄고 켬, 없으면 먼저 빌드). `--build` 로 새로 빌드, 그 밖의 인자는 앱에 그대로 (`--demo` 등) |
| `scripts/stop.sh` | 실행 중인 앱을 끈다 (정상 종료로 소켓 정리, 5초 안에 안 꺼지면 강제). 테스트판은 `VARIANT=test` |
| `AgentNotch --install-hooks` | Claude Code 훅 설치 (settings.json 백업 후 AgentNotch 항목만 추가, `--no-message-display` 로 응답 스트리밍 훅 제외) |
| `AgentNotch --uninstall-hooks` | AgentNotch 훅만 제거 (다른 훅은 그대로) |
| `AgentNotch --hook-status` | 훅 설치 상태 확인 |

| 모듈 | 역할 |
|---|---|
| `NotchShared` | 와이어 프로토콜(`HookEnvelope`, `HookReply`), `JSONValue` |
| `notch-hook` | 훅 헬퍼 실행 파일 |
| `NotchCore` | 세션 상태(`SessionStore`), 포커스 엔진, diff 계산, 툴 요약, 설정 |
| `NotchServices` | 소켓 서버, 훅 설치기, 터미널 이동, 로그인 시 실행, 업데이트 확인 · 업그레이드 |
| `NotchUI` | 노치 패널, 아일랜드 SwiftUI 뷰, 설정 화면 |
| `AgentNotch` | 앱 진입점, 메뉴바, 모듈 조립, 데모, 변경 내역 |

## 툴체인

- **Command Line Tools 만** 있으면 된다 (Xcode 불필요). Swift 6.0 이상, Swift 5 언어 모드, macOS 14+.
- CLT 의 SDK 에는 SwiftUI 매크로 플러그인이 없다. `@State` · `#Preview` · `@Entry` · `@Previewable` · `@Animatable` 를 쓰면
  빌드가 깨진다. 상태는 `@Observable` 모델 객체에 둔다.
- `swift test` 는 CLT 에서 Swift Testing 매크로 플러그인을 못 찾는다. 항상 `scripts/test.sh` 로 돌린다.

## 정식판과 테스트판

**두 앱이 별개로 떠 있을 수 있다.**

| | 정식판 | 테스트판 |
|---|---|---|
| 번들 | `build/AgentNotch.app` | `build/AgentNotch-Test.app` |
| 번들 ID | `com.ldg.agent-notch` | `com.ldg.agent-notch-test` |
| 만드는 법 | `scripts/build.sh` (릴리스 · Homebrew 가 부름) | `VARIANT=test scripts/build.sh`, `scripts/dev.sh` |
| 새 버전 확인 · 자체 업데이트 | 함 | **하지 않음** (brew 가 설치한 게 아니라 자기를 바꿀 수 없다) |

- 번들 ID 가 달라서 설정(UserDefaults)을 나눠 쓴다. 실행 파일 이름은 둘 다 `AgentNotch` 이고 번들 이름만 다르다.
- **소켓 · 훅 헬퍼 경로는 같이 쓴다** (`~/Library/Application Support/AgentNotch/`). 정식판이 떠 있으면 테스트판은
  "이미 실행 중" 으로 끝난다. 정식판을 켜 둔 채로 개발하려면 소켓을 나눈다:

  ```bash
  AGENT_NOTCH_SOCKET=/tmp/an-dev.sock scripts/dev.sh
  AGENT_NOTCH_SOCKET=/tmp/an-dev.sock scripts/simulate-events.sh
  ```

- 개발 중에는 정식 번들을 만들지 않는다. brew 로 설치해 쓰는 배포본과 헷갈린다. 실수로 만들었으면 `build/AgentNotch.app` 을 지운다.
- **빌드했다고 화면이 바뀌지 않는다.** 떠 있는 앱은 옛 바이너리다. `scripts/dev.sh` 가 끄고 다시 띄운다 (`watch` 를 붙이면 저장할 때마다).
  정식판(`build/AgentNotch.app`)은 `scripts/run.sh` (필요하면 `--build`) 로 다시 띄우고 `scripts/stop.sh` 로 끈다.
  `run.sh` 는 소켓이 열려 훅을 받을 준비가 될 때까지 기다렸다가 결과를 알려준다.

## 화면 없이 확인하기

| 명령 | 용도 |
|---|---|
| `AgentNotch --render-island <장면\|all> <폴더> [--style notch\|menubar\|both]` | 아일랜드 장면 PNG. 화면 기록 권한 불필요, 가짜 데이터. 화면에 영향을 주는 변경은 이걸로 먼저 본다 |
| `AgentNotch --demo` | 데모 시나리오로 시작 (`open build/AgentNotch-Test.app --args --demo`) |
| `scripts/simulate-events.sh [--fast] [--keep]` | `Fixtures/events/*.json` 을 `notch-hook` 으로 실행 중인 앱에 흘린다. 권한 요청 단계는 노치에서 고른 결정을 출력 |
| `AgentNotch --dump-changelog [경로]` | 변경 내역 JSON |
| `AgentNotch --probe-upgrade` | brew 위치와 업데이트 · 교체 스크립트 문법(`bash -n`)만 점검. **실행하지 않는다** |
| `AgentNotch --version` | `agent-notch <버전>` |
| `AgentNotch --help` | 인자 목록. 모르는 `--` 인자는 앱을 띄우지 않고 사용법을 보여주며 끝난다 (실수로 두 번째 앱이 떠 "이미 실행 중" 창이 뜨지 않게) |

- 오프스크린 렌더링은 AppKit 기반 컨트롤(Picker, 스위치, ScrollView 등)을 못 그려서 스냅숏에서만 비슷한 SwiftUI 그림으로 대체한다.
- 권한(자동화)이 걸리는 동작은 터미널에서 바이너리를 직접 부르면 TCC 가 터미널 앱에 권한을 물어 결과가 틀린다.
  `open -n build/AgentNotch-Test.app --args …` 처럼 번들로 띄워서 확인한다.

## 서명 인증서

자동화(iTerm2 AppleScript) 권한은 **코드 서명 신원**에 묶인다. ad-hoc 서명에는 신원이 없어 macOS 가 바이너리 해시로
앱을 알아보는데, 해시는 빌드할 때마다 바뀐다. 그래서 다시 빌드하거나 업데이트하면 허용해 둔 권한이 풀린다.

```bash
scripts/make-signing-cert.sh       # 한 번만. 로그인 키체인에 "AgentNotch Local Signing" 을 만든다
codesign -dv --verbose=4 build/AgentNotch-Test.app 2>&1 | grep Authority
```

- 인증서가 있으면 `scripts/build.sh` 가 그걸로, 없거나 실패하면 ad-hoc 으로 서명한다. **서명 때문에 빌드가 실패하지는 않는다.**
- 개인키는 임시 폴더에서만 만들고 바로 지운다. p12 암호도 매번 새로 만드는 일회용이다.
- **인증서를 배포하지 않는다.** 개인키가 새면 그 키로 서명한 앱을 macOS 가 같은 앱으로 보고 허용해 둔 권한을 물려받는다.
  그래서 Homebrew 사용자(bottle 포함)는 ad-hoc 이고, 업데이트 후 권한을 다시 물을 수 있다 ([usage.md](usage.md) 에 안내).

## 버전

`주.부.수` 세 자리, **긴급 수정은 네 번째 자리**를 붙인다. 태그는 `v<버전>` (예: `v0.2.0`, `v0.2.0.1`).

| 자리 | 예 | 언제 |
|---|---|---|
| 첫 번째 | `1.0.0` | 크게 뜯어고쳤을 때만. 아껴서 올린다 |
| 두 번째 | `0.1.0` → `0.2.0` | 기능 추가 · 쓰는 방법이 달라지는 변경 |
| 세 번째 | `0.1.1` | 오류 수정 · 설정 하나 추가 · 기본값 변경 같은 소소한 변경 |
| 네 번째 | `0.1.0.1` | 방금 나간 버전을 급히 고칠 때만 |

- **애매하면 세 번째 자리로 간다.** 두 번째 자리를 아껴 두면 "이 버전에서 뭐가 늘었더라" 를 번호만 보고 짚을 수 있다.
- 두 번째 자리는 10 을 넘어도 그대로 올린다 (`0.9.0` 다음은 `0.10.0`).
- **네 번째 자리가 세 번째보다 우선한다.** 내용이 아무리 소소해도 방금 나간 버전을 급히 고치는 것이면 네 번째다.
  자리를 고를 때 *무엇을 고쳤나* 보다 *왜 지금 내나* 를 먼저 본다.
- 버전은 세 곳에 있다: `Resources/Info.plist`(CFBundleShortVersionString) · `Sources/AgentNotch/Version.swift` ·
  `Sources/notch-hook/main.swift`(`HookHelper.version`). 다르면 `scripts/build.sh` 가 멈춘다. 손으로 올리지 말고 `release.sh` 를 쓴다.
- `CFBundleVersion` 은 `1` 로 고정이다.

## 릴리스

### 릴리스는 혼자 올리지 않는다

**버전 자리를 정하거나 태그를 붙이기 전에 반드시 사용자에게 묻는다.** 코드가 다 되고 검사를 전부 통과해도 릴리스는 별개다.
"다 됐어요, 어느 자리로 올릴까요?" 까지가 할 일이다. 태그 · GitHub 릴리스 · 업데이트 피드가 한꺼번에 나가고,
누가 하나라도 받아 가면 그 번호는 영영 고정되기 때문이다.

### 절차

```bash
scripts/release.sh 0.2.0
```

1. main 브랜치 · 깨끗한 작업 트리 · 새 태그인지 확인하고, 원격이 앞서 있으면 `pull --rebase`
2. 버전 세 곳을 올리고, `Changelog.swift` 의 그 버전 항목에 오늘 날짜를 찍는다 (항목이 없으면 멈춘다)
3. 정식판을 빌드해서 `--version` 과 `notch-hook --version` 이 맞는지 확인, `docs/changelog.json` 다시 뽑기
4. 커밋 `🔖 v<버전>` → 주석 태그 → 푸시
5. 태그 tarball 의 sha256 을 구해 `Formula/agent-notch.rb` 의 url · sha256 갱신, 지난 bottle 블록 삭제, `ruby -c` → 커밋 `📦 formula를 v<버전> 로 갱신` → 푸시
6. `gh release create` (제목 `AgentNotch <버전>`). 릴리스가 나가면 `.github/workflows/bottle.yml` 이 macOS 15 · 26 bottle 을 만들어 붙이고 formula 에 `📦 bottle 추가` 커밋을 올린다

- 중간에 멈추면(실패 · Ctrl+C) 커밋 전의 버전 · 변경 내역 변경을 되돌린다. 태그를 올린 뒤에 멈췄으면 formula 만 손으로 갱신하면 된다.
- `.github/workflows/build.yml` 은 태그 · PR 마다 macOS 15 · 26 에서 빌드, 명령줄 통로, `docs/changelog.json` 일치, 테스트를 확인한다.
  태그를 민 뒤에 도는 것이라 이미 나간 릴리스를 막지는 못한다. 깨졌으면 네 번째 자리로 바로 다시 낸다.

## 변경 내역

**무언가를 만들거나 고칠 때마다** `Sources/AgentNotch/Changelog.swift` 맨 위 항목(날짜가 `nil` 인 것)에 한 줄 더한다.
아직 안 나간 변경은 거기에 쌓아 두고, 날짜는 릴리스할 때 `release.sh` 가 찍는다. 새 버전 항목은 `date: nil` 로 만든다.

설정 "버전" 탭이 이걸 그대로 보여주고, 다른 버전의 앱은 `docs/changelog.json` 을 받아 본다. **JSON 은 손으로 고치지 않는다.**

```bash
source scripts/lib.sh && dump_changelog      # 빌드한 뒤 docs/changelog.json 을 다시 뽑는다
```

직접 `--dump-changelog` 를 부르면 빌드를 건너뛴 옛 바이너리가 방금 추가한 항목을 빠뜨린다. CI 가 소스와 다르면 실패시킨다.

### 문구

**기능 단위로 한 줄씩, 명사형으로 끝맺는다.** 무엇이 늘었는지 · 고쳐졌는지가 한눈에 들어와야 한다. 동작을 서술하지 않는다.

| | |
|---|---|
| ✅ | `외부 모니터 표시 설정 추가 (메뉴바 안 / 메뉴바 아래 / 표시 안 함)` |
| ✅ | `권한 카드를 접으면 주황 점이 사라지던 문제 수정` |
| ❌ | `새 버전이 나오면 펼친 아일랜드 헤더에 표시가 뜬다` ← 동작 서술 |
| ❌ | `하루에 한 번 새 버전을 확인한다. 버전 탭에서 끌 수 있다` ← 두 문장 |

- 끝맺음은 **추가 / 수정 / 변경 / 개선 / 지원 / 제거** 중에서 고른다.
- 덧붙일 게 있으면 괄호로 짧게: `(하루 1회, 끄기 가능)`.
- 내부 구조나 이유는 커밋 메시지 · 코드 주석에 남기고 여기에는 쓰지 않는다.

### 커밋 단위로 적지 않는다

커밋은 우리가 일한 단위이고, 변경 내역은 사용자가 겪는 단위다. 여러 커밋이어도 사용자에게 한 가지 변화면 한 줄로 적는다.
**줄마다 같은 말로 시작하고 있으면 합칠 때다.** 나눌 때는 "사용자가 따로 겪는가" 를 본다.

### 묶음과 갈래

- 기능 단위로 묶는다(`ChangelogGroup`). 묶음 이름은 화면 · 메뉴 이름을 그대로 쓴다 — `권한 · 질문`, `표시`, `업데이트`.
- 묶음마다 `icon` 에 SF Symbol 이름을 단다 (`hand.raised.fill`, `display` 등). 버전 탭이 제목 앞에 그리고, 줄들은 그 아래 왼쪽 세로선으로 묶인다.
  macOS 14 에 있는 기호만 쓴다. 아이콘이 없는 예전 내역은 점으로 보인다.
- 줄은 기능 위주로 짧게, 묶음마다 2–3줄. 세부 동작 · 조건은 사용 문서(`docs/usage.md`)에 둔다.
- 설정 탭 이야기면 `tab` 에 그 탭(`general` / `display` / `version`)을 적는다. 탭에 없는 것(아일랜드 · 메뉴)은 비워 둔다.
- 항목마다 갈래를 단다: `.new` 신규 · `.improve` 개선 · `.change` 변경 · `.fix` 수정 · `.remove` 제거.
- **새로 생긴 기능 묶음(`isNew: true`)** 은 무엇이 있는지만 적고(`.new`), 줄 끝에 `추가` 를 붙이지 않는다.
  그 기능을 만들면서 고친 오류 · 바꾼 동작은 나간 적이 없으니 적지 않는다.
- 평평한 `notes` 는 `groups` 에서 만들어지므로 손으로 적지 않는다. **이미 나간 버전은 나중에 고치지 않는다.**

## 커밋

gitmoji 하나 + 한국어 제목 한 줄. 필요하면 본문에 짧은 목록.

| 이모지 | 쓰임 |
|---|---|
| ✨ | 기능 |
| 🐛 | 수정 |
| 🎨 | 모양 · 구조 |
| 📝 | 문서 |
| 🔧 | 설정 · 스크립트 |
| 👷 | CI |
| ✅ | 테스트 |
| 🔖 | 버전 (release.sh) |
| 📦 | formula (release.sh · bottle 워크플로) |

## 공개 저장소 주의

- 비밀 정보(API 키, 토큰, 인증서, 개인 경로)를 코드 · 픽스처 · 문서 · 로그에 넣지 않는다. 예시 경로는 `/Users/dev/...`.
- 커밋 전에 확인: `git ls-files -mo --exclude-standard | xargs grep -nIE "/Users/[a-z]+/" | grep -v /Users/dev/`
