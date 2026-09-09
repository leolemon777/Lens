[CmdletBinding()]
param([switch]$CI)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = Split-Path $PSScriptRoot -Parent
Set-Location $Root
$TranscriptStarted = $false
try {
    Start-Transcript -Path (Join-Path $Root 'build.log') -Force | Out-Null
    $TranscriptStarted = $true
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Build this application on Windows x64.' }
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit Windows installation is required.' }
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        throw 'Rust is missing. Install the stable x86_64-pc-windows-msvc toolchain from https://rustup.rs/ and restart this terminal. Also install Visual Studio C++ Build Tools and Windows SDK; see docs/BUILD.md.'
    }
    if (Get-Command rustup -ErrorAction SilentlyContinue) {
        & rustup target add x86_64-pc-windows-msvc
        if ($LASTEXITCODE -ne 0) { throw 'Failed to install the Windows MSVC target.' }
    }
    & rustc --version
    if ($LASTEXITCODE -ne 0) { throw 'rustc could not start.' }
    & cargo --version
    if ($LASTEXITCODE -ne 0) { throw 'cargo could not start.' }
    # The first build resolves dependencies. Keep the resulting lockfile for future --locked builds.
    if (-not (Test-Path Cargo.lock)) {
        & cargo generate-lockfile
        if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed; no successful build is claimed.' }
    }
    & cargo test --locked -p lens-core --target x86_64-pc-windows-msvc
    if ($LASTEXITCODE -ne 0) { throw 'Rust core tests failed. Packaging is stopped.' }
    & cargo build --locked --release -p lens-windows --target x86_64-pc-windows-msvc
    if ($LASTEXITCODE -ne 0) { throw 'Windows application compilation failed. Packaging is stopped.' }
    $Exe = Join-Path $Root 'target\x86_64-pc-windows-msvc\release\lens-windows.exe'
    if (-not (Test-Path $Exe)) { throw 'cargo returned without the expected application binary.' }
    $Destination = Join-Path $Root 'dist\Lens-Windows'
    # Only the generated distribution directory is replaced; never touch the recording library.
    if (Test-Path $Destination) { Remove-Item -Recurse -Force $Destination }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Copy-Item $Exe (Join-Path $Destination 'Lens.exe')
    Copy-Item LICENSE, THIRD-PARTY-NOTICES.md, Cargo.lock -Destination $Destination
    Copy-Item docs\FIRST-RUN.md (Join-Path $Destination 'FIRST-RUN.md')
    if (Test-Path (Join-Path $Root 'tools\ffmpeg\bin\ffmpeg.exe')) {
        New-Item -ItemType Directory -Path (Join-Path $Destination 'tools') -Force | Out-Null
        Copy-Item (Join-Path $Root 'tools\ffmpeg') (Join-Path $Destination 'tools\ffmpeg') -Recurse
    } else {
        Write-Warning 'FFmpeg is not installed. This build supports silent single-segment recording and PNG screenshots only. Run Prepare-Media.cmd then rebuild for audio and segmented pause.'
    }
    $Evidence = [ordered]@{
        builtAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        target = 'x86_64-pc-windows-msvc'
        rustc = (& rustc --version | Out-String).Trim()
        exeSha256 = (Get-FileHash (Join-Path $Destination 'Lens.exe') -Algorithm SHA256).Hash
        lockSha256 = (Get-FileHash Cargo.lock -Algorithm SHA256).Hash
        rustCoreTests = 'passed during this build'
        windowsRecordingSmokeTest = 'NOT RUN: compilation does not verify desktop capture or audio'
    }
    $Evidence | ConvertTo-Json | Set-Content (Join-Path $Destination 'BUILD-EVIDENCE.json') -Encoding UTF8
    $Archive = Join-Path $Root 'dist\Lens-Windows-v0.1.0-x64.zip'
    Compress-Archive -Path "$Destination\*" -DestinationPath $Archive -Force
    Write-Host "Portable application: $Destination\Lens.exe" -ForegroundColor Green
    Write-Host "Archive: $Archive" -ForegroundColor Green
    Write-Host 'Run the interactive acceptance checklist in docs/ACCEPTANCE.md before important recordings.'
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
} finally {
    if ($TranscriptStarted) { Stop-Transcript | Out-Null }
}
