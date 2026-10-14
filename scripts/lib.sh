#!/usr/bin/env bash
# scripts/*.sh (build · dev · run · stop · release · test · simulate-events · make-signing-cert) 가 함께 쓰는 값과 함수.
#
# 앱 이름 · 번들 경로 · 빌드 호출을 스크립트마다 따로 계산하면, 이름을 바꿀 때 한 곳을 놓쳐서
# 없는 번들을 열거나 엉뚱한 앱을 끄게 된다. 여기 한 곳만 고친다.
#
# 쓰는 쪽: source "$(dirname "$0")/lib.sh"
# 셸에서 직접: source scripts/lib.sh && dump_changelog

# 저장소 뿌리 (Package.swift 가 있는 곳)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# VARIANT=test 로 부르면 번들 이름 · ID 가 다른 별개의 앱(AgentNotch-Test)이 나온다.
# 설정(UserDefaults)을 정식판과 나눠 쓰고, 새 버전 확인 · 자체 업데이트를 하지 않는다.
VARIANT="${VARIANT:-release}"
RELEASE_APP_NAME="AgentNotch"
TEST_APP_NAME="AgentNotch-Test"
if [[ "$VARIANT" == "test" ]]; then
  APP_NAME="$TEST_APP_NAME"
  BUNDLE_ID="com.ldg.agent-notch-test"
else
  APP_NAME="$RELEASE_APP_NAME"
  BUNDLE_ID="com.ldg.agent-notch"
fi

APP="$ROOT/build/$APP_NAME.app"
# 실행 파일 이름은 두 변형 모두 AgentNotch (번들 이름만 다르다)
BIN="$APP/Contents/MacOS/AgentNotch"
HELPER="$APP/Contents/MacOS/notch-hook"

CONFIG="${CONFIG:-release}"

# 코드 서명 신원.
#
# 손쉬운 사용 · 자동화(iTerm2 AppleScript) 권한은 **서명 신원**에 묶인다. ad-hoc(`-`)에는 신원이 없어서
# macOS 가 바이너리 해시로 앱을 알아보고, 해시는 빌드할 때마다 바뀐다 → 업데이트마다 권한을 다시 묻는다.
# 자체 서명 인증서(scripts/make-signing-cert.sh 로 한 번 만듦)가 있으면 그걸 쓰고, 없으면 ad-hoc.
SIGN_CERT_NAME="${SIGN_CERT_NAME:-AgentNotch Local Signing}"

sign_identity() {
  if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$SIGN_CERT_NAME\""; then
    printf '%s' "$SIGN_CERT_NAME"
  else
    printf '%s' '-'
  fi
}

# Package.swift 의 swift-tools-version. 올리면 여기도 같이 맞춘다.
MIN_SWIFT="6.0"

# 툴체인이 낡았으면 SwiftPM 의 알아보기 힘든 오류 대신 할 일을 알려준다.
# **Xcode 를 요구하지 않는다.** Command Line Tools 만으로 빌드된다 (formula 에 depends_on xcode 를 넣지 않는 이유).
require_swift() {
  local have
  have="$(swift --version 2>/dev/null | sed -n 's/.*Apple Swift version \([0-9][0-9.]*\).*/\1/p' | head -1)"
  if [[ -z "$have" ]]; then
    echo "Swift 를 찾지 못했어요. Command Line Tools 를 설치하세요:  xcode-select --install" >&2
    exit 1
  fi
  if [[ "$(printf '%s\n%s\n' "$MIN_SWIFT" "$have" | sort -V | head -1)" != "$MIN_SWIFT" ]]; then
    echo "Swift $have 는 너무 오래됐어요 — $MIN_SWIFT 이상이 필요해요." >&2
    echo "  Command Line Tools 만 쓰면:  softwareupdate --list 로 업데이트하거나 xcode-select --install" >&2
    exit 1
  fi
}

# Homebrew 처럼 이미 샌드박스 안에서 도는 환경에서는 SwiftPM 의 자체 샌드박스가 중첩되어 실패한다.
# 그럴 때 SWIFT_BUILD_FLAGS="--disable-sandbox" 로 넘긴다. 단어 분리를 의도해 따옴표를 씌우지 않는다.
swift_build() {
  require_swift
  # shellcheck disable=SC2086
  swift build -c "$CONFIG" --package-path "$ROOT" ${SWIFT_BUILD_FLAGS:-} "$@"
}

# 방금 빌드한 산출물 폴더
swift_bin_dir() {
  swift_build --show-bin-path
}

# ── 버전 ─────────────────────────────────────────────────────────
# 버전은 세 곳에 있다. 어긋난 채로 나가면 `agent-notch --version` 이 태그와 다른 값을 낸다.
plist_version() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist"
}

source_version() {
  sed -n 's/^let agentNotchVersion = "\(.*\)"$/\1/p' "$ROOT/Sources/AgentNotch/Version.swift"
}

hook_version() {
  sed -n 's/^    static let version = "\(.*\)"$/\1/p' "$ROOT/Sources/notch-hook/main.swift"
}

check_versions() {
  local plist source hook
  plist="$(plist_version)"
  source="$(source_version)"
  hook="$(hook_version)"
  if [[ -z "$plist" || "$plist" != "$source" || "$plist" != "$hook" ]]; then
    echo "버전 불일치: Info.plist=$plist, Version.swift=$source, notch-hook=$hook" >&2
    return 1
  fi
}

# ── 변경 내역 ────────────────────────────────────────────────────
# 앱이 원격으로 받아 보는 docs/changelog.json 을 Changelog.swift 에서 다시 뽑는다.
# **반드시 먼저 빌드한다** — 옛 바이너리로 뽑으면 방금 추가한 항목이 빠진다.
dump_changelog() {
  swift_build >&2
  "$(swift_bin_dir)/AgentNotch" --dump-changelog "$ROOT/docs/changelog.json"
}

# ── 실행 · 종료 (run.sh · stop.sh · dev.sh 공용) ─────────────────────────

# 이 판(정식/테스트)의 앱 프로세스를 찾는 패턴. build/ 든 /Applications 든 같은 판이면 잡는다
# (두 사본은 소켓을 같이 써서 함께 뜰 수 없다). notch-hook 헬퍼는 잡지 않는다.
app_process_pattern() {
  printf '/%s\\.app/Contents/MacOS/AgentNotch( |$)' "$APP_NAME"
}

# 실행 중인 앱을 끈다. SIGTERM 으로 정상 종료(소켓 정리)를 5초 기다리고, 그래도 남으면 강제로 끈다.
# 끈 게 있으면 0, 원래 꺼져 있었으면 1.
stop_running_app() {
  local pattern
  pattern="$(app_process_pattern)"
  pgrep -f "$pattern" >/dev/null 2>&1 || return 1
  pkill -TERM -f "$pattern" 2>/dev/null || true
  for _ in $(seq 1 50); do
    pgrep -f "$pattern" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  pkill -9 -f "$pattern" 2>/dev/null || true
  sleep 0.2
  return 0
}

# 앱을 띄운다. 인자는 앱에 그대로 넘기고, AGENT_NOTCH_SOCKET 이 있으면 환경변수로 전달한다.
launch_app() {
  local open_args=(-n "$APP")
  if [[ -n "${AGENT_NOTCH_SOCKET:-}" ]]; then
    open_args+=(--env "AGENT_NOTCH_SOCKET=$AGENT_NOTCH_SOCKET")
  fi
  if [[ $# -gt 0 ]]; then
    open_args+=(--args "$@")
  fi
  open "${open_args[@]}"
}
