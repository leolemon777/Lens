#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateRange(2, 600)]
    [int]$DurationSeconds = 10,
    [Parameter(Mandatory = $true)]
    [string]$DataRoot,
    [string]$MediaPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:AV_LOG_FORCE_NOCOLOR = '1'

$root = [System.IO.Path]::GetFullPath($DataRoot)
New-Item -ItemType Directory -Force -Path $root | Out-Null
$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$ffprobe = (Get-Command ffprobe -ErrorAction Stop).Source
$fixture = if ($MediaPath) { [System.IO.Path]::GetFullPath($MediaPath) } else { Join-Path $root 'av-sync-fixture.mp4' }

function Invoke-Ffmpeg([string[]]$Arguments) {
    $output = & $ffmpeg @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg failed ($LASTEXITCODE): $($output | Select-Object -Last 8 | Out-String)"
    }
    return @($output | ForEach-Object { $_.ToString() })
}

if (-not $MediaPath) {
    $audioExpr = "aevalsrc=if(lt(mod(t\,1)\,0.05)\,0.9\,0):s=48000:d=$DurationSeconds"
    Invoke-Ffmpeg @(
        '-hide_banner', '-y',
        '-f', 'lavfi', '-i', "color=c=black:s=320x180:r=60:d=$DurationSeconds",
        '-f', 'lavfi', '-i', $audioExpr,
        '-vf', "drawbox=x=0:y=0:w=320:h=180:color=white:t=fill:enable='lt(mod(t,1),0.05)'",
        '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-shortest', $fixture
    ) | Out-Null
}

if (-not (Test-Path -LiteralPath $fixture)) { throw "Media fixture not found: $fixture" }

$videoLines = Invoke-Ffmpeg @('-hide_banner', '-i', $fixture, '-vf', 'signalstats,metadata=print', '-an', '-f', 'null', 'NUL')
$videoPulses = [System.Collections.Generic.List[double]]::new()
$videoTime = $null
foreach ($line in $videoLines) {
    if ($line -match 'pts_time:([0-9.]+)') { $videoTime = [double]$Matches[1] }
    if ($line -match 'lavfi\.signalstats\.YAVG=([0-9.]+)' -and $videoTime -ne $null -and [double]$Matches[1] -gt 100) {
        $videoPulses.Add($videoTime)
    }
}

$audioLines = Invoke-Ffmpeg @('-hide_banner', '-i', $fixture, '-vn', '-af', 'astats=metadata=1:reset=1,ametadata=print', '-f', 'null', 'NUL')
$audioPulses = [System.Collections.Generic.List[double]]::new()
$audioTime = $null
foreach ($line in $audioLines) {
    if ($line -match 'pts_time:([0-9.]+)') { $audioTime = [double]$Matches[1] }
    if ($line -match 'lavfi\.astats\.Overall\.RMS_level=(-?(?:\d+(?:\.\d+)?))' -and $audioTime -ne $null) {
        $level = [double]$Matches[1]
        if ($level -gt -20) { $audioPulses.Add($audioTime) }
    }
}

function Collapse-Pulses([double[]]$Times, [double]$Gap = 0.2) {
    $result = [System.Collections.Generic.List[double]]::new()
    foreach ($time in $Times) {
        if ($result.Count -eq 0 -or $time - $result[$result.Count - 1] -gt $Gap) { $result.Add($time) }
    }
    return @($result)
}

$videoEvents = Collapse-Pulses $videoPulses
$audioEvents = Collapse-Pulses $audioPulses
if ($videoEvents.Count -eq 0 -or $audioEvents.Count -eq 0) { throw 'Could not detect both video flashes and audio pulses.' }
$pairs = [Math]::Min($videoEvents.Count, $audioEvents.Count)
$deltas = for ($i = 0; $i -lt $pairs; $i++) { [Math]::Abs($videoEvents[$i] - $audioEvents[$i]) * 1000.0 }
$report = [ordered]@{
    media = $fixture
    videoPulseCount = $videoEvents.Count
    audioPulseCount = $audioEvents.Count
    pairedPulseCount = $pairs
    maxAbsoluteDeltaMilliseconds = if ($deltas) { ($deltas | Measure-Object -Maximum).Maximum } else { $null }
    pulsePairs = @(for ($i = 0; $i -lt $pairs; $i++) { [ordered]@{ videoSeconds = $videoEvents[$i]; audioSeconds = $audioEvents[$i]; absoluteDeltaMilliseconds = $deltas[$i] } })
}
$reportPath = Join-Path $root 'av-sync-report.json'
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding utf8NoBOM
Write-Host "A/V fixture report: $reportPath"
if ($report.videoPulseCount -ne $report.audioPulseCount -or $report.maxAbsoluteDeltaMilliseconds -gt 30) { exit 1 }
exit 0
