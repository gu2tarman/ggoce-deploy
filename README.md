# ggoce-deploy

GGO Launcher 배포 아티팩트 호스팅 레포.

## 구조

```
client/
  manifest.json         ← 런처가 fetch하는 최신 매니페스트
  v1.4.2/               ← 버전별 파일 (cuo.dll, ClassicUO.exe, …, version.txt)
  v1.4.3/
notice.json             ← 공지사항 (Margo / GGOUO 섹션)
scripts/
  build-manifest.ps1    ← 새 GGO CE 빌드 → 자동 manifest 생성 헬퍼
```

## 새 GGO CE 릴리스 절차

1. GGO CE 빌드 완료 (예: `C:\...\CUO-GGOCustomEdition-v1.4.3`)
2. **이 레포 루트에서** 스크립트 실행:
   ```powershell
   .\scripts\build-manifest.ps1 `
     -BuildPath "C:\Users\USER\Desktop\CUO-GGOCE-Test\CUO-GGOCustomEdition-v1.4.3" `
     -Version "1.4.3" `
     -Notes "버그 수정, 신규 던전"
   ```
3. 스크립트가 자동으로:
   - `client/v1.4.3/` 폴더에 모든 .exe + .dll 복사
   - `version.txt` 자동 생성 (내용: `1.4.3`)
   - `client/manifest.json` 갱신 (SHA256 포함)
4. git 푸시:
   ```bash
   git add .
   git commit -m "Release v1.4.3"
   git push
   ```
5. 끝. 다음에 사용자가 런처 켜면 자동으로 "업데이트 다운로드 v1.4.3" 표시됨.

## 공지사항 갱신

`notice.json` 수정 → `git commit && git push`. 런처 재시작 시 자동 반영.

### 포맷
```json
{
  "margo": [{ "id": "...", "title": "...", "date": "YYYY-MM-DD", "severity": "normal|urgent|event", "body_md": "마크다운 본문", "url": "선택적 외부 링크" }],
  "ggouo": [{ ... }]
}
```

severity: `normal` (일반) / `urgent` (빨강 강조) / `event` (노랑 강조)

## manifest 포맷

```json
{
  "version": "1.4.3",
  "released": "2026-05-23T01:50:00Z",
  "notes": "...",
  "base_url": "https://raw.githubusercontent.com/gu2tarman/ggoce-deploy/main/client/v1.4.3/",
  "files": [
    { "path": "cuo.dll", "size": 15172096, "sha256": "..." }
  ]
}
```

런처가 manifest 파일 목록 외 파일은 **절대 건드리지 않음** → 사용자 프로필/매크로/설정 자동 보존.
