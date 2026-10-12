#!/usr/bin/env bash
# AgentNotch.app 번들을 만든다 (Xcode 없이 Command Line Tools + SwiftPM 만 사용).
#
#   scripts/build.sh                 # build/AgentNotch.app       (정식판, 릴리스·Homebrew 용)
#   VARIANT=test scripts/build.sh    # build/AgentNotch-Test.app  (개발 확인용)
#
# 환경변수
#   VARIANT            release(기본) | test
#   CONFIG             release(기본) | debug
#   SWIFT_BUILD_FLAGS  swift build 에 덧붙일 인자 (Homebrew 는 --disable-sandbox)
#   SIGN_CERT_NAME     서명 인증서 이름 (기본 "AgentNotch Local Signing", 없으면 ad-hoc)
#
# 진행 로그는 stderr, 마지막에 만든 .app 경로를 stdout 으로 출력한다.
set -euo pipefail

source "$(dirname "$0")/lib.sh"

# 버전 세 곳(Info.plist · Version.swift · notch-hook)이 같아야 한다
check_versions
VERSION="$(plist_version)"

echo "==> swift build -c $CONFIG ($APP_NAME $VERSION)" >&2
swift_build >&2
BIN_DIR="$(swift_bin_dir)"
for product in AgentNotch notch-hook; do
  [[ -x "$BIN_DIR/$product" ]] || { echo "빌드 결과에 $product 가 없어요 ($BIN_DIR)" >&2; exit 1; }
done

echo "==> 번들 조립: $APP" >&2
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AgentNotch" "$APP/Contents/MacOS/AgentNotch"
cp "$BIN_DIR/notch-hook" "$APP/Contents/MacOS/notch-hook"
chmod 755 "$APP/Contents/MacOS/AgentNotch" "$APP/Contents/MacOS/notch-hook"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# 변형마다 이름과 번들 ID 만 바꾼다. 실행 파일 이름(AgentNotch)은 그대로다.
for key_value in \
  "CFBundleName:$APP_NAME" \
  "CFBundleDisplayName:$APP_NAME" \
  "CFBundleIdentifier:$BUNDLE_ID"; do
  /usr/libexec/PlistBuddy -c "Set :${key_value%%:*} ${key_value#*:}" "$APP/Contents/Info.plist"
done
plutil -lint -s "$APP/Contents/Info.plist" >&2 || { echo "Info.plist 형식 오류" >&2; exit 1; }
printf 'APPL????' >"$APP/Contents/PkgInfo"

# Info.plist 외의 리소스(아이콘 등)는 그대로 복사
for item in "$ROOT/Resources"/*; do
  [[ -e "$item" ]] || continue
  [[ "$(basename "$item")" == "Info.plist" ]] && continue
  cp -R "$item" "$APP/Contents/Resources/"
done

# 서명. 헬퍼(중첩 코드)를 먼저 서명해야 앱 서명이 유효하다.
#
# 자체 서명 인증서가 있으면 그걸로, 없거나 실패하면 ad-hoc 으로 떨어진다.
# **서명 때문에 빌드가 실패하지는 않는다** — 키체인이 잠겨 있거나 접근을 거절해도 앱은 나와야 한다.
sign_with() {
  local identity="$1"
  codesign --force --sign "$identity" --timestamp=none \
    --identifier "$BUNDLE_ID.notch-hook" "$APP/Contents/MacOS/notch-hook" 2>/dev/null \
    && codesign --force --sign "$identity" --timestamp=none "$APP" 2>/dev/null
}

IDENTITY="$(sign_identity)"
if sign_with "$IDENTITY"; then
  if [[ "$IDENTITY" == "-" ]]; then
    echo "==> ad-hoc 서명" >&2
  else
    echo "==> '$IDENTITY' 로 서명" >&2
  fi
else
  if [[ "$IDENTITY" != "-" ]]; then
    echo "'$IDENTITY' 로 서명하지 못해 ad-hoc 으로 서명해요." >&2
    echo "키체인 창이 뜨면 '항상 허용' 을 눌러야 다음 빌드부터 묻지 않아요." >&2
  fi
  if ! sign_with "-"; then
    echo "경고: ad-hoc 서명도 실패했어요. 앱은 서명 없이 만들어졌어요." >&2
  fi
fi

echo "$APP"
