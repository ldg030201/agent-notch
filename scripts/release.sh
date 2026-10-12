#!/usr/bin/env bash
# 새 버전을 내보낸다. **버전 자리를 정하거나 태그를 붙이기 전에 반드시 사용자에게 묻는다** (docs/development.md).
#
#   scripts/release.sh 0.2.0        기능 추가 · 변경
#   scripts/release.sh 0.1.1        오류 수정 · 소소한 변경
#   scripts/release.sh 0.1.0.1      방금 나간 버전의 긴급 수정
#
# 하는 일:
#   1. main 브랜치 · 깨끗한 작업 트리 · 새 태그인지 확인, 원격이 앞서 있으면 rebase
#   2. 버전 세 곳(Info.plist · Version.swift · notch-hook)을 올리고, 변경 내역에 오늘 날짜를 찍고, 빌드해서 검증
#   3. docs/changelog.json 다시 뽑기 → 커밋 "🔖 v<버전>" → 태그 → 푸시
#   4. 그 태그의 tarball 을 받아 sha256 계산
#   5. Formula/agent-notch.rb 의 url · sha256 갱신, 지난 bottle 블록 삭제 → 커밋 · 푸시
#   6. gh 가 있으면 GitHub 릴리스 생성 (bottle 워크플로가 이어서 bottle 을 붙인다)
#
# 4번이 3번 뒤에 오는 이유: 태그가 올라가야 GitHub 가 tarball 을 만들고, 그래야 해시를 구할 수 있다.
set -euo pipefail

# 릴리스는 언제나 정식판으로 검증한다
export VARIANT=release
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

VERSION="${1:-}"
# 네 번째 자리는 긴급 수정용이다. 0.2.0 다음 핫픽스는 0.2.0.1.
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "사용법: scripts/release.sh <버전>    예: scripts/release.sh 0.2.0  또는  scripts/release.sh 0.2.0.1" >&2
  exit 1
fi
TAG="v$VERSION"
# sed · grep 정규식 안에서 점을 글자 그대로 쓰기 위해
VERSION_RE="${VERSION//./\\.}"
FORMULA="Formula/agent-notch.rb"
CHANGELOG="Sources/AgentNotch/Changelog.swift"

# 커밋 전에 손대는 파일. 아래 `git add` 와 같은 목록이어야 한다 — 빠뜨린 파일은 중단했을 때 그대로 남고,
# 그걸 모르고 커밋하면 태그도 릴리스도 없는 버전이 업데이트 피드에 나간다.
TOUCHED=(
  Resources/Info.plist
  Sources/AgentNotch/Version.swift
  Sources/notch-hook/main.swift
  "$CHANGELOG"
  docs/changelog.json
)

# 뒷정리는 어떻게 끝나든 돈다 (실패 · exit 1 · Ctrl+C).
BUMPED=0
COMMITTED=0
FORMULA_EDITED=0
FORMULA_COMMITTED=0
TMP=""
cleanup() {
  if [[ "$BUMPED" == "1" && "$COMMITTED" == "0" ]]; then
    git checkout -- "${TOUCHED[@]}" 2>/dev/null || true
    echo "→ 버전 · 변경 내역 변경을 되돌렸어요." >&2
  fi
  if [[ "$FORMULA_EDITED" == "1" && "$FORMULA_COMMITTED" == "0" ]]; then
    git checkout -- "$FORMULA" 2>/dev/null || true
    rm -f "$FORMULA.tmp"
    echo "→ formula 변경을 되돌렸어요. 태그는 이미 올라갔으니 formula 만 손으로 갱신하면 돼요." >&2
  fi
  if [[ -n "$TMP" ]]; then rm -rf "$TMP"; fi
}
trap cleanup EXIT
# 신호로 죽으면 EXIT 트랩이 안 도는 경우가 있어 직접 빠져나간다
trap 'exit 130' INT
trap 'exit 143' TERM

# ── 1. 사전 점검 ────────────────────────────────────────────────
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
  echo "main 에서만 릴리스해요 (지금: $BRANCH)" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "커밋하지 않은 변경이 있어요:" >&2
  git status --short >&2
  exit 1
fi

git fetch --tags --quiet origin
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
  || [[ -n "$(git ls-remote --tags origin "refs/tags/$TAG")" ]]; then
  echo "태그 $TAG 가 이미 있어요." >&2
  exit 1
fi

# 원격이 앞서 있으면 먼저 따라잡는다.
# bottle 워크플로가 릴리스 뒤에 formula 커밋을 main 에 올리므로, 연달아 릴리스하면 여기서 뒤처져 있다.
# 그대로 두면 태그만 올라가고 main 푸시가 거부된다.
git fetch --quiet origin main
if [[ -n "$(git log --oneline HEAD..origin/main)" ]]; then
  echo "▸ 원격이 앞서 있어요 — rebase"
  git pull --rebase --quiet origin main
fi

echo "▸ $TAG 준비"

# ── 2. 버전 올리기 · 날짜 찍기 · 빌드 검증 ─────────────────────
# 변경 내역 항목이 없으면 버전을 건드리기 전에 멈춘다
if ! grep -qE "version: \"$VERSION_RE\", date: " "$CHANGELOG"; then
  echo "변경 내역에 $VERSION 항목이 없어요 — $CHANGELOG 맨 위에 먼저 적어 주세요" >&2
  exit 1
fi

BUMPED=1
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
sed -i '' -E "s/^let agentNotchVersion = \".*\"$/let agentNotchVersion = \"$VERSION\"/" Sources/AgentNotch/Version.swift
sed -i '' -E "s/^(    static let version = )\"[^\"]*\"$/\1\"$VERSION\"/" Sources/notch-hook/main.swift
check_versions

# **날짜를 여기서 찍는다.** 업데이트 확인은 날짜가 있는 항목만 "나간 버전" 으로 센다.
# 비워 둔 채로 내면 태그도 릴리스도 나갔는데 앱에는 새 버전이 없다고 뜬다.
TODAY="$(date +%Y-%m-%d)"
if grep -qE "version: \"$VERSION_RE\", date: nil" "$CHANGELOG"; then
  sed -i '' -E "s/(version: \"$VERSION_RE\", date: )nil/\1\"$TODAY\"/" "$CHANGELOG"
  echo "▸ 변경 내역 날짜 $TODAY"
else
  echo "▸ 변경 내역 날짜는 이미 있어요"
fi

scripts/build.sh >/dev/null
BUILT="$("$BIN" --version | awk '{print $2}')"
if [[ "$BUILT" != "$VERSION" ]]; then
  echo "빌드한 앱 버전이 달라요: $BUILT (기대: $VERSION)" >&2
  exit 1
fi
HOOK_BUILT="$("$HELPER" --version)"
if [[ "$HOOK_BUILT" != "$VERSION" ]]; then
  echo "빌드한 notch-hook 버전이 달라요: $HOOK_BUILT (기대: $VERSION)" >&2
  exit 1
fi
echo "▸ 빌드 확인 ($BUILT)"

# 앱이 원격으로 받아 보는 변경 내역. 태그 전에 갱신해야 옛 버전 앱도 새 버전을 본다.
dump_changelog >/dev/null
echo "▸ docs/changelog.json 갱신"

# ── 3. 커밋 · 태그 · 푸시 ───────────────────────────────────────
git add "${TOUCHED[@]}"
git commit -q -m "🔖 $TAG" -m "- 버전을 $VERSION 으로 올림 (Info.plist · Version.swift · notch-hook)
- 변경 내역에 출시일 $TODAY 기록, docs/changelog.json 다시 뽑음"
COMMITTED=1
git tag -a "$TAG" -m "AgentNotch $VERSION"
git push -q origin main "$TAG"
echo "▸ 태그 푸시"

# ── 4. tarball 해시 ────────────────────────────────────────────
REPO_URL="$(git remote get-url origin)"
REPO_URL="${REPO_URL%.git}"
# SSH 주소는 curl 에 그대로 못 넣는다 (`:` 뒤를 포트로 읽음). HTTPS 로 바꾼다.
REPO_URL="${REPO_URL/#git@github.com:/https://github.com/}"
REPO_URL="${REPO_URL/#ssh:\/\/git@github.com\//https://github.com/}"
TARBALL="$REPO_URL/archive/refs/tags/$TAG.tar.gz"

TMP="$(mktemp -d)"
SHA=""
for attempt in 1 2 3 4 5; do
  if curl -fsSL -o "$TMP/src.tar.gz" "$TARBALL"; then
    SHA="$(shasum -a 256 "$TMP/src.tar.gz" | awk '{print $1}')"
    break
  fi
  echo "  tarball 생성 대기… ($attempt/5)"
  sleep 3
done
if [[ -z "$SHA" ]]; then
  echo "tarball 을 받지 못했어요: $TARBALL" >&2
  echo "태그는 이미 올라갔으니 잠시 뒤 formula 의 url · sha256 만 손으로 갱신하면 돼요." >&2
  exit 1
fi
echo "▸ sha256 ${SHA:0:16}…"

# ── 5. formula 갱신 ────────────────────────────────────────────
FORMULA_EDITED=1
sed -i '' -E "s|^  url \".*\"$|  url \"$TARBALL\"|" "$FORMULA"
sed -i '' -E "s|^  sha256 \".*\"$|  sha256 \"$SHA\"|" "$FORMULA"

# 지난 버전의 bottle 블록을 지운다. 그대로 두면 root_url 과 체크섬이 옛 태그를 가리켜서
# Homebrew 가 받으려다 404 로 설치가 통째로 실패한다. 지우면 bottle 워크플로가 새로 붙일 때까지 소스 빌드로 넘어간다.
awk '
  /^  bottle do$/ { skip = 1 }
  skip && /^  end$/ { skip = 0; next }
  !skip { print }
' "$FORMULA" >"$FORMULA.tmp"
mv "$FORMULA.tmp" "$FORMULA"
ruby -c "$FORMULA" >/dev/null
grep -qF "url \"$TARBALL\"" "$FORMULA" || { echo "formula 의 url 을 바꾸지 못했어요" >&2; exit 1; }
grep -qF "sha256 \"$SHA\"" "$FORMULA" || { echo "formula 의 sha256 을 바꾸지 못했어요" >&2; exit 1; }

git add "$FORMULA"
git commit -q -m "📦 formula를 $TAG 로 갱신"
FORMULA_COMMITTED=1
git push -q origin main
echo "▸ formula 갱신"

# ── 6. GitHub 릴리스 ───────────────────────────────────────────
if command -v gh >/dev/null 2>&1; then
  if gh release create "$TAG" --title "AgentNotch $VERSION" --generate-notes >/dev/null 2>&1; then
    echo "▸ GitHub 릴리스 생성 (bottle 워크플로가 이어서 돌아요)"
  else
    echo "▸ GitHub 릴리스 생성 실패 (직접: gh release create $TAG --title \"AgentNotch $VERSION\" --generate-notes)"
  fi
else
  echo "▸ gh 가 없어 GitHub 릴리스는 건너뜀"
fi

echo
echo "완료: $TAG"
echo "사용자 쪽 업데이트: 앱의 설정 > 버전 > 업데이트, 또는 brew upgrade agent-notch"
