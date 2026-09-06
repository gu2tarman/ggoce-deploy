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

function Assert-ClientPackageComplete([string[]]$Paths) {
    $missing = @(Get-RequiredClientFiles | Where-Object { $Paths -cnotcontains $_ })
    if ($missing.Count -gt 0) {
        throw "Incomplete client install package; required files missing: $($missing -join ', '). The manifest must contain the full install inventory, not only this release's changed files."
    }
}
