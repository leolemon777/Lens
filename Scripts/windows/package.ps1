#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('internal', 'beta', 'stable')]
    [string]$Channel = 'internal',
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = 'x64',
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$')]
    [string]$Version,
    [string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$packageLockDir = Join-Path $repoRoot 'Build\Windows'
New-Item -ItemType Directory -Path $packageLockDir -Force | Out-Null
$packageLockPath = Join-Path $packageLockDir 'package.lock'
try {
    $packageLock = [IO.File]::Open($packageLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
} catch {
    throw "Another Lens packaging process owns $packageLockPath; refusing concurrent NSIS output writes. $($_.Exception.Message)"
}
$outputBase = if ($OutputRoot) { [IO.Path]::GetFullPath($OutputRoot) } else { Join-Path $repoRoot 'Build\Releases\Windows' }
$packageRoot = Join-Path $outputBase "Lens-$Version-$Architecture"

if ($Channel -eq 'stable') {
    $dirty = git -C $repoRoot status --porcelain
    if ($dirty) { throw 'stable packaging requires a clean git worktree' }
}

& (Join-Path $PSScriptRoot 'build.ps1') -Configuration Release -Architecture $Architecture
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$env:Path = "E:\DevTools\cargo\bin;$env:Path"

# Clean any previous bundles to guarantee we never copy stale artifacts
$bundleDir = Join-Path $repoRoot 'Desktop\src-tauri\target\release\bundle'
if (Test-Path $bundleDir) {
    Remove-Item $bundleDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Prepare every runtime dependency inside Desktop\src-tauri\resources before Tauri generates NSIS.
# The paths are declared in tauri.conf.json, so missing files cause an immediate build failure.
$resourceStage = Join-Path $repoRoot 'Desktop\src-tauri\resources'
if (Test-Path $resourceStage) {
    Remove-Item -LiteralPath $resourceStage -Recurse -Force
}
New-Item -ItemType Directory -Path $resourceStage -Force | Out-Null

$distDir = Join-Path $repoRoot 'Desktop\dist'
$worker = Join-Path $repoRoot 'CoreRust\target\release\lens-worker.exe'
$licenseFile = Join-Path $repoRoot 'Build\Windows\generated\THIRD_PARTY_LICENSES.md'
& (Join-Path $PSScriptRoot 'generate-third-party-notices.ps1') -OutputPath $licenseFile
if ($LASTEXITCODE -ne 0) { throw 'Third-party notice generation failed; refusing to package' }
$ffmpegCmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
$ffprobeCmd = Get-Command ffprobe -ErrorAction SilentlyContinue
if (-not (Test-Path (Join-Path $distDir 'index.html'))) { throw "Missing built frontend: $distDir" }
if (-not (Test-Path $worker)) { throw "Missing release worker: $worker" }
if (-not $ffmpegCmd -or -not (Test-Path $ffmpegCmd.Source)) { throw 'ffmpeg.exe is required for packaging' }
if (-not $ffprobeCmd -or -not (Test-Path $ffprobeCmd.Source)) { throw 'ffprobe.exe is required for packaging' }
if (-not (Test-Path $licenseFile)) { throw "Missing third-party notices: $licenseFile" }

Copy-Item $distDir (Join-Path $resourceStage 'dist') -Recurse -Force
Copy-Item $worker (Join-Path $resourceStage 'lens-worker.exe') -Force
Copy-Item $ffmpegCmd.Source (Join-Path $resourceStage 'ffmpeg.exe') -Force
Copy-Item $ffprobeCmd.Source (Join-Path $resourceStage 'ffprobe.exe') -Force
Copy-Item $licenseFile (Join-Path $resourceStage 'THIRD_PARTY_LICENSES.md') -Force

# Ensure output directory for makensis exists
$bundleNsisDir = Join-Path $repoRoot 'Desktop\src-tauri\target\release\bundle\nsis'
New-Item -ItemType Directory -Path $bundleNsisDir -Force | Out-Null

Push-Location (Join-Path $repoRoot 'Desktop')
try {
    npx tauri build --bundles nsis
    if ($LASTEXITCODE -ne 0) {
        throw "Tauri NSIS bundle build failed with exit code $LASTEXITCODE; refusing to package incomplete or stale build."
    }
} finally {
    Pop-Location
}

$builtInstaller = Get-ChildItem (Join-Path $repoRoot 'Desktop\src-tauri\target\release\bundle\nsis') -Filter '*setup.exe' -File |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
if (-not $builtInstaller) { throw 'Tauri reported success but no NSIS installer was produced' }
# The two required media binaries total more than 400 MiB uncompressed. A tiny
# installer is definitive evidence that bundle resources were omitted.
if ($builtInstaller.Length -lt 50MB) {
    throw "NSIS installer is unexpectedly small ($($builtInstaller.Length) bytes); refusing a resource-incomplete package"
}

$staging = Join-Path $outputBase ".staging-$Version-$Architecture-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $staging -Force | Out-Null
try {
    $appPublish = Join-Path $staging 'app'
    New-Item -ItemType Directory -Path $appPublish -Force | Out-Null
    $exe = Join-Path $repoRoot 'Desktop\src-tauri\target\release\lens-desktop-probe.exe'
    if (-not (Test-Path $exe)) { throw "Missing Tauri exe: $exe" }
    Copy-Item $exe (Join-Path $appPublish 'Lens.exe')
    $nsisDir = Join-Path $repoRoot 'Desktop\src-tauri\target\release\bundle\nsis'
    if (Test-Path $nsisDir) {
        Copy-Item (Join-Path $nsisDir '*') $appPublish -Recurse -ErrorAction SilentlyContinue
    } else {
        throw "NSIS output directory not found at $nsisDir after tauri build"
    }
    Copy-Item (Join-Path $resourceStage 'lens-worker.exe') (Join-Path $appPublish 'lens-worker.exe') -Force

    # Package frontend assets alongside binary for self-contained runtime
    $publishDist = Join-Path $appPublish 'dist'
    Copy-Item (Join-Path $resourceStage 'dist') $publishDist -Recurse -Force

    # Package FFmpeg / ffprobe binaries
    Copy-Item (Join-Path $resourceStage 'ffmpeg.exe') (Join-Path $appPublish 'ffmpeg.exe') -Force
    Copy-Item (Join-Path $resourceStage 'ffprobe.exe') (Join-Path $appPublish 'ffprobe.exe') -Force
    Copy-Item (Join-Path $resourceStage 'THIRD_PARTY_LICENSES.md') (Join-Path $appPublish 'THIRD_PARTY_LICENSES.md') -Force

    $files = Get-ChildItem $staging -File -Recurse | Where-Object { $_.Name -ne 'release.json' }
    $entries = foreach ($file in $files) {
        [ordered]@{
            path = [IO.Path]::GetRelativePath($staging, $file.FullName).Replace('\', '/')
            bytes = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $legacyHit = @($entries | Where-Object { $_.path -match 'Lens\.Windows' })
    if ($legacyHit.Count -gt 0) {
        throw "Package must not contain leftover C# product files: $($legacyHit.path -join ', ')"
    }
    $manifest = [ordered]@{
        schemaVersion = 1
        product = 'Lens'
        version = $Version
        channel = $Channel
        architecture = $Architecture
        stack = 'tauri-rust'
        targetFramework = 'none'
        signed = $false
        authenticode = $false
        commit = (git -C $repoRoot rev-parse HEAD).Trim()
        dirty = [bool](git -C $repoRoot status --porcelain)
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        files = @($entries)
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $staging 'release.json') -Encoding UTF8

    if (Test-Path $packageRoot) {
        $resolvedBase = [IO.Path]::GetFullPath($outputBase).TrimEnd('\') + '\'
        $resolvedTarget = [IO.Path]::GetFullPath($packageRoot)
        if (-not $resolvedTarget.StartsWith($resolvedBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to replace package outside output root.' }
        Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
    }
    Move-Item -LiteralPath $staging -Destination $packageRoot
    Write-Host "Package created: $(Join-Path $packageRoot 'release.json')" -ForegroundColor Green
    if ($Channel -ne 'internal' -and -not $manifest.signed) {
        Write-Host "Unsigned package; Public/G-W6 signing is still a blocker." -ForegroundColor Yellow
    }
} finally {
    if (Test-Path $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}
