#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,
    [ValidateSet('Development', 'Public')]
    [string]$Mode = 'Development'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$manifestFull = [IO.Path]::GetFullPath($ManifestPath)
if (-not (Test-Path $manifestFull)) { throw "Manifest not found: $manifestFull" }
$manifest = Get-Content -Raw $manifestFull | ConvertFrom-Json
$root = Split-Path $manifestFull -Parent
if ($manifest.schemaVersion -ne 1) { throw 'Unsupported release manifest schema.' }
if ($manifest.PSObject.Properties.Name -contains 'stack' -and $manifest.stack -and $manifest.stack -ne 'tauri-rust') {
    throw "Release stack must be tauri-rust; found $($manifest.stack)"
}
$legacyHit = @($manifest.files | Where-Object { $_.path -match 'Lens\.Windows' })
if ($legacyHit.Count -gt 0) {
    throw "Release must not include leftover C# product files: $($legacyHit.path -join ', ')"
}
if ($Mode -eq 'Public' -and ($manifest.channel -eq 'internal' -or -not $manifest.signed -or $manifest.dirty)) {
    throw 'Public verification requires a signed, clean, non-internal package.'
}
$checked = 0
foreach ($entry in $manifest.files) {
    $path = Join-Path $root ($entry.path -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing package file: $($entry.path)" }
    $item = Get-Item -LiteralPath $path
    if ($item.Length -ne [int64]$entry.bytes) { throw "Size mismatch: $($entry.path)" }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $entry.sha256) { throw "SHA-256 mismatch: $($entry.path)" }
    $checked++
}
Write-Host "Release verified: $($manifest.product) $($manifest.version) [$($manifest.channel)]; files=$checked; mode=$Mode" -ForegroundColor Green
