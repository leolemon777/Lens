#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DataRoot,
    [string]$InstallRoot,
    [string]$BasePackage = 'Build\Releases\Windows\Lens-0.1.4-x64',
    [string]$UpgradePackage = 'Build\Releases\Windows\Lens-0.1.5-x64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$dataRootResolved = [IO.Path]::GetFullPath($DataRoot)
$installRootResolved = if ($InstallRoot) { [IO.Path]::GetFullPath($InstallRoot) } else { Join-Path $dataRootResolved 'install' }
$corruptRoot = Join-Path $dataRootResolved 'corrupt-upgrade'
foreach ($path in @($dataRootResolved, $installRootResolved, $corruptRoot)) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
}
New-Item -ItemType Directory -Path $dataRootResolved -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $dataRootResolved 'user-data') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $dataRootResolved 'user-data\keep.txt') -Value 'must survive upgrade failure' -Encoding utf8

$installer = Join-Path $repoRoot 'Scripts\windows\install.ps1'
$basePackageResolved = if ([IO.Path]::IsPathRooted($BasePackage)) {
    [IO.Path]::GetFullPath($BasePackage)
} else {
    [IO.Path]::GetFullPath((Join-Path $repoRoot $BasePackage))
}
$upgradePackageResolved = if ([IO.Path]::IsPathRooted($UpgradePackage)) {
    [IO.Path]::GetFullPath($UpgradePackage)
} else {
    [IO.Path]::GetFullPath((Join-Path $repoRoot $UpgradePackage))
}
& pwsh -NoProfile -File $installer -Action Install -PackageRoot $basePackageResolved -InstallRoot $installRootResolved
if ($LASTEXITCODE -ne 0) { throw 'Base install failed.' }

Copy-Item -LiteralPath $upgradePackageResolved -Destination $corruptRoot -Recurse
$corruptBinary = Join-Path $corruptRoot 'app\Lens.exe'
if (-not (Test-Path -LiteralPath $corruptBinary -PathType Leaf)) {
    throw "Expected packaged app binary missing: $corruptBinary"
}
Add-Content -LiteralPath $corruptBinary -Value 'intentional corruption' -Encoding utf8

& pwsh -NoProfile -File $installer -Action Upgrade -PackageRoot $corruptRoot -InstallRoot $installRootResolved
$failedUpgradeExitCode = $LASTEXITCODE
if ($failedUpgradeExitCode -eq 0) { throw 'Corrupt upgrade unexpectedly succeeded.' }

$state = Get-Content -LiteralPath (Join-Path $installRootResolved 'current.json') -Raw | ConvertFrom-Json
$userDataPath = Join-Path $dataRootResolved 'user-data\keep.txt'
$activeApp = Join-Path $installRootResolved "versions\$($state.currentVersion)\app\Lens.exe"
if ($state.currentVersion -ne '0.1.4') { throw "Failed upgrade changed active version to $($state.currentVersion)." }
if (-not (Test-Path -LiteralPath $activeApp -PathType Leaf)) { throw 'Active app disappeared after failed upgrade.' }
if (-not (Test-Path -LiteralPath $userDataPath -PathType Leaf)) { throw 'User data disappeared after failed upgrade.' }

$report = [ordered]@{
    failedUpgradeExitCode = $failedUpgradeExitCode
    activeVersionAfterFailure = $state.currentVersion
    activeAppPreserved = [bool](Test-Path -LiteralPath $activeApp -PathType Leaf)
    userDataPreserved = [bool](Test-Path -LiteralPath $userDataPath -PathType Leaf)
    stagingDirectories = @(Get-ChildItem -LiteralPath $installRootResolved -Directory -Filter '.staging-*').Count
}
$reportPath = Join-Path $dataRootResolved 'installer-stress-report.json'
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding utf8
$report | ConvertTo-Json -Depth 5
Write-Output "Installer stress report: $reportPath"
