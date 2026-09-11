#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$target = 'x86_64-pc-windows-msvc'
if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot 'Build\Windows\generated\THIRD_PARTY_LICENSES.md'
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

function Escape-Table([object]$Value) {
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function Find-LicenseFiles([string]$Directory) {
    @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(LICENSE|COPYING|NOTICE|UNLICENSE)(\.|$|-)' } |
        Sort-Object Name)
}

$cargoPackages = @()
foreach ($manifest in @('CoreRust\Cargo.toml', 'Desktop\src-tauri\Cargo.toml')) {
    $manifestPath = Join-Path $repoRoot $manifest
    $metadata = cargo metadata --manifest-path $manifestPath --format-version 1 --locked --offline --filter-platform $target | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "cargo metadata failed for $manifest" }
    $resolved = @($metadata.resolve.nodes.id)
    $cargoPackages += @($metadata.packages | Where-Object { $_.source -and $resolved -contains $_.id })
}
$cargoPackages = @($cargoPackages | Sort-Object name, version -Unique)
$cargoMissing = @($cargoPackages | Where-Object { -not $_.license -and -not $_.license_file })
if ($cargoMissing.Count -gt 0) {
    throw "Rust dependencies without license metadata: $($cargoMissing.name -join ', ')"
}

$lock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Desktop\package-lock.json') | ConvertFrom-Json -AsHashtable
$npmPackages = @($lock.packages.GetEnumerator() |
    Where-Object { $_.Key -like 'node_modules/*' } |
    ForEach-Object {
        $entry = $_.Value
        [pscustomobject]@{
            name = $_.Key -replace '^node_modules/', ''
            version = $entry.version
            license = $entry.license
            directory = Join-Path (Join-Path $repoRoot 'Desktop') $_.Key
        }
    } | Sort-Object name, version)
$npmMissing = @($npmPackages | Where-Object { -not $_.license })
if ($npmMissing.Count -gt 0) {
    throw "npm dependencies without license metadata: $($npmMissing.name -join ', ')"
}

$licenseTexts = @{}
function Add-LicenseText([string]$Owner, [string]$Path) {
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not $licenseTexts.ContainsKey($hash)) {
        $licenseTexts[$hash] = [ordered]@{ owners = [Collections.Generic.List[string]]::new(); path = $Path }
    }
    $licenseTexts[$hash].owners.Add($Owner)
}
foreach ($package in $cargoPackages) {
    $directory = Split-Path $package.manifest_path
    foreach ($file in Find-LicenseFiles $directory) {
        Add-LicenseText "Rust $($package.name) $($package.version)" $file.FullName
    }
}
foreach ($package in $npmPackages) {
    foreach ($file in Find-LicenseFiles $package.directory) {
        Add-LicenseText "npm $($package.name) $($package.version)" $file.FullName
    }
}
if ($licenseTexts.Count -eq 0) { throw 'No dependency license texts were found in the locked package sources' }

$ffmpeg = Get-Command ffmpeg -ErrorAction Stop
$ffprobe = Get-Command ffprobe -ErrorAction Stop
$ffmpegVersion = (& $ffmpeg.Source -version | Select-Object -First 1)
$ffmpegConfiguration = (& $ffmpeg.Source -buildconf 2>&1 | Where-Object { $_ -match '^\s+--' }) -join ' '
$ffmpegHash = (Get-FileHash -LiteralPath $ffmpeg.Source -Algorithm SHA256).Hash.ToLowerInvariant()
$ffprobeHash = (Get-FileHash -LiteralPath $ffprobe.Source -Algorithm SHA256).Hash.ToLowerInvariant()

$builder = [Text.StringBuilder]::new()
[void]$builder.AppendLine('# Lens Windows Third-Party Notices')
[void]$builder.AppendLine()
[void]$builder.AppendLine("Generated from locked dependencies for target ``$target`` at $((Get-Date).ToUniversalTime().ToString('o')).")
[void]$builder.AppendLine('This inventory is generated evidence, not a substitute for release-owner legal review.')
[void]$builder.AppendLine()
[void]$builder.AppendLine('## Distributed media tools')
[void]$builder.AppendLine()
[void]$builder.AppendLine("- FFmpeg: $(Escape-Table $ffmpegVersion)")
[void]$builder.AppendLine("- FFmpeg SHA-256: ``$ffmpegHash``")
[void]$builder.AppendLine("- ffprobe SHA-256: ``$ffprobeHash``")
[void]$builder.AppendLine('- License family: GPL version 3 or later for the currently selected Gyan full build; the build enables GPL/version3 components including libx264/libx265.')
[void]$builder.AppendLine("- Build configuration: ``$(Escape-Table $ffmpegConfiguration)``")
[void]$builder.AppendLine('- Upstream/legal: https://ffmpeg.org/legal.html')
[void]$builder.AppendLine('- Binary provider: https://www.gyan.dev/ffmpeg/builds/')
[void]$builder.AppendLine()
[void]$builder.AppendLine("## Rust packages ($($cargoPackages.Count))")
[void]$builder.AppendLine()
[void]$builder.AppendLine('| Package | Version | License | Repository |')
[void]$builder.AppendLine('|---|---:|---|---|')
foreach ($package in $cargoPackages) {
    [void]$builder.AppendLine("| $(Escape-Table $package.name) | $(Escape-Table $package.version) | $(Escape-Table ($package.license ?? $package.license_file)) | $(Escape-Table $package.repository) |")
}
[void]$builder.AppendLine()
[void]$builder.AppendLine("## npm packages ($($npmPackages.Count))")
[void]$builder.AppendLine()
[void]$builder.AppendLine('| Package | Version | License |')
[void]$builder.AppendLine('|---|---:|---|')
foreach ($package in $npmPackages) {
    [void]$builder.AppendLine("| $(Escape-Table $package.name) | $(Escape-Table $package.version) | $(Escape-Table $package.license) |")
}
[void]$builder.AppendLine()
[void]$builder.AppendLine("## License and notice texts ($($licenseTexts.Count) unique files)")
foreach ($hash in @($licenseTexts.Keys | Sort-Object)) {
    $record = $licenseTexts[$hash]
    [void]$builder.AppendLine()
    [void]$builder.AppendLine("### $($record.owners -join ', ')")
    [void]$builder.AppendLine()
    [void]$builder.AppendLine("Source text SHA-256: ``$hash``")
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('```text')
    [void]$builder.AppendLine([IO.File]::ReadAllText($record.path).TrimEnd())
    [void]$builder.AppendLine('```')
}

$parent = Split-Path $OutputPath
New-Item -ItemType Directory -Path $parent -Force | Out-Null
[IO.File]::WriteAllText($OutputPath, $builder.ToString(), [Text.UTF8Encoding]::new($false))
Write-Host "Generated notices: $OutputPath ($($cargoPackages.Count) Rust, $($npmPackages.Count) npm, $($licenseTexts.Count) unique texts)" -ForegroundColor Green
