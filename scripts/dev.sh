#!/usr/bin/env bash
# 테스트판(AgentNotch-Test)을 빌드하고 다시 띄운다. brew 로 설치한 정식판과 설정을 나눠 쓴다.
#
#   scripts/dev.sh                  한 번 빌드하고 다시 띄우기
#   scripts/dev.sh watch            소스가 바뀔 때마다 반복 (fswatch 필요, Ctrl+C 로 종료 — 앱은 계속 떠 있음)
#   scripts/dev.sh --demo           나머지 인자는 앱에 그대로 넘긴다 (watch 뒤에 붙여도 된다)
#
#   AGENT_NOTCH_SOCKET=/tmp/an-dev.sock scripts/dev.sh
#     소켓을 바꿔 띄운다. 정식판과 기본 소켓을 같이 쓰므로, 정식판을 켜 둔 채로 개발하려면 소켓을 나눈다
#     (그때 이벤트는 scripts/simulate-events.sh 로 같은 소켓에 흘린다).
set -uo pipefail

export VARIANT="${VARIANT:-test}"
source "$(dirname "$0")/lib.sh"

MODE="${1:-once}"
if [[ "$MODE" == "once" || "$MODE" == "watch" ]]; then
  shift || true
else
  MODE="once"
fi
APP_ARGS=("$@")
LOG="$ROOT/build/dev-build.log"
mkdir -p "$ROOT/build"

stop_app() {
  pkill -f "$APP_NAME.app/Contents/MacOS/AgentNotch" 2>/dev/null || return 0
  # 소켓 파일을 정리하고 끝날 때까지 잠깐 기다린다 (바로 띄우면 "이미 실행 중" 으로 끝난다)
  for _ in $(seq 1 30); do
    pgrep -f "$APP_NAME.app/Contents/MacOS/AgentNotch" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  pkill -9 -f "$APP_NAME.app/Contents/MacOS/AgentNotch" 2>/dev/null || true
}

build() {
  if "$ROOT/scripts/build.sh" >"$LOG" 2>&1; then
    return 0
  fi
  printf '\033[31m✗ 빌드 실패\033[0m (%s)\n' "$LOG"
  if grep -qE "error:" "$LOG"; then
    grep -E "error:" "$LOG" | head -20
  else
    tail -20 "$LOG"
  fi
  return 1
}

launch() {
  local open_args=(-n "$APP")
  if [[ -n "${AGENT_NOTCH_SOCKET:-}" ]]; then
    open_args+=(--env "AGENT_NOTCH_SOCKET=$AGENT_NOTCH_SOCKET")
  fi
  if [[ ${#APP_ARGS[@]} -gt 0 ]]; then
    open_args+=(--args "${APP_ARGS[@]}")
  fi
  open "${open_args[@]}"
}

cycle() {
  printf '\n\033[2m──\033[0m %s \033[2m빌드…\033[0m\n' "$(date +%H:%M:%S)"
  build || return 1
  stop_app
  launch
  printf '\033[32m✓\033[0m %s 실행 중\n' "$APP_NAME"
}

cycle
STATUS=$?
[[ "$MODE" == "watch" ]] || exit "$STATUS"

if ! command -v fswatch >/dev/null 2>&1; then
  printf '\033[31mfswatch 가 없어요.\033[0m brew install fswatch 후 다시 실행하세요.\n' >&2
  exit 1
fi

printf '\n감시 중: Sources/ Resources/ Package.swift  \033[2m(Ctrl+C 로 종료 — 앱은 계속 떠 있음)\033[0m\n'
# -o: 변경 묶음마다 이벤트 1개, -l: 연속 저장을 한 번으로 합친다
fswatch -o -l 0.4 "$ROOT/Sources" "$ROOT/Resources" "$ROOT/Package.swift" | while read -r _; do
  cycle
done
