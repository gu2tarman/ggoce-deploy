# Complete install inventory. Existing clients download only missing/hash-different files.
function Get-RequiredClientFiles {
    @(
        'ClassicUO.exe',
        'cuo.dll',
        'cuoapi.dll',
        'FAudio.dll',
        'FNA3D.dll',
        'SDL3.dll',
        'libtheorafile.dll',
        'zlib.dll',
        'FNA.dll.config',
        'System.Buffers.dll',
        'System.Memory.dll',
        'System.Runtime.CompilerServices.Unsafe.dll',
        'Fonts/kodia.ttf',
        'version.txt'
    )
}

# Files taken from the previous complete package instead of the build output.
# ClassicUO.exe (NAOT loader) rebuilds with a different hash even when its source is
# unchanged; shipping the rebuild would make every client re-download it.
function Get-ReusedClientFiles {
    @('ClassicUO.exe')
}

# Highest complete client package below $CurrentVersion.
function Get-PreviousVersionDir([string]$ClientDir, [string]$CurrentVersion) {
    if (-not (Test-Path -LiteralPath $ClientDir)) { return $null }
    $cur = $null
    if (-not [version]::TryParse($CurrentVersion, [ref]$cur)) { return $null }
    $best = $null
    foreach ($d in (Get-ChildItem -LiteralPath $ClientDir -Directory -Filter 'v*')) {
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

function Assert-ClientPackageComplete([string[]]$Paths) {
    $missing = @(Get-RequiredClientFiles | Where-Object { $Paths -cnotcontains $_ })
    if ($missing.Count -gt 0) {
        throw "Incomplete client install package; required files missing: $($missing -join ', '). The manifest must contain the full install inventory, not only this release's changed files."
    }
}
