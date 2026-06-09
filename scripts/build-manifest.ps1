<#
.SYNOPSIS
  Copy a clean GGO CE client build into ggoce-deploy and generate client/manifest.json.

.DESCRIPTION
  Default files are a conservative auto-update allowlist:
  runtime binaries, cuo.dll, ClassicUO.exe, version.txt, and the bundled kodia font.

  User-owned files are intentionally excluded:
  settings.json, Logs, Macros, Profiles, Screenshots, and *.pdb.

.EXAMPLE
  .\scripts\build-manifest.ps1 `
    -BuildPath "C:\Users\USER\Desktop\CUO-GGOCE-Test\CUO-GGOCustomEdition-v1.4.2" `
    -Version "1.4.2" `
    -Notes "Official ClassicUO multi reading fix + GGO CE v1.4.2"
#>

param(
    [Parameter(Mandatory=$true)][string]$BuildPath,
    [Parameter(Mandatory=$true)][string]$Version,
    [string]$Notes = "",
    [string[]]$Include = @(
        "ClassicUO.exe",
        "cuo.dll",
        "cuoapi.dll",
        "FAudio.dll",
        "FNA3D.dll",
        "SDL3.dll",
        "libtheorafile.dll",
        "zlib.dll",
        "FNA.dll.config",
        "System.Buffers.dll",
        "System.Memory.dll",
        "System.Runtime.CompilerServices.Unsafe.dll",
        "Fonts/kodia.ttf"
    )
)

$ErrorActionPreference = "Stop"

function To-NormalizedRelativePath([string]$Path) {
    return ($Path -replace "\\", "/").TrimStart("/")
}

function Write-Utf8NoBomLf([string]$Path, [string]$Content) {
    $normalized = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
    [System.IO.File]::WriteAllText($Path, $normalized, [System.Text.UTF8Encoding]::new($false))
}

if (-not (Test-Path -LiteralPath $BuildPath -PathType Container)) {
    throw "BuildPath is not a directory: $BuildPath"
}

$resolvedBuildPath = (Resolve-Path -LiteralPath $BuildPath).Path
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$clientDir = Join-Path $repoRoot "client"
$versionDir = Join-Path $clientDir "v$Version"
$manifestPath = Join-Path $clientDir "manifest.json"

Write-Host "==> Build:    $resolvedBuildPath" -ForegroundColor Cyan
Write-Host "==> Version:  v$Version" -ForegroundColor Cyan
Write-Host "==> Target:   $versionDir" -ForegroundColor Cyan

if (Test-Path -LiteralPath $versionDir) {
    Write-Host "Existing $versionDir found; replacing it" -ForegroundColor Yellow
    Remove-Item -LiteralPath $versionDir -Recurse -Force
}
New-Item -ItemType Directory -Path $versionDir | Out-Null

$fileMap = @{}

foreach ($entry in $Include) {
    $normalized = To-NormalizedRelativePath $entry
    $localPattern = $normalized -replace "/", [System.IO.Path]::DirectorySeparatorChar
    $fullPattern = Join-Path $resolvedBuildPath $localPattern

    if ($normalized.Contains("*") -or $normalized.Contains("?")) {
        $matches = Get-ChildItem -Path $fullPattern -File
        foreach ($match in $matches) {
            $rel = [System.IO.Path]::GetRelativePath($resolvedBuildPath, $match.FullName)
            $rel = To-NormalizedRelativePath $rel
            $fileMap[$rel] = $match.FullName
        }
        continue
    }

    if (-not (Test-Path -LiteralPath $fullPattern -PathType Leaf)) {
        throw "Required release file is missing: $normalized"
    }

    $fileMap[$normalized] = (Resolve-Path -LiteralPath $fullPattern).Path
}

if ($fileMap.Count -eq 0) {
    throw "No files matched Include list."
}

$entries = @()
foreach ($relPath in ($fileMap.Keys | Sort-Object)) {
    $source = $fileMap[$relPath]
    $dest = Join-Path $versionDir ($relPath -replace "/", [System.IO.Path]::DirectorySeparatorChar)
    $destDir = Split-Path -Parent $dest

    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir | Out-Null
    }

    Copy-Item -LiteralPath $source -Destination $dest -Force
    $item = Get-Item -LiteralPath $dest
    $hash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLower()

    $entries += [PSCustomObject]@{
        path = $relPath
        size = $item.Length
        sha256 = $hash
    }

    Write-Host ("  + {0,-55} {1,10} bytes  sha256={2}..." -f $relPath, $item.Length, $hash.Substring(0,12)) -ForegroundColor Gray
}

$versionTxt = Join-Path $versionDir "version.txt"
Write-Utf8NoBomLf $versionTxt $Version
$vItem = Get-Item -LiteralPath $versionTxt
$vHash = (Get-FileHash -LiteralPath $versionTxt -Algorithm SHA256).Hash.ToLower()
$entries += [PSCustomObject]@{
    path = "version.txt"
    size = $vItem.Length
    sha256 = $vHash
}
Write-Host ("  + version.txt                                             {0,10} bytes  sha256={1}..." -f $vItem.Length, $vHash.Substring(0,12)) -ForegroundColor Gray

$baseUrl = "https://raw.githubusercontent.com/gu2tarman/ggoce-deploy/main/client/v$Version/"
$manifest = [ordered]@{
    version = $Version
    released = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    notes = $Notes
    base_url = $baseUrl
    files = $entries
}

$json = $manifest | ConvertTo-Json -Depth 5
Write-Utf8NoBomLf $manifestPath $json

Write-Host ""
Write-Host "==> manifest created: $manifestPath" -ForegroundColor Green
Write-Host "==> files: $($entries.Count), total size: $([math]::Round(($entries | Measure-Object size -Sum).Sum / 1MB, 2)) MB" -ForegroundColor Green
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "  git status" -ForegroundColor White
Write-Host "  git diff client/manifest.json" -ForegroundColor White
Write-Host "  git add client scripts README.md" -ForegroundColor White
Write-Host "  git commit -m `"Release v$Version client manifest`"" -ForegroundColor White
