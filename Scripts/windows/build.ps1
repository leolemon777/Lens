#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',

    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = 'x64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$outputRoot = Join-Path $repoRoot "Build\Windows\$Architecture"

# Exit codes: 0 pass, 1 work failure, 2 environment/input not satisfied.
$exitOk = 0; $exitFail = 1; $exitEnv = 2

$env:Path = "E:\DevTools\cargo\bin;$env:Path"
$env:RUSTUP_HOME = 'E:\DevTools\rustup'
$env:CARGO_HOME = 'E:\DevTools\cargo'

& (Join-Path $PSScriptRoot 'check-env.ps1') -Architecture $Architecture -ReportPath (Join-Path $outputRoot 'environment.json')
if ($LASTEXITCODE -ne 0) {
    Write-Host "Environment not satisfied; build aborted." -ForegroundColor Red
    exit $exitEnv
}

$cargoArgs = @('build', '--workspace')
$tauriArgs = @('build')
if ($Configuration -eq 'Release') {
    $cargoArgs += '--release'
    $tauriArgs += '--release'
}

Write-Host "`n=== CoreRust workspace ($Configuration) ===" -ForegroundColor Cyan
Push-Location (Join-Path $repoRoot 'CoreRust')
try {
    cargo @cargoArgs
    if ($LASTEXITCODE -ne 0) { exit $exitFail }
} finally { Pop-Location }

Write-Host "`n=== Desktop frontend ===" -ForegroundColor Cyan
Push-Location (Join-Path $repoRoot 'Desktop')
try {
    if (Test-Path 'package-lock.json') {
        npm ci
        if ($LASTEXITCODE -ne 0) { npm install; if ($LASTEXITCODE -ne 0) { exit $exitFail } }
    } else {
        npm install
        if ($LASTEXITCODE -ne 0) { exit $exitFail }
    }
    npm run typecheck
    if ($LASTEXITCODE -ne 0) { exit $exitFail }
    npm run build
    if ($LASTEXITCODE -ne 0) { exit $exitFail }
} finally { Pop-Location }

Write-Host "`n=== Tauri host ($Configuration) ===" -ForegroundColor Cyan
Push-Location (Join-Path $repoRoot 'Desktop\src-tauri')
try {
    cargo @tauriArgs
    if ($LASTEXITCODE -ne 0) { exit $exitFail }
    $exeName = if ($Configuration -eq 'Release') { 'target\release\lens-desktop-probe.exe' } else { 'target\debug\lens-desktop-probe.exe' }
    $exe = Join-Path (Get-Location) $exeName
    if (-not (Test-Path $exe)) {
        Write-Host "Expected Tauri exe missing: $exe" -ForegroundColor Red
        exit $exitFail
    }
    Write-Host "Product exe: $exe"
} finally { Pop-Location }

Write-Host "`nBuild succeeded (Tauri/Rust stack)." -ForegroundColor Green
exit $exitOk
