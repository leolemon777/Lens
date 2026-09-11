#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Unit', 'Protocol', 'Project', 'Media', 'Screenshot', 'Recording',
                 'Recovery', 'Effects', 'Analysis', 'Interop', 'Accessibility', 'SyncFixture', 'Install',
                 'Frontend', 'Desktop')]
    [string]$Suite = 'Unit',

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$exitOk = 0; $exitFail = 1; $exitEnv = 2

$env:Path = "E:\DevTools\cargo\bin;$env:Path"
$env:RUSTUP_HOME = 'E:\DevTools\rustup'
$env:CARGO_HOME = 'E:\DevTools\cargo'

function Invoke-CargoTest([string]$Location, [string[]]$CargoTestArguments) {
    Push-Location $Location
    try {
        cargo test @CargoTestArguments
        if ($LASTEXITCODE -ne 0) { exit $exitFail }
    } finally { Pop-Location }
}

switch ($Suite) {
    'Unit' {
        Invoke-CargoTest (Join-Path $repoRoot 'CoreRust') @('--workspace', '--offline')
        Push-Location (Join-Path $repoRoot 'Desktop')
        try {
            npx tsc --noEmit
            if ($LASTEXITCODE -ne 0) { exit $exitFail }
        } finally { Pop-Location }
    }
    'Frontend' {
        Push-Location (Join-Path $repoRoot 'Desktop')
        try {
            npx tsc --noEmit
            if ($LASTEXITCODE -ne 0) { exit $exitFail }
            npx vite build
            if ($LASTEXITCODE -ne 0) { exit $exitFail }
        } finally { Pop-Location }
    }
    'Desktop' {
        Push-Location (Join-Path $repoRoot 'Desktop\src-tauri')
        try {
            cargo check --offline
            if ($LASTEXITCODE -ne 0) { exit $exitFail }
        } finally { Pop-Location }
    }
    'Protocol' {
        Invoke-CargoTest (Join-Path $repoRoot 'CoreRust') @('-p', 'lens-core', '--test', 'protocol_golden', '--offline')
        Invoke-CargoTest (Join-Path $repoRoot 'CoreRust') @('-p', 'lens-core', '--test', 'worker_integration', '--offline')
    }
    'Project' {
        Invoke-CargoTest (Join-Path $repoRoot 'CoreRust') @('-p', 'lens-core', '--test', 'schema_tests', '--offline')
        Invoke-CargoTest (Join-Path $repoRoot 'CoreRust') @('-p', 'lens-core', '--test', 'project_compatibility', '--offline')
        Invoke-CargoTest (Join-Path $repoRoot 'CoreRust') @('-p', 'lens-project', '--offline')
    }
    'Recording' {
        Invoke-CargoTest (Join-Path $repoRoot 'CoreRust') @('-p', 'lens-platform-windows', '--lib', '--offline')
        Write-Host "Skipped ignored hardware recording tests (run cargo test -- --ignored on a capture box)."
    }
    'Media' {
        Invoke-CargoTest (Join-Path $repoRoot 'CoreRust') @('-p', 'lens-platform-windows', '--offline')
        Invoke-CargoTest (Join-Path $repoRoot 'CoreRust') @('-p', 'lens-project', '--offline')
    }
    'Recovery' {
        Invoke-CargoTest (Join-Path $repoRoot 'CoreRust') @('-p', 'lens-platform-windows', '--offline')
        Write-Host "Forced-kill recovery remains #[ignore]; not claimed as G-W2 pass."
    }
    'Screenshot' {
        Invoke-CargoTest (Join-Path $repoRoot 'CoreRust') @('-p', 'lens-platform-windows', '--lib', 'screenshot', '--offline')
    }
    'Interop' {
        Invoke-CargoTest (Join-Path $repoRoot 'CoreRust') @('-p', 'lens-core', 'interop', '--offline')
        Invoke-CargoTest (Join-Path $repoRoot 'CoreRust') @('-p', 'lens-core', 'quality', '--offline')
    }
    'Analysis' {
        Invoke-CargoTest (Join-Path $repoRoot 'CoreRust') @('-p', 'lens-core', 'quality', '--offline')
        Invoke-CargoTest (Join-Path $repoRoot 'CoreRust') @('-p', 'lens-platform-windows', 'transcript', '--offline')
        Write-Host "G-W5 CER/WER on real models is not claimed; evaluator tests only."
    }
    'Accessibility' {
        Write-Host "Accessibility suite is not implemented for the Tauri shell yet." -ForegroundColor Yellow
        exit $exitEnv
    }
    'Effects' {
        Invoke-CargoTest (Join-Path $repoRoot 'CoreRust') @('-p', 'lens-project', 'xfade', '--offline')
        Invoke-CargoTest (Join-Path $repoRoot 'CoreRust') @('-p', 'lens-project', '--test', 'media_regression', '--offline', '--', '--ignored', '--test-threads=1')
    }
    'SyncFixture' {
        Write-Host "SyncFixture still requires a dedicated WGC/WASAPI machine pass." -ForegroundColor Yellow
        exit $exitEnv
    }
    'Install' {
        Write-Host "Install suite requires a signed/unsigned Tauri package produced by package.ps1." -ForegroundColor Yellow
        exit $exitEnv
    }
    default {
        Write-Host "Suite '$Suite' is not yet implemented." -ForegroundColor Yellow
        exit $exitEnv
    }
}

Write-Host "`nTests passed for suite: $Suite" -ForegroundColor Green
exit $exitOk
