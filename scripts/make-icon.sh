#!/usr/bin/env bash
# 앱 아이콘(Resources/AppIcon.icns)과 README 용 그림(docs/images/icon.png)을 다시 만든다.
# 그림 자체는 scripts/AppIcon.swift 에 있다. 아이콘은 자주 바뀌지 않으므로 결과물을 커밋해 두고
# build.sh 는 Resources/ 를 복사만 한다 (Homebrew 빌드에 iconutil · 렌더링을 끼우지 않는다).
#
# 사용법: scripts/make-icon.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

swiftc -O -o "$WORK/app-icon" "$ROOT/scripts/AppIcon.swift"
"$WORK/app-icon" "$WORK"

# @2x 는 한 단계 큰 그림을 그대로 쓴다. 확대가 아니라 그 크기로 새로 그린 것이다
cp "$WORK/16.png"   "$ICONSET/icon_16x16.png"
cp "$WORK/32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$WORK/32.png"   "$ICONSET/icon_32x32.png"
cp "$WORK/64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$WORK/128.png"  "$ICONSET/icon_128x128.png"
cp "$WORK/256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$WORK/256.png"  "$ICONSET/icon_256x256.png"
cp "$WORK/512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$WORK/512.png"  "$ICONSET/icon_512x512.png"
cp "$WORK/1024.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
cp "$WORK/512.png" "$ROOT/docs/images/icon.png"
echo "$ROOT/Resources/AppIcon.icns"
echo "$ROOT/docs/images/icon.png"
