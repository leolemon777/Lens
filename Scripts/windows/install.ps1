#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Upgrade', 'Rollback', 'Uninstall')]
    [string]$Action = 'Install',
    [string]$PackageRoot,
    [Parameter(Mandatory = $true)]
    [string]$InstallRoot,
    [ValidateSet('Development', 'Public')]
    [string]$VerificationMode = 'Development',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FullPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path)
}

function Assert-SafeInstallRoot([string]$Path) {
    $full = Get-FullPath $Path
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root) -or $full.TrimEnd('\') -eq $root.TrimEnd('\')) {
        throw "Refusing to use a filesystem root as install directory: $full"
    }
    return $full
}

function Read-State([string]$Root) {
    $statePath = Join-Path $Root 'current.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
}

function Write-State([string]$Root, [string]$CurrentVersion, [string]$PreviousVersion) {
    $statePath = Join-Path $Root 'current.json'
    $temporary = "$statePath.$([guid]::NewGuid().ToString('N')).tmp"
    [ordered]@{
        schemaVersion = 1
        currentVersion = $CurrentVersion
        previousVersion = $PreviousVersion
        currentAppPath = (Join-Path $Root "versions\$CurrentVersion\app")
        updatedUtc = [DateTimeOffset]::UtcNow
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $statePath -Force
}

$installRootResolved = Assert-SafeInstallRoot $InstallRoot
$markerPath = Join-Path $installRootResolved '.lens-install-root'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$verifyScript = Join-Path $repoRoot 'Scripts\windows\verify-release.ps1'

if ($Action -eq 'Uninstall') {
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw "Install marker not found; refusing to remove $installRootResolved"
    }
    Remove-Item -LiteralPath $installRootResolved -Recurse -Force
    Write-Output "Uninstalled Lens from $installRootResolved; user data was not touched."
    exit 0
}

$state = Read-State $installRootResolved
if ($Action -eq 'Rollback') {
    if ($null -eq $state -or [string]::IsNullOrWhiteSpace([string]$state.previousVersion)) {
        throw 'No previous version is available for rollback.'
    }
    $previous = [string]$state.previousVersion
    $previousApp = Join-Path $installRootResolved "versions\$previous\app"
    if (-not (Test-Path -LiteralPath $previousApp -PathType Container)) {
        throw "Previous version is missing: $previousApp"
    }
    Write-State $installRootResolved $previous ([string]$state.currentVersion)
    Write-Output "Rolled back Lens to $previous."
    exit 0
}

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    throw "-PackageRoot is required for $Action."
}
$packageRootResolved = Get-FullPath $PackageRoot
$manifestPath = Join-Path $packageRootResolved 'release.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Release manifest not found: $manifestPath" }

& $verifyScript -ManifestPath $manifestPath -Mode $VerificationMode
if (-not $?) { throw 'Release verification failed.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$version = [string]$manifest.version
if ([string]::IsNullOrWhiteSpace($version)) { throw 'Release manifest has no version.' }

if ($Action -eq 'Install' -and $null -ne $state -and -not $Force) {
    throw "Lens is already installed at version $($state.currentVersion); use Upgrade or -Force."
}
if ($Action -eq 'Upgrade' -and ($null -eq $state -or [string]::IsNullOrWhiteSpace([string]$state.currentVersion))) {
    throw 'Cannot upgrade before an initial install.'
}
if ($null -ne $state -and [string]$state.currentVersion -eq $version -and -not $Force) {
    throw "Version $version is already active."
}

New-Item -ItemType Directory -Path $installRootResolved -Force | Out-Null
Set-Content -LiteralPath $markerPath -Value 'Lens transactional install root; do not edit.' -Encoding utf8
$versionsRoot = Join-Path $installRootResolved 'versions'
New-Item -ItemType Directory -Path $versionsRoot -Force | Out-Null
$stagingRoot = Join-Path $installRootResolved ".staging-$([guid]::NewGuid().ToString('N'))"
$stagingVersion = Join-Path $stagingRoot $version
$targetVersion = Join-Path $versionsRoot $version
try {
    New-Item -ItemType Directory -Path $stagingVersion -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $packageRootResolved 'app') -Destination $stagingVersion -Recurse
    Copy-Item -LiteralPath $manifestPath -Destination $stagingVersion
    if (Test-Path -LiteralPath $targetVersion) {
        if (-not $Force) { throw "Version directory already exists: $targetVersion" }
        Remove-Item -LiteralPath $targetVersion -Recurse -Force
    }
    Move-Item -LiteralPath $stagingVersion -Destination $targetVersion
    $previousVersion = if ($null -eq $state) { '' } else { [string]$state.currentVersion }
    Write-State $installRootResolved $version $previousVersion
    Write-Output "Installed Lens $version at $(Join-Path $targetVersion 'app')."
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
