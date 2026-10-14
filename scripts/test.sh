#!/usr/bin/env bash
# swift test 래퍼. Command Line Tools 만 있으면 SwiftPM 이 Swift Testing 매크로 플러그인 경로를
# 찾지 못해서(@Test: "plugin for module 'TestingMacros' not found") 경로를 직접 넘긴다.
#
# 사용법: scripts/test.sh [swift test 인자...]   예) scripts/test.sh --filter SessionStoreTests
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ARGS=(--package-path "$ROOT")

DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null || true)"
PLUGIN_DIR="$DEVELOPER_DIR_PATH/usr/lib/swift/host/plugins/testing"
if [[ "$DEVELOPER_DIR_PATH" == *CommandLineTools* && -d "$PLUGIN_DIR" ]]; then
  ARGS+=(-Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR")
fi

exec swift test "${ARGS[@]}" "$@"
