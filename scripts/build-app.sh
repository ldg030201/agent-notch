#!/usr/bin/env bash
# AgentNotch.app 번들을 만든다 (Xcode 없이 Command Line Tools 만으로).
#
# 사용법: scripts/build-app.sh [--debug] [--version X] [--output DIR]
#   --debug        디버그 빌드 (기본: release)
#   --version X    번들 버전 (기본: git 태그 v* 또는 0.1.0)
#   --output DIR   결과 폴더 (기본: <저장소>/build)
#   SWIFT_BUILD_FLAGS 환경변수: swift build 에 덧붙일 인자 (Homebrew 는 --disable-sandbox)
#
# 마지막 줄에 만든 .app 경로를 출력한다. 진행 로그는 stderr 로 나간다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="release"
VERSION=""
OUTPUT="$ROOT/build"

usage() {
  sed -n '4,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) CONFIG="debug" ;;
    --version)
      [[ $# -ge 2 ]] || die "--version 값이 필요해요"
      VERSION="$2"
      shift
      ;;
    --version=*) VERSION="${1#*=}" ;;
    --output)
      [[ $# -ge 2 ]] || die "--output 값이 필요해요"
      OUTPUT="$2"
      shift
      ;;
    --output=*) OUTPUT="${1#*=}" ;;
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

# 버전: 인자 > git 태그(v1.2.3) > 0.1.0
if [[ -z "$VERSION" ]]; then
  VERSION="$(git -C "$ROOT" describe --tags --match 'v[0-9]*' 2>/dev/null || true)"
  VERSION="${VERSION#v}"
  [[ -n "$VERSION" ]] || VERSION="0.1.0"
fi
[[ "$VERSION" =~ ^[0-9A-Za-z.+-]+$ ]] || die "버전 형식이 올바르지 않아요: $VERSION"
# CFBundleVersion 은 숫자 형식이어야 해서 앞쪽 숫자 부분만 쓴다 (0.1.0-3-gabc1234 → 0.1.0)
BUNDLE_VERSION="$(printf '%s' "$VERSION" | grep -Eo '^[0-9]+(\.[0-9]+){0,2}' || true)"
[[ -n "$BUNDLE_VERSION" ]] || BUNDLE_VERSION="0"

# SWIFT_BUILD_FLAGS 는 공백으로 나눠 여러 인자로 넘긴다
EXTRA_FLAGS=()
if [[ -n "${SWIFT_BUILD_FLAGS:-}" ]]; then
  read -r -a EXTRA_FLAGS <<<"$SWIFT_BUILD_FLAGS"
fi
SWIFT_ARGS=(--package-path "$ROOT" -c "$CONFIG")
# bash 3.2 + set -u 에서 빈 배열을 안전하게 펼치기 위한 형태
SWIFT_ARGS+=(${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"})

echo "==> swift build -c $CONFIG (버전 $VERSION)" >&2
swift build "${SWIFT_ARGS[@]}" >&2
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
for product in AgentNotch notch-hook; do
  [[ -x "$BIN_DIR/$product" ]] || die "빌드 결과에 $product 가 없어요 ($BIN_DIR)"
done

mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
APP="$OUTPUT/AgentNotch.app"
CONTENTS="$APP/Contents"

echo "==> 번들 조립: $APP" >&2
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIR/AgentNotch" "$CONTENTS/MacOS/AgentNotch"
cp "$BIN_DIR/notch-hook" "$CONTENTS/MacOS/notch-hook"
chmod 755 "$CONTENTS/MacOS/AgentNotch" "$CONTENTS/MacOS/notch-hook"

sed -e "s/__SHORT_VERSION__/$VERSION/g" -e "s/__BUNDLE_VERSION__/$BUNDLE_VERSION/g" \
  "$ROOT/Resources/Info.plist" >"$CONTENTS/Info.plist"
plutil -lint -s "$CONTENTS/Info.plist" >&2 || die "Info.plist 형식 오류"
printf 'APPL????' >"$CONTENTS/PkgInfo"

# Info.plist 외의 리소스(아이콘 등)는 그대로 복사
for item in "$ROOT/Resources"/*; do
  [[ -e "$item" ]] || continue
  [[ "$(basename "$item")" == "Info.plist" ]] && continue
  cp -R "$item" "$CONTENTS/Resources/"
done

# 애플 개발자 인증서 없이 ad-hoc 서명. 헬퍼(중첩 코드)를 먼저 서명해야 앱 서명이 유효하다.
echo "==> ad-hoc 서명" >&2
codesign --force --sign - --timestamp=none --identifier dev.agentnotch.notch-hook "$CONTENTS/MacOS/notch-hook" >&2
codesign --force --sign - --timestamp=none "$APP" >&2
codesign --verify --strict "$APP" >&2 || die "서명 검증 실패"

echo "$APP"
