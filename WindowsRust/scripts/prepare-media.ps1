[CmdletBinding()]
param([switch]$CI)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root = Split-Path $PSScriptRoot -Parent
$Target = Join-Path $Root 'tools\ffmpeg'
if (-not $CI) {
    Write-Host 'This downloads an LGPL-labelled Windows x64 FFmpeg build from BtbN/FFmpeg-Builds on GitHub.'
    Write-Host 'It is used locally for audio muxing and completed-segment export. No recording is uploaded.'
    Write-Host 'The archive SHA-256 is verified against the GitHub asset digest or release checksum file.'
    if ((Read-Host 'Download the media tools? Type YES to continue') -cne 'YES') { throw 'Download cancelled. Nothing was installed.' }
}
$Headers = @{ 'User-Agent'='Lens-Windows-Build'; 'Accept'='application/vnd.github+json' }
if ($env:GITHUB_TOKEN) { $Headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
$Release = Invoke-RestMethod -Uri 'https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest' -Headers $Headers
# Deliberately exclude GPL and non-free labelled artifacts.
$Asset = $Release.assets | Where-Object { $_.name -eq 'ffmpeg-master-latest-win64-lgpl.zip' } | Select-Object -First 1
if (-not $Asset) { throw 'Expected LGPL Windows x64 archive is not available. No alternative was silently selected.' }
$Temp = Join-Path ([IO.Path]::GetTempPath()) ('lens-media-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Temp | Out-Null
try {
    $Archive = Join-Path $Temp $Asset.name
    # Do not forward API authorization headers to a download redirect host.
    Invoke-WebRequest -UseBasicParsing -Uri $Asset.browser_download_url -OutFile $Archive
    $Actual = (Get-FileHash $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $Expected = $null
    if (($Asset.PSObject.Properties.Name -contains 'digest') -and $Asset.digest -and $Asset.digest.StartsWith('sha256:')) {
        $Expected = $Asset.digest.Substring(7).ToLowerInvariant()
    } else {
        $ChecksumAsset = $Release.assets | Where-Object { $_.name -eq 'checksums.sha256' } | Select-Object -First 1
        if (-not $ChecksumAsset) { throw 'No verifiable SHA-256 was published; refusing to use this archive.' }
        $ChecksumPath = Join-Path $Temp 'checksums.sha256'
        Invoke-WebRequest -UseBasicParsing -Uri $ChecksumAsset.browser_download_url -OutFile $ChecksumPath
        $Pattern = '^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($Asset.name) + '$'
        foreach ($Line in [IO.File]::ReadLines($ChecksumPath)) { if ($Line -match $Pattern) { $Expected = $Matches[1].ToLowerInvariant(); break } }
    }
    if (-not $Expected -or $Actual -ne $Expected) { throw 'SHA-256 verification failed. The downloaded executable will not be installed or run.' }
    $Extract = Join-Path $Temp 'unpacked'
    Expand-Archive -Path $Archive -DestinationPath $Extract
    $Binary = Get-ChildItem $Extract -Recurse -File -Filter ffmpeg.exe | Select-Object -First 1
    if (-not $Binary) { throw 'Archive does not contain ffmpeg.exe.' }
    $Package = Split-Path (Split-Path $Binary.FullName -Parent) -Parent
    if (-not (Test-Path (Join-Path $Package 'bin\ffmpeg.exe'))) { throw 'Unexpected FFmpeg package structure.' }
    # Preserve upstream notices, documentation and any licence texts along with the binary.
    $Staging = Join-Path $Root 'tools\ffmpeg.new'
    if (Test-Path $Staging) { Remove-Item $Staging -Recurse -Force }
    Copy-Item $Package $Staging -Recurse
    [ordered]@{
        upstream='https://github.com/BtbN/FFmpeg-Builds'; release=$Release.tag_name
        archive=$Asset.name; archiveSha256=$Actual; downloadedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        source=$Asset.browser_download_url; sourceBuildRecipes='https://github.com/BtbN/FFmpeg-Builds'
    } | ConvertTo-Json | Set-Content (Join-Path $Staging 'UPSTREAM.json') -Encoding UTF8
    Copy-Item (Join-Path $Root 'THIRD-PARTY-NOTICES.md') $Staging
    if (Test-Path $Target) { Remove-Item $Target -Recurse -Force }
    Move-Item $Staging $Target
    Write-Host "Verified media tools installed in $Target" -ForegroundColor Green
    Write-Host 'Run Build.cmd next. Review upstream licence terms before redistributing binaries.'
} finally {
    if (Test-Path $Temp) { Remove-Item $Temp -Recurse -Force }
}
