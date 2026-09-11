#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = 'x64',

    [Parameter(Mandatory = $false)]
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExitOk = 0
$ExitWorkFailed = 1
$ExitEnvNotSatisfied = 2

function New-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('installed', 'missing', 'version-mismatch', 'unfrozen', 'unknown')][string]$Status,
        [string]$Version = '',
        [string]$Detail = ''
    )
    [ordered]@{
        name    = $Name
        status  = $Status
        version = $Version
        detail  = $Detail
    }
}

function Get-FirstToolLine {
    param(
        [Parameter(Mandatory)][string]$Tool,
        [string[]]$ArgumentList = @('--version')
    )
    try {
        $command = Get-Command $Tool -ErrorAction Stop
        $output = & $command.Source @ArgumentList 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($output | Select-Object -First 1)
    } catch {
        return $null
    }
}

$checks = [System.Collections.Generic.List[object]]::new()

# --- Operating system and requested architecture ---
$os = Get-CimInstance Win32_OperatingSystem
# CIM OSArchitecture is a localized display string ("64-bit", "64 位", ...).
# PROCESSOR_ARCHITECTURE is stable regardless of UI language.
$processorArch = $env:PROCESSOR_ARCHITECTURE
$osArchitectureMatches = ($Architecture -eq 'x64' -and $processorArch -eq 'AMD64') -or
    ($Architecture -eq 'arm64' -and $processorArch -eq 'ARM64')
$checks.Add((New-Check -Name 'os' `
    -Status ($(if ($osArchitectureMatches) { 'installed' } else { 'version-mismatch' })) `
    -Version "$($os.Caption) build $($os.BuildNumber)" `
    -Detail "Requested $Architecture; PROCESSOR_ARCHITECTURE=$processorArch"))

# --- PowerShell ---
$pwshVersion = $PSVersionTable.PSVersion.ToString()
$checks.Add((New-Check -Name 'pwsh' -Status 'installed' -Version $pwshVersion -Detail $PSHOME))

# --- Node.js / npm (Tauri frontend) ---
$nodeVersion = Get-FirstToolLine -Tool 'node'
$npmVersion = Get-FirstToolLine -Tool 'npm'
if ($nodeVersion -and $npmVersion) {
    $checks.Add((New-Check -Name 'node' -Status 'installed' -Version $nodeVersion -Detail "npm $npmVersion"))
} else {
    $checks.Add((New-Check -Name 'node' -Status 'missing' -Detail 'node/npm not found on PATH'))
}

# --- WebView2 Runtime ---
$webview2Keys = @(
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
    'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
    'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
)
$webview2Version = $null
foreach ($key in $webview2Keys) {
    $item = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    if ($item -and $item.pv) {
        $webview2Version = [string]$item.pv
        break
    }
}
if ($webview2Version) {
    $checks.Add((New-Check -Name 'webview2' -Status 'installed' -Version $webview2Version))
} else {
    $checks.Add((New-Check -Name 'webview2' -Status 'missing' -Detail 'WebView2 Runtime not found in EdgeUpdate registry'))
}

# --- Rust toolchain (rustc + cargo + MSVC host) ---
$rustcVersion = Get-FirstToolLine -Tool 'rustc'
$cargoVersion = Get-FirstToolLine -Tool 'cargo'
$rustHost = ''
if ($rustcVersion) {
    try {
        $rustcCmd = Get-Command rustc -ErrorAction Stop
        $vv = & $rustcCmd.Source -vV 2>$null
        $hostLine = $vv | Where-Object { $_ -like 'host:*' } | Select-Object -First 1
        if ($hostLine) { $rustHost = ($hostLine -replace 'host:\s*', '').Trim() }
    } catch {}
}
$expectedRustHost = if ($Architecture -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
if (-not $rustcVersion -or -not $cargoVersion) {
    $checks.Add((New-Check -Name 'rust' -Status 'missing' -Detail "rustc/cargo not found on PATH; expected host $expectedRustHost"))
} elseif ($rustHost -and $rustHost -ne $expectedRustHost) {
    $checks.Add((New-Check -Name 'rust' -Status 'version-mismatch' -Version "$rustcVersion / $cargoVersion" -Detail "host is $rustHost, expected $expectedRustHost"))
} else {
    $checks.Add((New-Check -Name 'rust' -Status 'installed' -Version "$rustcVersion / $cargoVersion" -Detail "host $rustHost"))
}

# --- Visual Studio C++ workload (vswhere, not PATH-only) ---
$vswherePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsInstance = $null
if (Test-Path -LiteralPath $vswherePath) {
    $vsJson = & $vswherePath -all -products * -requires Microsoft.VisualStudio.Workload.NativeDesktop Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json 2>$null
    if ($LASTEXITCODE -eq 0 -and $vsJson) {
        $vsInstance = ($vsJson | ConvertFrom-Json) | Select-Object -First 1
    }
}
if ($vsInstance) {
    $checks.Add((New-Check -Name 'visual-cpp-workload' -Status 'installed' -Version $vsInstance.installationVersion -Detail $vsInstance.installationPath))
} else {
    $checks.Add((New-Check -Name 'visual-cpp-workload' -Status 'missing' -Detail 'No complete VS instance with NativeDesktop workload and VC tools found via vswhere'))
}

# --- Windows SDK (registry root first, then common roots) ---
$sdkRoots = @()
# Windows Kits can be relocated to another drive; Installed Roots\KitsRoot10
# is the canonical pointer the installer writes in that case.
$kitsRootReg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue
if ($kitsRootReg -and $kitsRootReg.PSObject.Properties['KitsRoot10']) { $sdkRoots += $kitsRootReg.KitsRoot10 }
$sdkRoots += @(
    (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'),
    (Join-Path $env:ProgramFiles 'Windows Kits\10')
)
$sdkVersions = @()
foreach ($root in ($sdkRoots | Select-Object -Unique)) {
    $includeRoot = Join-Path $root 'Include'
    if (Test-Path -LiteralPath $includeRoot) {
        $sdkVersions += @(Get-ChildItem -LiteralPath $includeRoot -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    }
}
$sdkVersions = @($sdkVersions | Sort-Object -Unique)
if ($sdkVersions.Count -gt 0) {
    $checks.Add((New-Check -Name 'windows-sdk' -Status 'installed' -Version ($sdkVersions -join ', ') -Detail "Roots: $(($sdkRoots | Select-Object -Unique) -join '; ')"))
} else {
    $checks.Add((New-Check -Name 'windows-sdk' -Status 'missing' -Detail 'No Windows 10 SDK include directories found'))
}

# --- Disk space on the repository drive ---
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$repoDrive = ($repoRoot -split ':')[0] + ':'
$volume = Get-Volume -DriveLetter ($repoDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
if ($volume) {
    $freeGiB = [math]::Round($volume.SizeRemaining / 1GB, 1)
    $diskStatus = if ($volume.SizeRemaining -ge 20GB) { 'installed' } else { 'version-mismatch' }
    $checks.Add((New-Check -Name 'disk-space' -Status $diskStatus -Version "$freeGiB GiB free" -Detail "$($volume.FileSystem) on $repoDrive"))
} else {
    $checks.Add((New-Check -Name 'disk-space' -Status 'unknown' -Detail "Could not query volume for $repoDrive"))
}

# --- Version lock files (W0 deliverable; unfrozen until they exist) ---
$lockFiles = @(
    'CoreRust\rust-toolchain.toml',
    'CoreRust\Cargo.lock',
    'Desktop\package-lock.json'
)
$missingLocks = @($lockFiles | Where-Object { -not (Test-Path (Join-Path $repoRoot $_)) })
if ($missingLocks.Count -eq 0) {
    $checks.Add((New-Check -Name 'version-lock' -Status 'installed' -Detail ($lockFiles -join '; ')))
} else {
    $checks.Add((New-Check -Name 'version-lock' -Status 'unfrozen' -Detail "Not created yet (expected before W0 freeze): $($missingLocks -join '; ')"))
}

# --- Repository commit ---
$commit = ''
try {
    $gitCmd = Get-Command git -ErrorAction Stop
    Push-Location $repoRoot
    try { $commit = (& $gitCmd.Source rev-parse HEAD 2>$null).Trim() } finally { Pop-Location }
} catch {}

# --- Summary and report ---
$missing = @()
$unfrozen = @()
foreach ($check in $checks) {
    if ($check['status'] -in @('missing', 'version-mismatch')) { $missing += $check['name'] }
    if ($check['status'] -eq 'unfrozen') { $unfrozen += $check['name'] }
}

$report = [ordered]@{
    timestamp      = (Get-Date).ToUniversalTime().ToString('o')
    repository     = $repoRoot
    commit         = $commit
    architecture   = $Architecture
    summary        = [ordered]@{
        missing   = $missing
        unfrozen  = $unfrozen
        ready     = ($missing.Count -eq 0)
    }
    checks         = $checks
}

$reportJson = $report | ConvertTo-Json -Depth 6
if ($ReportPath) {
    $reportFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath)
    $reportDir = Split-Path -Parent $reportFullPath
    if ($reportDir -and -not (Test-Path -LiteralPath $reportDir)) {
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    }
    Set-Content -LiteralPath $reportFullPath -Value $reportJson -Encoding UTF8
}

Write-Host $reportJson

if ($missing.Count -gt 0) {
    Write-Host "`nEnvironment not satisfied. Missing or mismatched: $($missing -join ', ')" -ForegroundColor Yellow
    exit $ExitEnvNotSatisfied
}
if ($unfrozen.Count -gt 0) {
    Write-Host "`nEnvironment installed but versions unfrozen: $($unfrozen -join ', ')" -ForegroundColor Yellow
}
exit $ExitOk
