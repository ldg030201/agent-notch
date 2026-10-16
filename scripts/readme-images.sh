#!/usr/bin/env bash
# README 스크린샷(docs/images/*.png)을 다시 만든다.
# 실제 아일랜드 뷰를 가짜 데이터로 그려(화면 기록 권한 불필요) 아일랜드 둘레만 자른다 (`--render-island … --crop`).
# 화면이 바뀌면 이 스크립트로 다시 뽑고 README 와 함께 커밋한다.
#
# 사용법: scripts/readme-images.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# README 에 쓰는 장면 (파일 이름 = 장면 이름)
SCENES=(working menubar-working expanded permission-desktop question peek done)

swift_build >&2
BIN_DIR="$(swift_bin_dir)"
OUT="$ROOT/docs/images"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

for scene in "${SCENES[@]}"; do
  # 메뉴바 알약 장면은 --style 과 관계없이 노치 없는 화면으로 그리지만 파일 이름은 <장면>-notch.png 다
  "$BIN_DIR/AgentNotch" --render-island "$scene" "$TMP" --style notch --crop >/dev/null
  mv "$TMP/$scene-notch.png" "$OUT/$scene.png"
  echo "$OUT/$scene.png"
done
