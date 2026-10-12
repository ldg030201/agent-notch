#!/usr/bin/env bash
# 실행 중인 앱을 끈다 (정상 종료로 소켓을 정리하고, 5초 안에 안 꺼지면 강제로 끈다).
#
#   scripts/stop.sh               정식판(AgentNotch)
#   VARIANT=test scripts/stop.sh  테스트판(AgentNotch-Test)
set -euo pipefail
source "$(dirname "$0")/lib.sh"

if stop_running_app; then
  echo "✓ $APP_NAME 종료"
else
  echo "실행 중인 $APP_NAME 이 없어요"
fi
