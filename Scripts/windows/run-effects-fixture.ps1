#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DataRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:AV_LOG_FORCE_NOCOLOR = '1'
$root = [System.IO.Path]::GetFullPath($DataRoot)
New-Item -ItemType Directory -Force -Path $root | Out-Null
$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$ffprobe = (Get-Command ffprobe -ErrorAction Stop).Source
$output = Join-Path $root 'crossfade-fixture.mp4'

& $ffmpeg -hide_banner -y `
    -f lavfi -i 'color=c=red:s=320x180:r=30:d=1' `
    -f lavfi -i 'color=c=blue:s=320x180:r=30:d=1' `
    -filter_complex '[0:v][1:v]xfade=transition=fade:duration=0.4:offset=0.6,format=yuv420p[v]' `
    -map '[v]' -c:v libx264 -preset ultrafast $output 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not render crossfade fixture ($LASTEXITCODE)." }

$probe = & $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $output
if ($LASTEXITCODE -ne 0) { throw 'Could not probe crossfade fixture.' }
$duration = [double]($probe | Select-Object -First 1)

$lines = & $ffmpeg -hide_banner -ss 0.8 -i $output -frames:v 1 -vf 'signalstats,metadata=print' -f null NUL 2>&1 |
    ForEach-Object { $_.ToString() }
$values = @{}
foreach ($line in $lines) {
    if ($line -match 'lavfi\.signalstats\.(YAVG|UAVG|VAVG)=([0-9.]+)' -and -not $values.ContainsKey($Matches[1])) {
        $values[$Matches[1]] = [double]$Matches[2]
    }
}
if ($values.Count -ne 3) { throw 'Midpoint frame did not produce Y/U/V statistics.' }

$report = [ordered]@{
    output = $output
    durationSeconds = $duration
    midpointSeconds = 0.8
    midpointY = $values.YAVG
    midpointU = $values.UAVG
    midpointV = $values.VAVG
    assertion = 'red-blue crossfade midpoint is neither source color'
}
$reportPath = Join-Path $root 'effects-fixture-report.json'
$report | ConvertTo-Json | Set-Content -LiteralPath $reportPath -Encoding utf8NoBOM
Write-Host "Effects fixture report: $reportPath"

if ([Math]::Abs($duration - 1.6) -gt 0.05 -or
    $values.YAVG -lt 45 -or $values.YAVG -gt 75 -or
    $values.UAVG -lt 145 -or $values.UAVG -gt 190 -or
    $values.VAVG -lt 145 -or $values.VAVG -gt 195) { exit 1 }
exit 0
