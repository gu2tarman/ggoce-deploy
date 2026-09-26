<#
.SYNOPSIS
  GGO release orchestrator for the ggoce-deploy repo.

.DESCRIPTION
  Single entry point shared by Claude (/release skill) and Codex (AGENTS.md).
  It wraps the steps that build-manifest.ps1 does NOT cover:
    - safe notice insert (preserves existing entries, UTF-8 no-BOM),
    - launcher manifest update,
    - JSON / no-BOM / schema verification,
    - git staging with a prepared commit message.

  Deliberate boundaries:
    - Does NOT build (NAOT / Tauri). Build is environment-specific and is
      produced separately (Codex / CI).
    - Does NOT 'git push'. Pushing goes live instantly (the launcher fetches
      these files), so a human reviews 'verify' output and pushes manually.

.ACTIONS
  notice    Insert a notice into notice.json (ggouo | margo).
  manifest  Refresh a manifest. -Target client delegates to build-manifest.ps1;
            -Target launcher rewrites launcher/manifest.json.
  verify    Check every *.json for BOM + parse errors; deep-check client files.
  stage     verify, git add only deploy runtime changes, and print a commit message.

.EXAMPLES
  # 1) client release (after a publish folder exists)
  .\scripts\release.ps1 manifest -Target client `
     -BuildPath "C:\tmp\CUO-GGOCE-publish-v1.5.0.6" -Version 1.5.0.6 `
     -Notes "GGO CE 1.5.0.6: ..."

  # 2) announce it (existing notices are preserved)
  .\scripts\release.ps1 notice -Channel ggouo `
     -Title "GGO Custom client 1.5.0.6" `
     -Url "https://github.com/gu2tarman/ggoce-deploy" -UrlLabel "patch notes" `
     -BodyMd "**v1.5.0.6** ..."

  # 3) verify, then stage
  .\scripts\release.ps1 verify
  .\scripts\release.ps1 stage
  git commit -m "Release client v1.5.0.6 (manifest/notice)"
  # then review and: git -C <ggoce-deploy> push

  # launcher release (after CI published the GitHub Release)
  .\scripts\release.ps1 manifest -Target launcher -Version 0.1.8 `
     -ExePath "C:\path\GGOLauncher.exe" -Notes "..."
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('notice', 'manifest', 'verify', 'stage', 'help')]
    [string]$Action,

    [ValidateSet('client', 'launcher')]
    [string]$Target = 'client',

    # --- notice ---
    [ValidateSet('ggouo', 'margo')]
    [string]$Channel,
    [string]$Title,
    [string]$Date,
    [ValidateSet('normal', 'event', 'urgent')]
    [string]$Severity = 'normal',
    [string]$Url,
    [string]$UrlLabel,
    [string]$BodyMd,
    [string]$Id,

    # --- manifest (client -> build-manifest.ps1) ---
    [string]$BuildPath,
    [string]$Version,
    [string]$Notes,
    [string[]]$ClientInclude,

    # --- manifest (launcher) ---
    [string]$ExePath,
    [string]$Sha256,
    [long]$Size,

    # --- verify ---
    [switch]$Deep,

    # --- stage ---
    [switch]$Commit
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'client-package.ps1')

# ---------------------------------------------------------------------------
# Encoding-safe helpers. PowerShell 5.1's default encoding mangles UTF-8 JSON
# and ConvertTo-Json escapes < > & ' as \uXXXX; both are fixed here.
# ---------------------------------------------------------------------------

function Test-HasBom([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

function Read-JsonFile([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    return ($text | ConvertFrom-Json)
}

function Write-Utf8NoBomLf([string]$Path, [string]$Content) {
    $normalized = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
    [System.IO.File]::WriteAllText($Path, $normalized, [System.Text.UTF8Encoding]::new($false))
}

function Save-JsonFile([string]$Path, $Object) {
    $json = $Object | ConvertTo-Json -Depth 12
    # Undo PS 5.1 over-escaping so markdown bodies stay readable in git diffs.
    $json = $json -replace '\\u0027', "'" -replace '\\u003c', '<' -replace '\\u003e', '>' -replace '\\u0026', '&'
    Write-Utf8NoBomLf $Path $json
}

function Get-NowUtc() {
    return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Read-TextNoBom([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

# Highest complete client package below $CurrentVersion, for scope diffing.
function Get-PreviousVersionDir([string]$CurrentVersion) {
    $clientDir = Join-Path $RepoRoot 'client'
    if (-not (Test-Path -LiteralPath $clientDir)) { return $null }
    $cur = $null
    if (-not [version]::TryParse($CurrentVersion, [ref]$cur)) { return $null }
    $best = $null
    foreach ($d in (Get-ChildItem -LiteralPath $clientDir -Directory -Filter 'v*')) {
        $vs = $d.Name.Substring(1)
        $v = $null
        if (-not [version]::TryParse($vs, [ref]$v)) { continue }
        $missing = @(Get-RequiredClientFiles | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $d.FullName $_) -PathType Leaf)
        })
        if ($missing.Count -gt 0) { continue }
        if ($v -lt $cur -and ($null -eq $best -or $v -gt $best.Ver)) {
            $best = [pscustomobject]@{ Ver = $v; Name = $vs; Path = $d.FullName }
        }
    }
    return $best
}

# ---------------------------------------------------------------------------
# notice
# ---------------------------------------------------------------------------

function Invoke-Notice() {
    if (-not $Channel) { throw "notice requires -Channel ggouo|margo" }
    if (-not $Title) { throw "notice requires -Title" }
    if ($Channel -eq 'margo' -and ($Url -or $UrlLabel)) {
        Write-Host "note: margo (server) notices usually have no url/url_label; including them anyway." -ForegroundColor Yellow
    }

    $noticePath = Join-Path $RepoRoot 'notice.json'
    $data = Read-JsonFile $noticePath

    $d = $Date
    if (-not $d) { $d = (Get-Date).ToString('yyyy-MM-dd') }

    $entryId = $Id
    if (-not $entryId) {
        $suffix = ([guid]::NewGuid().ToString('N')).Substring(0, 6)
        $entryId = "$d-$Channel-$suffix"
    }

    $entry = [ordered]@{
        id       = $entryId
        title    = $Title
        date     = $d
        severity = $Severity
    }
    if ($Url) { $entry.url = $Url }
    if ($UrlLabel) { $entry.url_label = $UrlLabel }
    if ($BodyMd) { $entry.body_md = $BodyMd }

    $existing = @($data.$Channel)
    $before = $existing.Count
    $matches = @($existing | Where-Object { $_.id -eq $entryId })

    if ($matches.Count -gt 1) {
        throw "notice id already appears more than once in '$Channel': $entryId"
    }

    if ($matches.Count -eq 1) {
        $newArr = @($entry) + @($existing | Where-Object { $_.id -ne $entryId })
        $action = 'updated'
    }
    else {
        $newArr = @($entry) + $existing
        $action = 'inserted'
    }
    $data.$Channel = $newArr

    Save-JsonFile $noticePath $data

    Write-Host "==> $action in '$Channel' [$entryId]" -ForegroundColor Green
    Write-Host "    $Channel entries: $before -> $($newArr.Count) (existing preserved)" -ForegroundColor Gray
    Write-Host "    run 'verify' before staging." -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# manifest
# ---------------------------------------------------------------------------

function Invoke-Manifest() {
    if ($Target -eq 'client') {
        if (-not $BuildPath -or -not $Version) {
            throw "client manifest requires -BuildPath and -Version"
        }
        $buildManifest = Join-Path $PSScriptRoot 'build-manifest.ps1'
        if (-not (Test-Path -LiteralPath $buildManifest)) {
            throw "build-manifest.ps1 not found next to release.ps1"
        }
        Write-Host "==> delegating to build-manifest.ps1" -ForegroundColor Cyan
        if ($ClientInclude) {
            & $buildManifest -BuildPath $BuildPath -Version $Version -Notes $Notes -Include $ClientInclude
        }
        else {
            & $buildManifest -BuildPath $BuildPath -Version $Version -Notes $Notes
        }
        Write-Host "==> client manifest done; run 'verify' next." -ForegroundColor Green
        return
    }

    # launcher
    if (-not $Version) { throw "launcher manifest requires -Version" }
    $size = $Size
    $sha = $Sha256
    if ($ExePath) {
        if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
            throw "ExePath not found: $ExePath"
        }
        $size = (Get-Item -LiteralPath $ExePath).Length
        $sha = (Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash.ToLower()
    }
    if (-not $sha -or $size -le 0) {
        throw "launcher manifest needs -ExePath (auto), or both -Sha256 and -Size"
    }

    $verClean = $Version.TrimStart('v')
    $manifestPath = Join-Path $RepoRoot 'launcher\manifest.json'
    $url = "https://github.com/gu2tarman/GGOLauncher/releases/download/v$verClean/GGOLauncher.exe"

    $manifest = [ordered]@{
        version  = $verClean
        released = Get-NowUtc
        notes    = $Notes
        url      = $url
        size     = $size
        sha256   = $sha
    }
    Save-JsonFile $manifestPath $manifest

    Write-Host "==> launcher manifest updated: v$verClean" -ForegroundColor Green
    Write-Host ("    size={0}  sha256={1}" -f $size, $sha) -ForegroundColor Gray
    Write-Host "    url=$url" -ForegroundColor Gray
    Write-Host "    run 'verify' next." -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------

function Invoke-Verify() {
    $problems = @()
    $warnings = @()
    $checked = 0

    $jsonFiles = Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Filter *.json |
        Where-Object { $_.FullName -notmatch '\\\.git\\' }

    foreach ($f in $jsonFiles) {
        $checked++
        $rel = $f.FullName.Substring($RepoRoot.Length + 1)
        if (Test-HasBom $f.FullName) {
            $problems += "BOM present (launcher rejects it): $rel"
        }
        try {
            Read-JsonFile $f.FullName | Out-Null
        }
        catch {
            $problems += "INVALID JSON: $rel -- $($_.Exception.Message)"
        }
    }

    # notice shape
    $noticePath = Join-Path $RepoRoot 'notice.json'
    if (Test-Path -LiteralPath $noticePath) {
        try {
            $notice = Read-JsonFile $noticePath
            $ids = @{}
            foreach ($channel in 'ggouo', 'margo') {
                if (-not $notice.PSObject.Properties.Name.Contains($channel)) {
                    $problems += "notice.json missing channel: $channel"
                    continue
                }
                foreach ($entry in @($notice.$channel)) {
                    foreach ($field in 'id', 'title', 'date', 'severity') {
                        if (-not $entry.PSObject.Properties.Name.Contains($field)) {
                            $problems += "notice.json $channel entry missing field: $field"
                        }
                    }
                    if ($entry.id) {
                        if ($ids.ContainsKey($entry.id)) {
                            $problems += "notice.json duplicate id: $($entry.id)"
                        }
                        $ids[$entry.id] = $true
                    }
                    if ($entry.date -and $entry.date -notmatch '^\d{4}-\d{2}-\d{2}$') {
                        $problems += "notice.json invalid date for $($entry.id): $($entry.date)"
                    }
                    if ($entry.severity -and $entry.severity -notin @('normal', 'event', 'urgent')) {
                        $problems += "notice.json invalid severity for $($entry.id): $($entry.severity)"
                    }
                    if ($entry.url_label -and -not $entry.url) {
                        $problems += "notice.json url_label without url: $($entry.id)"
                    }
                }
            }
        }
        catch {
            $problems += "notice.json shape check failed: $($_.Exception.Message)"
        }
    }

    # sidebar shape + remotely managed launcher background URL
    $sidebarPath = Join-Path $RepoRoot 'sidebar.json'
    if (Test-Path -LiteralPath $sidebarPath) {
        try {
            $sidebar = Read-JsonFile $sidebarPath
            if (-not $sidebar.PSObject.Properties.Name.Contains('groups')) {
                $problems += "sidebar.json missing field: groups"
            }
            if ($sidebar.background_url -and $sidebar.background_url -notmatch '^https://') {
                $problems += "sidebar.json background_url must use https:// or be null"
            }
        }
        catch {
            $problems += "sidebar.json shape check failed: $($_.Exception.Message)"
        }
    }

    # client manifest <-> on-disk files
    $clientManifest = Join-Path $RepoRoot 'client\manifest.json'
    if (Test-Path -LiteralPath $clientManifest) {
        try {
            $cm = Read-JsonFile $clientManifest
            Assert-ClientPackageComplete -Paths @($cm.files | ForEach-Object { $_.path })
            foreach ($field in 'version', 'released', 'base_url', 'files') {
                if (-not $cm.PSObject.Properties.Name.Contains($field)) {
                    $problems += "client/manifest.json missing field: $field"
                }
            }
            if ($cm.version) {
                $vdir = Join-Path $RepoRoot ("client\v" + $cm.version)
                if ($cm.base_url -and $cm.base_url -notmatch "/client/v$([regex]::Escape($cm.version))/$") {
                    $problems += "client/manifest.json base_url does not match version: $($cm.base_url)"
                }
                foreach ($file in $cm.files) {
                    foreach ($field in 'path', 'size', 'sha256') {
                        if (-not $file.PSObject.Properties.Name.Contains($field)) {
                            $problems += "client/manifest.json file entry missing field: $field"
                        }
                    }
                    if ($file.path -and ($file.path -match '^\.\.?(/|\\)' -or $file.path -match '^[A-Za-z]:' -or $file.path -match '\\')) {
                        $problems += "client/manifest.json unsafe or non-normalized path: $($file.path)"
                    }
                    if ($file.sha256 -and $file.sha256 -notmatch '^[0-9a-f]{64}$') {
                        $problems += "client/manifest.json sha256 not a 64-hex lowercase digest: $($file.path)"
                    }
                    $fp = Join-Path $vdir ($file.path -replace '/', '\')
                    if (-not (Test-Path -LiteralPath $fp -PathType Leaf)) {
                        $problems += "client file missing: v$($cm.version)/$($file.path)"
                        continue
                    }
                    $actualSize = (Get-Item -LiteralPath $fp).Length
                    if ($actualSize -ne $file.size) {
                        $problems += "size mismatch v$($cm.version)/$($file.path): manifest=$($file.size) disk=$actualSize"
                    }
                    if ($Deep) {
                        $actualHash = (Get-FileHash -LiteralPath $fp -Algorithm SHA256).Hash.ToLower()
                        if ($actualHash -ne $file.sha256) {
                            $problems += "sha256 mismatch v$($cm.version)/$($file.path)"
                        }
                    }
                }

                # --- version-notation consistency: every hand-typed version string must
                #     match the shipped -Version. These are the spots build tools do NOT
                #     auto-derive, so a stale/typo'd version otherwise sails through to live.
                $vtxtPath = Join-Path $vdir 'version.txt'
                if (Test-Path -LiteralPath $vtxtPath -PathType Leaf) {
                    $vtxt = (Read-TextNoBom $vtxtPath).Trim()
                    if ($vtxt -ne $cm.version) {
                        $problems += "version.txt '$vtxt' != manifest version '$($cm.version)'"
                    }
                }
                if ($cm.notes) {
                    $noteVers = @([regex]::Matches($cm.notes, '\d+\.\d+\.\d+(?:\.\d+)?') | ForEach-Object { $_.Value } | Select-Object -Unique)
                    if ($noteVers.Count -gt 0 -and ($noteVers -notcontains $cm.version)) {
                        $problems += "manifest.notes names version(s) [$($noteVers -join ', ')] but ships $($cm.version)"
                    }
                }
                $cuoDllPath = Join-Path $vdir 'cuo.dll'
                if (Test-Path -LiteralPath $cuoDllPath -PathType Leaf) {
                    try {
                        $cuoInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($cuoDllPath)
                        foreach ($peField in 'FileVersion', 'ProductVersion') {
                            $peVersion = $cuoInfo.$peField
                            if ([string]::IsNullOrWhiteSpace($peVersion)) {
                                $problems += "cuo.dll PE $peField is empty; expected '$($cm.version)'"
                            }
                            elseif ($peVersion -ne $cm.version) {
                                $problems += "cuo.dll PE $peField '$peVersion' != manifest version '$($cm.version)'"
                            }
                        }
                    }
                    catch {
                        $problems += "cuo.dll PE version check failed: $($_.Exception.Message)"
                    }
                }
                else {
                    $problems += "cuo.dll missing from client v$($cm.version)"
                }
                # newest 'GGO CE' client patch-note must name the shipped version (title = hard,
                # body = warn since bodies legitimately back-reference older versions).
                $noticePathX = Join-Path $RepoRoot 'notice.json'
                if (Test-Path -LiteralPath $noticePathX) {
                    try {
                        $nx = Read-JsonFile $noticePathX
                        $ceNote = @($nx.ggouo) | Where-Object { $_.title -match 'GGO\s*CE\s*\d+\.\d+\.\d+' } | Select-Object -First 1
                        if ($ceNote) {
                            $tv = [regex]::Match($ceNote.title, '\d+\.\d+\.\d+(?:\.\d+)?')
                            if ($tv.Success -and $tv.Value -ne $cm.version) {
                                $problems += "newest 'GGO CE' notice is v$($tv.Value) but client ships v$($cm.version) (id $($ceNote.id))"
                            }
                            if ($ceNote.body_md) {
                                $foreign = @([regex]::Matches($ceNote.body_md, '\d+\.\d+\.\d+(?:\.\d+)?') | ForEach-Object { $_.Value } | Select-Object -Unique | Where-Object { $_ -ne $cm.version })
                                if ($foreign.Count -gt 0) {
                                    $warnings += "notice body also mentions [$($foreign -join ', ')] (ok as back-reference) - id $($ceNote.id)"
                                }
                            }
                        }
                    }
                    catch {
                        $warnings += "could not cross-check notice against client version: $($_.Exception.Message)"
                    }
                }

                # --- deploy scope: what actually changes vs the previous version. A hotfix
                #     should usually CHANGE only cuo.dll; the manifest still lists all runtime files.
                #     If ClassicUO.exe (the NAOT loader)
                #     changed, that widens the client download set for no detection benefit
                #     (version detection reads cuo.dll's PE version, not the loader).
                $prevInfo = Get-PreviousVersionDir $cm.version
                if ($prevInfo) {
                    $scope = @()
                    foreach ($file in $cm.files) {
                        if ($file.path -eq 'version.txt') { continue }
                        $prevFp = Join-Path $prevInfo.Path ($file.path -replace '/', '\')
                        if (-not (Test-Path -LiteralPath $prevFp -PathType Leaf)) {
                            $scope += "$($file.path) (new)"
                            continue
                        }
                        $prevHash = (Get-FileHash -LiteralPath $prevFp -Algorithm SHA256).Hash.ToLower()
                        if ($prevHash -ne $file.sha256) { $scope += $file.path }
                    }
                    if ($scope.Count -eq 0) {
                        $warnings += "deploy scope vs complete package v$($prevInfo.Name): only version.txt changed (no binary changes)"
                    }
                    else {
                        $warnings += "deploy scope vs complete package v$($prevInfo.Name): $($scope.Count) file(s) change -> $($scope -join ', ')"
                    }
                    if ($scope -match '^ClassicUO\.exe') {
                        $warnings += "ClassicUO.exe changed - the NAOT loader's version does NOT drive update detection (cuo.dll does). For a hotfix, confirm the loader really needed to change; do not bump src/ClassicUO.Bootstrap Directory.Build.props (stays 1.1.0.0)."
                    }
                }
            }
        }
        catch {
            $problems += "client/manifest.json check failed: $($_.Exception.Message)"
        }
    }

    # launcher manifest shape
    $launcherManifest = Join-Path $RepoRoot 'launcher\manifest.json'
    if (Test-Path -LiteralPath $launcherManifest) {
        try {
            $lm = Read-JsonFile $launcherManifest
            foreach ($field in 'version', 'released', 'notes', 'url', 'size', 'sha256') {
                if (-not $lm.PSObject.Properties.Name.Contains($field)) {
                    $problems += "launcher/manifest.json missing field: $field"
                }
            }
            if ($lm.version -and $lm.version -match '^v') {
                $problems += "launcher/manifest.json version should not include leading v"
            }
            if ($lm.released) {
                try { [datetime]::Parse($lm.released).ToUniversalTime() | Out-Null }
                catch { $problems += "launcher/manifest.json released is not parseable: $($lm.released)" }
            }
            if ($lm.size -le 0) {
                $problems += "launcher/manifest.json size must be positive"
            }
            if ($lm.sha256 -and $lm.sha256 -notmatch '^[0-9a-f]{64}$') {
                $problems += "launcher/manifest.json sha256 not a 64-hex lowercase digest"
            }
            if ($lm.version -and $lm.url -and $lm.url -notmatch "/releases/download/v$([regex]::Escape($lm.version))/GGOLauncher\.exe$") {
                $problems += "launcher/manifest.json url does not match version: $($lm.url)"
            }
        }
        catch {
            $problems += "launcher/manifest.json check failed: $($_.Exception.Message)"
        }
    }

    Write-Host ""
    Write-Host "==> verify: checked $checked json file(s)" -ForegroundColor Cyan
    if ($warnings.Count -gt 0) {
        Write-Host "==> scope / notes ($($warnings.Count)):" -ForegroundColor Yellow
        foreach ($w in $warnings) { Write-Host "    ~ $w" -ForegroundColor Yellow }
    }
    if ($problems.Count -eq 0) {
        Write-Host "==> OK - no problems found." -ForegroundColor Green
    }
    else {
        Write-Host "==> $($problems.Count) problem(s):" -ForegroundColor Red
        foreach ($p in $problems) { Write-Host "    - $p" -ForegroundColor Red }
        exit 1
    }
}

# ---------------------------------------------------------------------------
# stage
# ---------------------------------------------------------------------------

function Invoke-Stage() {
    Push-Location $RepoRoot
    try {
        Write-Host "==> verifying before staging..." -ForegroundColor Cyan
        Invoke-Verify

        $paths = @('notice.json', 'sidebar.json', 'client\manifest.json', 'launcher\manifest.json')
        $cm = Join-Path $RepoRoot 'client\manifest.json'
        if (Test-Path -LiteralPath $cm) {
            try {
                $clientVersion = (Read-JsonFile $cm).version
                if ($clientVersion) { $paths += "client\v$clientVersion" }
            }
            catch {}
        }

        foreach ($path in $paths) {
            if (Test-Path -LiteralPath (Join-Path $RepoRoot $path)) {
                git add -- $path | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "git add failed for: $path" }
            }
        }

        $stagedFiles = @(git diff --cached --name-only)
        if ($LASTEXITCODE -ne 0) { throw "git diff --cached failed" }
        $staged = $stagedFiles -join "`n"
        if (-not $staged) {
            Write-Host "==> nothing staged (no changes)." -ForegroundColor Yellow
            return
        }

        Write-Host "==> staged files:" -ForegroundColor Cyan
        git diff --cached --name-only | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }

        $msg = "Release: update deploy manifests/notice"
        $hasClient = @($stagedFiles | Where-Object { $_ -like 'client/*' }).Count -gt 0
        $hasLauncher = @($stagedFiles | Where-Object { $_ -eq 'launcher/manifest.json' }).Count -gt 0
        if ($hasClient -and (Test-Path -LiteralPath $cm)) {
            try { $msg = "Release client v$((Read-JsonFile $cm).version) (manifest/notice)" } catch {}
        }
        elseif ($hasLauncher) {
            $lm = Join-Path $RepoRoot 'launcher\manifest.json'
            try { $msg = "Release launcher v$((Read-JsonFile $lm).version) (manifest/notice)" } catch {}
        }
        elseif ($stagedFiles -contains 'notice.json') {
            $msg = "Release: update notices"
        }

        Write-Host ""
        Write-Host "==> suggested commit message:" -ForegroundColor Cyan
        Write-Host "    $msg" -ForegroundColor White

        if ($Commit) {
            git commit -m $msg | Out-Null
            Write-Host "==> committed." -ForegroundColor Green
        }
        Write-Host ""
        Write-Host "Review, then push manually (push goes live):" -ForegroundColor Yellow
        Write-Host "    git -C `"$RepoRoot`" push" -ForegroundColor White
    }
    finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------

function Show-Help() {
    Get-Help -Detailed $PSCommandPath
}

switch ($Action) {
    'notice' { Invoke-Notice }
    'manifest' { Invoke-Manifest }
    'verify' { Invoke-Verify }
    'stage' { Invoke-Stage }
    'help' { Show-Help }
}
