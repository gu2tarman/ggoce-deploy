<#
.SYNOPSIS
  GGO CE 새 빌드를 ggoce-deploy 레포로 가져와 manifest.json 자동 생성.

.DESCRIPTION
  사용 방법:
    1. GGO CE 빌드 완료 후 release 폴더가 준비됨 (예: CUO-GGOCustomEdition-v1.4.3)
    2. 이 스크립트를 ggoce-deploy 레포 루트에서 실행:
       .\scripts\build-manifest.ps1 -BuildPath "C:\...\CUO-GGOCustomEdition-v1.4.3" -Version "1.4.3"
    3. 자동으로:
       a) client/v<Version>/ 폴더에 빌드 파일 복사
       b) client/v<Version>/version.txt 생성
       c) client/manifest.json 갱신 (모든 파일 SHA256)
    4. git add . && git commit && git push 하면 끝

.PARAMETER BuildPath
  GGO CE 빌드 산출물 폴더 (예: C:\...\CUO-GGOCustomEdition-v1.4.3)

.PARAMETER Version
  배포 버전 문자열 (예: "1.4.3")

.PARAMETER Notes
  manifest에 포함할 릴리스 노트 (선택)

.PARAMETER Include
  manifest에 포함할 파일 글롭 패턴 배열. 기본: *.exe, *.dll
  PDB는 디버그 심볼이라 보통 제외. 필요 시 -Include "*.exe","*.dll","*.pdb" 식으로 추가.
#>

param(
    [Parameter(Mandatory=$true)][string]$BuildPath,
    [Parameter(Mandatory=$true)][string]$Version,
    [string]$Notes = "",
    [string[]]$Include = @("*.exe", "*.dll")
)

$ErrorActionPreference = "Stop"

# ── 경로 검증 ──────────────────────────────────────────
if (-not (Test-Path $BuildPath -PathType Container)) {
    throw "BuildPath가 폴더가 아닙니다: $BuildPath"
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$clientDir = Join-Path $repoRoot "client"
$versionDir = Join-Path $clientDir "v$Version"
$manifestPath = Join-Path $clientDir "manifest.json"

Write-Host "==> Build:    $BuildPath" -ForegroundColor Cyan
Write-Host "==> Version:  v$Version" -ForegroundColor Cyan
Write-Host "==> Target:   $versionDir" -ForegroundColor Cyan

if (Test-Path $versionDir) {
    Write-Host "기존 $versionDir 폴더 발견 — 비웁니다" -ForegroundColor Yellow
    Remove-Item -Recurse -Force $versionDir
}
New-Item -ItemType Directory -Path $versionDir | Out-Null

# ── 파일 수집 (BuildPath 루트, Include 패턴) ─────────────
$files = @()
foreach ($pattern in $Include) {
    $files += Get-ChildItem -Path $BuildPath -Filter $pattern -File
}
$files = $files | Sort-Object Name -Unique
if ($files.Count -eq 0) {
    throw "Include 패턴에 매칭되는 파일이 없습니다: $($Include -join ', ')"
}

# ── 복사 + 해시 ────────────────────────────────────────
$entries = @()
foreach ($f in $files) {
    $dest = Join-Path $versionDir $f.Name
    Copy-Item -Path $f.FullName -Destination $dest -Force
    $hash = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
    $entries += [PSCustomObject]@{
        path = $f.Name
        size = $f.Length
        sha256 = $hash
    }
    Write-Host ("  + {0,-30} {1,10} bytes  sha256={2}..." -f $f.Name, $f.Length, $hash.Substring(0,12)) -ForegroundColor Gray
}

# ── version.txt 생성 (런처의 detect_ggoce_version 폴백 + 명시적 버전) ─
$versionTxt = Join-Path $versionDir "version.txt"
[System.IO.File]::WriteAllText($versionTxt, $Version, [System.Text.UTF8Encoding]::new($false))
$vSize = (Get-Item $versionTxt).Length
$vHash = (Get-FileHash $versionTxt -Algorithm SHA256).Hash.ToLower()
$entries += [PSCustomObject]@{
    path = "version.txt"
    size = $vSize
    sha256 = $vHash
}
Write-Host ("  + version.txt                    {0,10} bytes  sha256={1}..." -f $vSize, $vHash.Substring(0,12)) -ForegroundColor Gray

# ── manifest.json 작성 ─────────────────────────────────
$baseUrl = "https://raw.githubusercontent.com/gu2tarman/ggoce-deploy/main/client/v$Version/"
$manifest = [ordered]@{
    version = $Version
    released = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
    notes = $Notes
    base_url = $baseUrl
    files = $entries
}
$json = $manifest | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($manifestPath, $json, [System.Text.UTF8Encoding]::new($false))

Write-Host ""
Write-Host "==> manifest 생성됨: $manifestPath" -ForegroundColor Green
Write-Host "==> 파일 수: $($entries.Count), 총 크기: $([math]::Round(($entries | Measure-Object size -Sum).Sum / 1MB, 2)) MB" -ForegroundColor Green
Write-Host ""
Write-Host "다음 명령으로 배포:" -ForegroundColor Cyan
Write-Host "  cd `"$repoRoot`"" -ForegroundColor White
Write-Host "  git add ." -ForegroundColor White
Write-Host "  git commit -m `"Release v$Version`"" -ForegroundColor White
Write-Host "  git push" -ForegroundColor White
