# ggoce-deploy

GGO Launcher 배포 아티팩트 호스팅 레포.

## 콘텐츠

- `notice.json` — 런처 공지사항 (Margo / GGOUO 두 섹션)
- `launcher/` — 런처 자체 업데이트 manifest + 바이너리 (Phase 9 추가 예정)
- `client/` — CUO 본체 manifest + diff 파일 (Phase 8 추가 예정)

## notice.json 갱신 방법

1. 이 파일 수정
2. `git commit && git push`
3. 런처 재시작 시 자동 반영 (5분 캐시)

## 포맷

```json
{
  "margo": [{ "id": "...", "title": "...", "date": "YYYY-MM-DD", "severity": "normal|urgent|event", "body_md": "마크다운 본문" }],
  "ggouo": [{ ... }]
}
```

`severity`:
- `normal` — 일반
- `urgent` — 빨간 테두리 + `긴급` 뱃지
- `event` — 노란 테두리 + `이벤트` 뱃지
