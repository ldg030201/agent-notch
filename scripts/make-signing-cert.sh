#!/usr/bin/env bash
# 로컬 코드 서명 인증서("AgentNotch Local Signing")를 로그인 키체인에 만든다. **한 번만** 실행하면 된다.
#
# 왜 필요한가:
#   손쉬운 사용 · 자동화(iTerm2 제어) 권한은 코드 서명 신원에 묶인다. ad-hoc 서명(`codesign --sign -`)에는
#   신원이 없어서 macOS 가 바이너리 해시로 앱을 알아보고, 해시는 다시 빌드할 때마다 바뀐다.
#   그래서 빌드 · 업데이트마다 허용해 둔 권한이 풀린다. 자체 서명 인증서를 두면 신원이 고정된다.
#
#   인증서와 개인키는 이 맥의 키체인 밖으로 나가지 않는다. Homebrew 사용자는 각자 맥에서 빌드하므로
#   (bottle 은 CI 에서 ad-hoc) 배포에는 영향이 없다. **개인키를 저장소 · CI 에 두지 않는다** — 새면 그 키로
#   서명한 앱을 macOS 가 같은 앱으로 보고 허용해 둔 권한을 물려받는다.
#
# 지우려면:
#   security delete-certificate -c "AgentNotch Local Signing" ~/Library/Keychains/login.keychain-db
#   (지우면 scripts/build.sh 가 다시 ad-hoc 서명으로 떨어진다)
set -euo pipefail
umask 077

source "$(dirname "$0")/lib.sh"

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# macOS 기본 LibreSSL 을 쓴다. Homebrew 의 OpenSSL 3 가 만든 p12 는 security 가 못 읽는 경우가 있다.
OPENSSL=/usr/bin/openssl

# codesign 이 개인키를 꺼내 쓸 수 있게 키 접근 목록에 넣는다.
# 이 단계가 없으면 codesign 이 errSecInternalComponent 로 실패한다.
# 묻는 암호는 **로그인 암호**다. 화면에 보이지 않고, 이 스크립트는 그 값을 저장하지 않는다 (security 가 직접 받는다).
allow_codesign() {
  echo "codesign 이 키를 쓸 수 있게 여는 중… (로그인 암호를 물어봐요. 입력해도 화면에는 안 보여요)"
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -l "$SIGN_CERT_NAME" "$KEYCHAIN" >/dev/null
}

if security find-certificate -c "$SIGN_CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "인증서가 이미 있어요: $SIGN_CERT_NAME"
  # 접근 목록만 어긋난 상태일 수 있다. 그것만 다시 잡는다.
  allow_codesign
  echo "지금 서명 신원: $(sign_identity)"
  exit 0
fi

# 개인키는 이 임시 폴더 안에만 둔다. 어떻게 끝나든 지운다.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# p12 를 키체인에 넣을 때만 쓰는 일회용 암호. 파일과 함께 바로 버린다.
P12_PASS="$("$OPENSSL" rand -hex 16)"
export AGENT_NOTCH_P12_PASS="$P12_PASS"

echo "인증서를 만드는 중…"
"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$SIGN_CERT_NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  2>/dev/null

"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/bundle.p12" -name "$SIGN_CERT_NAME" -passout env:AGENT_NOTCH_P12_PASS
unset AGENT_NOTCH_P12_PASS

# -T 로 codesign 에만 미리 접근을 연다. `-A`(모든 앱 허용)는 쓰지 않는다 — 신원을 쥔 키를 아무 앱이나 쓰게 된다.
echo "키체인에 넣는 중… (암호를 물으면 로그인 암호를 넣어 주세요)"
security import "$WORK/bundle.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign
P12_PASS=""

# 자체 서명 루트라 그대로 두면 codesign 이 신뢰 사슬을 못 만든다. 이 인증서만 **코드 서명 용도로** 신뢰한다.
echo "코드 서명 용도로 신뢰 설정 중… (암호를 한 번 더 물을 수 있어요)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

allow_codesign

echo
echo "끝났어요. 지금 서명 신원: $(sign_identity)"
echo "이제 다시 빌드해도 신원이 그대로예요."
echo "확인: VARIANT=test scripts/build.sh && codesign -dv --verbose=4 build/AgentNotch-Test.app 2>&1 | grep Authority"
