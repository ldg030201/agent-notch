# AgentNotch Homebrew formula (소스 빌드)
#
# 애플 개발자 계정이 없어 서명·공증(notarization)을 할 수 없으므로, 미리 빌드한 .app 을 내려받는 cask 대신
# 사용자 맥에서 직접 빌드하는 formula 로 배포한다. 내려받은 앱에 붙는 quarantine 속성이 없어서
# Gatekeeper 에 막히지 않는다. Xcode 없이 Command Line Tools(Swift 6 이상)만 있으면 된다.
#
# 릴리스 때: url 의 태그와 sha256 을 갱신해 tap 저장소의 Formula/agent-notch.rb 로 복사한다.
#   curl -L https://github.com/OWNER/agent-notch/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256
class AgentNotch < Formula
  desc "Shows Claude Code sessions in the MacBook notch, Dynamic Island style"
  homepage "https://github.com/OWNER/agent-notch"
  url "https://github.com/OWNER/agent-notch/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  head "https://github.com/OWNER/agent-notch.git", branch: "main"
  # license: 미정 (TBD)

  depends_on macos: :sonoma

  def install
    # SwiftPM 의 자체 샌드박스는 Homebrew 빌드 샌드박스 안에서 중첩 실행할 수 없다
    ENV["SWIFT_BUILD_FLAGS"] = "--disable-sandbox"
    system "scripts/build-app.sh", "--version", version.to_s, "--output", buildpath/"dist"
    prefix.install buildpath/"dist/AgentNotch.app"

    (bin/"agent-notch").write <<~SH
      #!/bin/bash
      # AgentNotch 실행. 인자는 앱에 그대로 넘긴다 (예: agent-notch --demo)
      if [ "$1" = "--version" ]; then
        exec "#{opt_prefix}/AgentNotch.app/Contents/MacOS/AgentNotch" --version
      fi
      exec open "#{opt_prefix}/AgentNotch.app" --args "$@"
    SH
    chmod 0755, bin/"agent-notch"
  end

  service do
    run [opt_prefix/"AgentNotch.app/Contents/MacOS/AgentNotch"]
    keep_alive false
    process_type :interactive
  end

  def caveats
    <<~EOS
      처음 실행:
        agent-notch
      메뉴바 아이콘(또는 첫 실행 안내창)에서 "Claude Code 훅 설치" 를 눌러 주세요.
      ~/.claude/settings.json 은 백업한 뒤 AgentNotch 항목만 추가해요.

      로그인할 때 자동으로 실행하려면:
        brew services start agent-notch

      지우기 전에는 메뉴에서 "훅 제거" 를 먼저 눌러 주세요.
      그다음 brew services stop agent-notch, brew uninstall agent-notch,
      rm -rf ~/Library/"Application Support"/AgentNotch 순서로 정리하면 돼요.
    EOS
  end

  test do
    helper = prefix/"AgentNotch.app/Contents/MacOS/notch-hook"
    assert_match(/\A\d+\.\d+\.\d+\s*\z/, shell_output("#{helper} --version"))
    assert_match "agent-notch", shell_output("#{bin}/agent-notch --version")

    # 앱이 꺼져 있으면 헬퍼는 아무것도 출력하지 않고 exit 0 (Claude Code 동작에 영향 없음)
    ENV["AGENT_NOTCH_SOCKET"] = (testpath/"none.sock").to_s
    output = pipe_output("#{helper} Stop", '{"session_id":"brew-test","hook_event_name":"Stop"}', 0)
    assert_empty output
  end
end
