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

`client/manifest.json`과 해당 버전 폴더에는 **신규 설치에 필요한 필수 파일 전체**를 항상 포함합니다.
manifest는 변경 파일 목록이 아니라 완전한 설치 목록입니다.

- 신규 설치: 필수 파일 전체를 다운로드합니다.
- 기존 설치 업데이트: 로컬 파일의 존재 여부·크기·SHA-256을 비교하여 누락되거나 내용이 달라진 파일만 다운로드합니다. 보통 `cuo.dll`과 `version.txt`만 달라집니다.
- 변경하지 않은 실행 파일·라이브러리·폰트는 검증된 기존 바이너리를 그대로 재사용합니다. 새 버전 폴더에 포함되어도 해시가 같으면 다시 다운로드하지 않습니다.
- `-ClientInclude` / `-Include`로 필수 목록을 변경 파일 두 개로 축소하면 안 됩니다. 필수 목록은 `scripts/client-package.ps1`에서 관리하며 생성 및 검증 시 누락을 거부합니다.
- 배포 전 빈 폴더 신규 설치, 정상 이전 버전 업데이트, 정상 동일 버전 재검사, 일부 파일 누락 복구를 각각 확인합니다.

기존 버전의 필수 파일 누락을 복구할 때는 바이너리 버전업 없이 완전한 패키지를 준비한 뒤 같은 `-Version`으로 `release.ps1 manifest -Target client`를 실행할 수 있습니다. 기존 `cuo.dll`과 `version.txt`의 해시를 보존하고 `verify -Deep` 후 게시합니다.


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

아래 `files`는 형식 설명용 일부 예시입니다. 실제 manifest에는 위 필수 목록 전체가 있어야 합니다.

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
