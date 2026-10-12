#!/usr/bin/env bash
# 실행 중인 AgentNotch 에 가짜 훅 이벤트를 흘려 보낸다 (Fixtures/events/*.json → notch-hook → 소켓).
# ~/.claude 는 건드리지 않는다. 픽스처는 모두 가짜 데이터다.
#
# 사용법: scripts/simulate-events.sh [--fast] [--keep] [--reply-timeout SEC] [--helper PATH]
#   --fast              이벤트 사이 대기를 줄인다
#   --keep              마지막 SessionEnd 를 보내지 않는다 (세션을 노치에 남김)
#   --reply-timeout SEC 권한 요청에 대한 노치 응답을 기다리는 최대 시간 (기본 60)
#   --helper PATH       notch-hook 경로 (기본: build/AgentNotch-Test.app → build/AgentNotch.app → .build/debug → .build/release)
#   AGENT_NOTCH_SOCKET  소켓 경로를 바꿀 때 (앱도 같은 값으로 실행해야 함)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/Fixtures/events"
FAST=0
KEEP=0
REPLY_TIMEOUT=60
HELPER="${NOTCH_HOOK:-}"

usage() {
  sed -n '5,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fast) FAST=1 ;;
    --keep) KEEP=1 ;;
    --reply-timeout)
      [[ $# -ge 2 ]] || die "--reply-timeout 값이 필요해요"
      REPLY_TIMEOUT="$2"
      shift
      ;;
    --helper)
      [[ $# -ge 2 ]] || die "--helper 값이 필요해요"
      HELPER="$2"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "알 수 없는 인자: $1"
      ;;
  esac
  shift
done

if [[ -z "$HELPER" ]]; then
  for candidate in \
    "$ROOT/build/AgentNotch-Test.app/Contents/MacOS/notch-hook" \
    "$ROOT/build/AgentNotch.app/Contents/MacOS/notch-hook" \
    "$ROOT/.build/debug/notch-hook" \
    "$ROOT/.build/release/notch-hook"; do
    if [[ -x "$candidate" ]]; then
      HELPER="$candidate"
      break
    fi
  done
fi
[[ -n "$HELPER" && -x "$HELPER" ]] || die "notch-hook 을 찾지 못했어요. VARIANT=test scripts/build.sh 또는 swift build 를 먼저 실행하세요."

if ! "$HELPER" --ping; then
  die "AgentNotch 가 실행 중이 아니에요 (소켓: ${AGENT_NOTCH_SOCKET:-기본 경로})"
fi

event_name() {
  sed -n 's/.*"hook_event_name": *"\([^"]*\)".*/\1/p' "$1" | head -n 1
}

pause() {
  if [[ "$FAST" == 1 ]]; then
    sleep 0.2
  else
    sleep "$1"
  fi
}

# 파일 하나를 훅처럼 보낸다: send <픽스처> <다음 이벤트까지 대기(초)>
send() {
  local file="$FIXTURES/$1"
  [[ -f "$file" ]] || die "픽스처가 없어요: $1"
  local event
  event="$(event_name "$file")"
  echo "▶ $1 ($event)"
  "$HELPER" "$event" <"$file"
  pause "$2"
}

# 권한 요청은 노치에서 고를 때까지 기다리고 결과를 보여준다
send_permission() {
  local file="$FIXTURES/$1"
  [[ -f "$file" ]] || die "픽스처가 없어요: $1"
  echo "▶ $1 (PermissionRequest) — 노치에서 허용/거부를 골라 보세요 (최대 ${REPLY_TIMEOUT}초)"
  local output
  output="$("$HELPER" PermissionRequest --reply-timeout "$REPLY_TIMEOUT" <"$file")"
  if [[ -n "$output" ]]; then
    echo "  결정: $output"
  else
    echo "  결정 없음 → Claude Code 기본 권한 프롬프트로 넘어가는 경우"
  fi
  pause 1
}

send 01-session-start.json 1
send 02-user-prompt-submit.json 1.2
send 03-pre-tool-use-read.json 1.5
send 04-post-tool-use-read.json 0.8
send 05-pre-tool-use-edit.json 1.2
send 06-post-tool-use-edit.json 3
send 07-message-display-1.json 1
send 08-message-display-2.json 1.5
send 09-notification.json 3
send 10-pre-tool-use-bash.json 1
send_permission 11-permission-request-bash.json
send 12-post-tool-use-bash.json 1.5
send 13-stop-failure.json 5
# 다시 시도한 턴이 정상 완료되는 흐름
send 02-user-prompt-submit.json 2
send 14-stop.json 5
if [[ "$KEEP" == 0 ]]; then
  send 15-session-end.json 0
fi
echo "완료"
