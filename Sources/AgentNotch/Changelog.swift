import Foundation
import NotchServices

// 버전별 변경 내역. 설정 "버전" 탭이 이걸 보여주고, `--dump-changelog` 로 뽑은 docs/changelog.json 을
// 다른 버전의 앱이 원격으로 받아 본다. 쓰는 규칙은 docs/development.md 의 "변경 내역" 참고.
//
// - 무언가를 만들거나 고치면 날짜가 비어 있는(date: nil) 맨 위 항목에 한 줄 더한다.
// - 기능 단위로 한 줄, 명사형으로 끝맺는다. 동작을 서술하지 않는다.
// - JSON 은 손으로 고치지 않는다: `source scripts/lib.sh && dump_changelog`
// - 날짜는 scripts/release.sh 가 채운다 (`version: "X", date: nil` 형태를 바꾸지 않는다).

enum Changelog {
    /// 원격 내역 주소. 릴리스 API 대신 이 파일 하나로 최신 버전과 내역을 함께 받는다.
    static let feedURL = URL(string: "https://raw.githubusercontent.com/ldg030201/agent-notch/main/docs/changelog.json")!

    /// `--dump-changelog` 가 쓰는 JSON (키 정렬 고정)
    static func jsonData() throws -> Data {
        try ChangelogFeed(entries: entries).jsonData()
    }

    /// 최신이 위로 온다
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(version: "0.1.0", date: nil, groups: [
            ChangelogGroup(title: "노치 아일랜드", isNew: true, notes: [
                .new("Claude Code 세션 상태 표시 (프로젝트 · 지금 쓰는 툴 · +N −M)"),
                .new("파일 수정 미리보기 (파일명 · 줄 번호 · 미니 diff)"),
                .new("완료 · 실패 요약 (걸린 시간 · 바뀐 파일 수 · 마지막 응답 한 줄)"),
                .new("질문 · 계획 승인 · MCP 입력 요청 알림"),
                .new("클릭해서 펼치는 세션 목록 · 타임라인 · diff · 최근 응답"),
                .new("전역 단축키 ⌃⌥⌘N (펼치기 · 접기)"),
            ]),
            ChangelogGroup(title: "권한 요청", tab: "general", isNew: true, notes: [
                .new("노치에서 허용 · 항상 허용 · 거부 · 터미널로"),
                .new("키보드 단축키 (⌘↩ 허용 · ⌥⌘↩ 항상 허용 · ⌘⌫ 거부 · ⎋ 접기)"),
                .new("터미널이 앞에 있으면 터미널 프롬프트로 바로 넘기기 (끄기 가능)"),
                .new("노치에서 기다리는 최대 시간 설정 (기본 120초)"),
            ]),
            ChangelogGroup(title: "여러 세션", isNew: true, notes: [
                .new("주의가 필요한 세션 자동 포커스 (권한 → 입력 → 실패 → 완료 순)"),
                .new("세션 고정 (메뉴에서 ⌥ 또는 펼친 목록의 핀)"),
                .new("터미널로 이동 (iTerm2 는 해당 탭까지)"),
            ]),
            ChangelogGroup(title: "표시", tab: "display", isNew: true, notes: [
                .new("외부 모니터의 메뉴바 안 알약 (메뉴바 아래 · 표시 안 함 선택 가능)"),
                .new("메뉴바 아이콘을 가리지 않는 노치 옆 배치 (노치 아래 띠 · 선만 선택 가능)"),
                .new("손쉬운 사용 권한으로 메뉴 위치 정확히 감지"),
                .new("열린 메뉴 · 팝오버와 겹칠 때 잠깐 숨기기"),
                .new("다른 노치 앱 감지"),
                .new("표시 화면 · 풀스크린 동작 · 미리보기 · 완료 표시 시간 · 응답 스트리밍 설정"),
            ]),
            ChangelogGroup(title: "Claude Code 훅", tab: "general", isNew: true, notes: [
                .new("메뉴 · 설정에서 훅 설치 · 다시 설치 · 제거 (settings.json 백업, 다른 훅은 그대로)"),
                .new("처음 실행할 때 훅 설치 안내"),
            ]),
            ChangelogGroup(title: "업데이트", tab: "version", isNew: true, notes: [
                .new("새 버전 확인 (하루 1회, 끄기 가능)"),
                .new("앱 안에서 업데이트 (진행 로그, 다 받은 뒤 다시 띄우기)"),
                .new("버전별 변경 내역"),
            ]),
            ChangelogGroup(title: "일반", tab: "general", isNew: true, notes: [
                .new("로그인 시 실행"),
            ]),
            ChangelogGroup(title: "데모", isNew: true, notes: [
                .new("훅 없이 모든 상태를 보여주는 약 40초 데모 (메뉴바 메뉴에서 재생)"),
            ]),
        ]),
    ]
}
