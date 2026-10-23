# AgentNotch Homebrew formula. 저장소 자체가 tap 이라 이 파일은 저장소 뿌리의 Formula/ 에 있어야 한다.
#
# 애플 개발자 계정이 없어 서명 · 공증을 할 수 없으므로, 미리 빌드한 .app 을 내려받는 cask 대신
# 사용자 맥에서 빌드(또는 CI 가 만든 bottle 을 설치)하는 formula 로 배포한다. 이렇게 받은 앱에는
# quarantine 속성이 붙지 않아 Gatekeeper 에 막히지 않는다.
#
# url · sha256 · bottle 블록은 scripts/release.sh 와 .github/workflows/bottle.yml 이 갱신한다. 손으로 고치지 않는다.
class AgentNotch < Formula
  desc "Claude Code · Codex 세션을 맥북 노치에 다이나믹 아일랜드처럼 보여주는 메뉴바 앱"
  homepage "https://github.com/ldg030201/agent-notch"
  url "https://github.com/ldg030201/agent-notch/archive/refs/tags/v1.0.1.tar.gz"
  # 첫 릴리스 전 자리표시자. scripts/release.sh 가 태그를 올린 뒤 tarball 해시로 채운다.
  sha256 "be3f39766c3b8ac2dde7b7c6797fd456f45a8619c93d533235a886ce190c1fb4"
  license "MIT"
  head "https://github.com/ldg030201/agent-notch.git", branch: "main"

  bottle do
    root_url "https://github.com/ldg030201/agent-notch/releases/download/v1.0.1"
    sha256 arm64_tahoe:   "6fca98e0ad9c9696c4f927be3fc5a770e949eaeceae7c6f90735784b0fb78c17"
    sha256 arm64_sequoia: "ef7fc6cd2acc13ea9f85852e15fc6861be7975ef5edea27a56decb3131ab3f90"
  end

  # Xcode 는 필요 없다. Command Line Tools 의 Swift 만으로 빌드된다 (depends_on xcode 를 넣지 않는다).
  depends_on arch: :arm64   # Apple Silicon 맥만 (Intel 맥은 지원하지 않는다)
  depends_on macos: :sonoma

  def install
    # Homebrew 빌드 샌드박스 안에서는 SwiftPM 의 자체 샌드박스가 중첩되어 실패한다
    ENV["SWIFT_BUILD_FLAGS"] = "--disable-sandbox"
    system "scripts/build.sh"
    prefix.install "build/AgentNotch.app"
    # 앱 이름은 AgentNotch, 명령 이름은 agent-notch
    bin.install_symlink prefix/"AgentNotch.app/Contents/MacOS/AgentNotch" => "agent-notch"
  end

  def caveats
    <<~EOS
      /Applications 에 복사해서 실행하세요 (formula 는 /Applications 를 건드리지 않아요):
        cp -R #{opt_prefix}/AgentNotch.app /Applications/ && open /Applications/AgentNotch.app

      심볼릭 링크로 걸면 Launchpad · Spotlight 가 앱으로 인식하지 못해요. 복사해야 해요.
      brew upgrade 로 올렸다면 /Applications 쪽도 다시 복사해야 새 버전이 돼요.
      (앱의 설정 > 버전 > 업데이트 를 쓰면 교체 · 재실행까지 알아서 해요)

      처음 실행하면 메뉴바 아이콘에서 "Claude Code 훅 설치" (Codex 를 쓰면 "Codex 훅 설치" 도) 를 눌러 주세요.
      ~/.claude/settings.json · ~/.codex/hooks.json 은 백업한 뒤 AgentNotch 항목만 추가해요.
      Codex 는 새 훅을 한 번 검토해야 실행해요 (Codex 앱 훅 검토, CLI 는 /hooks).

      지우기 전에는 메뉴에서 "훅 제거" 를 먼저 눌러 주세요. 그다음 brew uninstall agent-notch.
      로그인할 때 자동으로 켜려면 설정 > 일반 > 로그인 시 실행 을 켜세요.
    EOS
  end

  test do
    assert_match "agent-notch", shell_output("#{bin}/agent-notch --version")
  end
end
