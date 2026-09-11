#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',

    [string]$DataRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$exitOk = 0; $exitFail = 1; $exitEnv = 2

$profileDir = if ($Configuration -eq 'Release') { 'release' } else { 'debug' }
$exePath = Join-Path $repoRoot "Desktop\src-tauri\target\$profileDir\lens-desktop-probe.exe"
if (-not (Test-Path $exePath)) {
    Write-Host "Tauri build output not found: $exePath" -ForegroundColor Red
    Write-Host "Run: pwsh Scripts/windows/build.ps1 -Configuration $Configuration"
    exit $exitEnv
}

if ($DataRoot) {
    $env:LENS_LIBRARY_ROOT = $DataRoot
}

Write-Host "Starting Lens: $exePath"
& $exePath
exit $LASTEXITCODE
