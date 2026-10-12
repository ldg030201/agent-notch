#!/usr/bin/env bash
# 빌드된 앱을 다시 띄운다 (켜져 있으면 끄고 켠다). 빌드된 앱이 없으면 먼저 빌드한다.
#
#   scripts/run.sh                build/AgentNotch.app 을 다시 띄우기
#   scripts/run.sh --build        새로 빌드한 뒤 다시 띄우기
#   scripts/run.sh --demo         그 밖의 인자는 앱에 그대로 넘긴다
#   VARIANT=test scripts/run.sh   테스트판(AgentNotch-Test)
#
# 끄기만 하려면 scripts/stop.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"

REBUILD=0
APP_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --build) REBUILD=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) APP_ARGS+=("$arg") ;;
  esac
done

if [[ "$REBUILD" == 1 || ! -x "$BIN" ]]; then
  echo "▸ 빌드"
  "$ROOT/scripts/build.sh"
fi

if stop_running_app; then
  echo "▸ 실행 중이던 $APP_NAME 종료"
fi

# bash 3.2 는 set -u 에서 빈 배열을 펼치면 unbound 로 죽는다
launch_app ${APP_ARGS[@]+"${APP_ARGS[@]}"}

# 실제로 떴고 훅 이벤트를 받을 준비가 됐는지 확인 (소켓이 열리기까지 1~2초 걸린다).
# 다른 판이 같은 소켓으로 떠 있으면 새로 띄운 쪽이 "이미 실행 중" 안내 후 꺼진다.
HELPER="$APP/Contents/MacOS/notch-hook"
for _ in $(seq 1 50); do
  if ! pgrep -f "$(app_process_pattern)" >/dev/null 2>&1; then
    sleep 0.1
    continue
  fi
  if "$HELPER" --ping >/dev/null 2>&1; then
    echo "✓ $APP_NAME 실행 중 · 훅 받을 준비됨 ($APP)"
    exit 0
  fi
  sleep 0.1
done
if pgrep -f "$(app_process_pattern)" >/dev/null 2>&1; then
  echo "△ $APP_NAME 은 떴지만 소켓이 아직 안 열렸어요. 잠시 뒤 '$HELPER --ping' 으로 확인하세요." >&2
else
  echo "✗ $APP_NAME 이 뜨지 않았어요. 다른 판(정식/테스트)이 켜져 있지 않은지 확인하세요." >&2
fi
exit 1
