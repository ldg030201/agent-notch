<div align="center">

# AgentNotch

**맥북 노치에서 Claude Code 세션이 지금 뭘 하는지 보여주는 메뉴바 앱**

![macOS](https://img.shields.io/badge/macOS-14+-3A72C4?logo=apple&logoColor=white)
[![Release](https://img.shields.io/github/v/release/ldg030201/agent-notch?label=release&color=3A72C4)](https://github.com/ldg030201/agent-notch/releases)
[![License](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

</div>

---

터미널로 돌아가지 않고 노치에서 바로 확인하고 처리해요.

- 🟢 **지금 하는 일**: 프로젝트 · 툴 이름 · `+N −M`, 전체 세션 상태, 백그라운드 작업 수
- 🔁 **여러 세션**: 일하는 세션을 몇 초마다 넘기며 번갈아 보여주고, 알림 온 세션은 바로. 우클릭으로 고정
- ✏️ **미니 diff**: 파일을 고치면 잠깐 펼쳐서 바뀐 줄을 보여줘요
- 🔐 **권한 요청**: 노치에서 바로 허용 · 거부
- ✅ **완료 알림**: 걸린 시간 · 바뀐 파일 · 마지막 응답 한 줄
- 🖥️ **외부 모니터**: 메뉴바 안 알약으로 같은 내용을 보여줘요
- 🔒 **세션 내용은 내 맥 밖으로 나가지 않아요**: 네트워크 통신은 하루 한 번 새 버전 확인뿐이에요

## 📦 설치

```bash
brew tap ldg030201/agent-notch https://github.com/ldg030201/agent-notch && brew trust ldg030201/agent-notch && brew install -y agent-notch && cp -R "$(brew --prefix agent-notch)/AgentNotch.app" /Applications/ && open /Applications/AgentNotch.app
```

macOS 14 이상과 Homebrew 만 있으면 돼요 (Xcode 불필요).
애플 개발자 서명 · 공증을 못 해서 cask 대신 formula 로 배포해요. 그래서 Gatekeeper 에 막히지 않아요.

## 🚀 시작하기

1. 앱을 처음 실행하면 Claude Code 훅 설치와 로그인할 때 자동으로 켜기를 한 번에 물어봐요. 훅은 `~/.claude/settings.json` 을 백업한 뒤 AgentNotch 항목만 추가해요.
2. 새로 시작하는 Claude Code 세션부터 노치에 나타나요. 훅 없이 먼저 보려면 메뉴바 아이콘 → **데모 재생**.

업데이트는 설정 → **버전** 에서 버튼 하나로 해요.

## 📚 더 보기

- [사용 가이드](docs/usage.md): 화면 · 단축키 · 설정 · 외부 모니터 · 업데이트 · 제거 · 문제 해결 · 개인정보
- [개발 · 릴리스](docs/development.md)
- [설계](docs/architecture.md)

## 📄 라이선스

[MIT](LICENSE)
