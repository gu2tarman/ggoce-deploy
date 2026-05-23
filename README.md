# ggoce-deploy

GGO Launcher가 읽는 배포 아티팩트 저장소입니다.

## 구조

```text
client/
  manifest.json          런처가 fetch하는 최신 GGO CE 클라이언트 manifest
  v1.4.2/                버전별 클라이언트 업데이트 파일
launcher/
  manifest.json          런처 자기 업데이트용 manifest
notice.json              공지사항
scripts/
  build-manifest.ps1     빌드 폴더에서 client manifest 생성
```

## 클라이언트 업데이트 원칙

`client/manifest.json`은 자동 업데이트용 클린 산출물만 포함합니다.

포함 대상:

```text
ClassicUO.exe
cuo.dll
cuoapi.dll
FAudio.dll
FNA3D.dll
SDL3.dll
libtheorafile.dll
zlib.dll
FNA.dll.config
System.Buffers.dll
System.Memory.dll
System.Runtime.CompilerServices.Unsafe.dll
Fonts/kodia.ttf
version.txt
```

제외 대상:

```text
settings.json
Logs/
Macros/
Profiles/
Screenshots/
*.pdb
```

런처는 manifest에 포함된 파일만 검사/다운로드/교체해야 합니다. manifest에 없는 사용자 설정, 프로필, 매크로, 로그 파일은 건드리지 않습니다.

## 새 GGO CE 버전 배포 절차

예시:

```powershell
.\scripts\build-manifest.ps1 `
  -BuildPath "C:\Users\USER\Desktop\CUO-GGOCE-Test\CUO-GGOCustomEdition-v1.4.2" `
  -Version "1.4.2" `
  -Notes "Official ClassicUO multi reading fix + GGO CE v1.4.2"
```

스크립트가 하는 일:

```text
client/v<Version>/ 폴더 재생성
allowlist 파일 복사
Fonts/kodia.ttf 복사
version.txt 생성
client/manifest.json 갱신
각 파일 size/sha256 기록
```

검토 후 커밋:

```bash
git status
git diff client/manifest.json
git add client scripts README.md
git commit -m "Release v1.4.2 client manifest"
git push
```

## manifest 형식

```json
{
  "version": "1.4.2",
  "released": "2026-05-23T00:00:00Z",
  "notes": "Release notes",
  "base_url": "https://raw.githubusercontent.com/gu2tarman/ggoce-deploy/main/client/v1.4.2/",
  "files": [
    { "path": "cuo.dll", "size": 15172096, "sha256": "..." },
    { "path": "Fonts/kodia.ttf", "size": 3670336, "sha256": "..." }
  ]
}
```

런처 주의사항:

```text
manifest.version이 로컬 버전과 같아도 files 전체를 순회해서 파일 존재 여부와 sha256을 비교해야 합니다.
version만 같다고 최신으로 판단하면 안 됩니다.
```

GGO CE 버전 감지는 `ClassicUO.exe`가 아니라 `cuo.dll`의 PE `FileVersion` 또는 `ProductVersion`을 읽습니다.
