import Foundation
import NotchServices

// 버전별 변경 내역. 설정 "버전" 탭이 이걸 보여주고, `--dump-changelog` 로 뽑은 docs/changelog.json 을
// 다른 버전의 앱이 원격으로 받아 본다. 쓰는 규칙은 docs/development.md 의 "변경 내역" 참고.
//
// - 무언가를 만들거나 고치면 날짜가 비어 있는(date: nil) 맨 위 항목에 한 줄 더한다.
// - 기능 단위로 한 줄, 명사형으로 끝맺는다. 동작을 서술하지 않는다.
// - 묶음마다 제목 앞 아이콘(SF Symbol 이름)을 단다.
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
        ChangelogEntry(version: "1.0.1", date: "2026-10-17", groups: [
            ChangelogGroup(title: "설치", icon: "shippingbox.fill", notes: [
                .fix("macOS 15 에서 설치(소스 빌드)가 실패하던 문제"),
                .change("Apple Silicon 맥만 지원"),
            ]),
            ChangelogGroup(title: "업데이트", icon: "arrow.down.circle.fill", tab: "version", notes: [
                .fix("업데이트를 취소해도 Homebrew 가 계속 돌던 문제"),
            ]),
        ]),
        ChangelogEntry(version: "1.0.0", date: "2026-10-17", groups: [
            ChangelogGroup(title: "노치 아일랜드", icon: "rectangle.topthird.inset.filled", isNew: true, notes: [
                .new("세션 상태 · 지금 쓰는 툴 · 바뀐 줄 수 표시"),
                .new("파일 수정 미리보기 · 완료 요약"),
                .new("펼쳐 보는 세션 목록 · 타임라인"),
            ]),
            ChangelogGroup(title: "권한 · 질문", icon: "hand.raised.fill", tab: "general", isNew: true, notes: [
                .new("노치에서 허용 · 항상 허용 · 거부"),
                .new("질문 답하기 · 계획 승인 (권장 선택지 표시)"),
                .new("Claude 앱을 보고 있어도 노치에서 승인 · 답하기"),
                .new("터미널 · Claude 앱으로 넘기기 (Claude 앱은 그 세션을 바로 열기)"),
            ]),
            ChangelogGroup(title: "여러 세션", icon: "square.stack.3d.up.fill", isNew: true, notes: [
                .new("세션 자동 넘기기 (알림 온 세션 먼저, 우클릭으로 고정)"),
                .new("진행 중인 세션은 목록 위로 (상태가 바뀌면 미끄러지듯 이동)"),
                .new("백그라운드 작업 수 표시"),
                .new("앱을 다시 켜도 진행 중인 세션 이어 보기"),
            ]),
            ChangelogGroup(title: "표시", icon: "display", tab: "display", isNew: true, notes: [
                .new("노치 아래 띠 (메뉴바를 가리지 않음)"),
                .new("외부 모니터 메뉴바 알약"),
                .new("열린 메뉴와 겹치면 피하기"),
            ]),
            ChangelogGroup(title: "단축키", icon: "keyboard", tab: "shortcuts", isNew: true, notes: [
                .new("어디서든 펼치기 · 카드 단축키 (처음엔 꺼짐, 키 바꾸기)"),
            ]),
            ChangelogGroup(title: "시작하기", icon: "power", tab: "general", isNew: true, notes: [
                .new("첫 실행 안내 (훅 설치 · 로그인 시 실행)"),
                .new("설정 초기화"),
            ]),
            ChangelogGroup(title: "업데이트", icon: "arrow.down.circle.fill", tab: "version", isNew: true, notes: [
                .new("앱 안에서 업데이트 (하루 1회 확인)"),
                .new("버전별 변경 내역"),
            ]),
            ChangelogGroup(title: "데모", icon: "play.circle.fill", isNew: true, notes: [
                .new("훅 없이 모든 상태를 보여주는 데모"),
            ]),
        ]),
    ]
}
