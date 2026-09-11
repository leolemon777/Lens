#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$env:Path = "E:\DevTools\cargo\bin;E:\DevTools\CMake\bin;$env:Path"
$env:RUSTUP_HOME = 'E:\DevTools\rustup'
$env:CARGO_HOME = 'E:\DevTools\cargo'

Push-Location (Join-Path $repoRoot 'Desktop')
try {
    npm run typecheck
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    npm run build
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
}

Push-Location (Join-Path $repoRoot 'Desktop\src-tauri')
try {
    cargo build --release
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $exe = Join-Path (Get-Location) 'target\release\lens-desktop-probe.exe'
} finally {
    Pop-Location
}

Write-Host "Starting Lens: $exe"
Start-Process $exe
