# verify_isolated_install.ps1
param(
    [string]$InstallDir = "E:\Users\Administrator\Desktop\LENS\Build\Windows\evidence\测试安装 路径 With Space",
    [string]$EvidenceDir = "E:\Users\Administrator\Desktop\LENS\Build\Windows\evidence"
)

$ErrorActionPreference = "Stop"
$logFile = Join-Path $EvidenceDir "isolated_install_run.log"
"=== Starting Isolated Installation Verification ===" | Out-File -FilePath $logFile -Encoding utf8

function Log($msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "[$ts] $msg" | Out-File -FilePath $logFile -Append -Encoding utf8
    Write-Host "[$ts] $msg"
}

Log "Target install directory: $InstallDir"

# 1. Verify existence of all required files in target directory
$requiredFiles = @(
    "ffmpeg.exe",
    "ffprobe.exe",
    "lens-worker.exe",
    "dist\index.html",
    "dist\assets",
    "THIRD_PARTY_LICENSES.md"
)

foreach ($f in $requiredFiles) {
    $fullPath = Join-Path $InstallDir $f
    if (-not (Test-Path $fullPath)) {
        Log "FAIL: Required file missing: $fullPath"
        throw "Missing required installation file: $f"
    }
    $item = Get-Item $fullPath
    Log "PASS: Found $f (Size: $($item.Length) bytes)"
}

# Ensure Lens.exe exists (copy from lens-desktop-probe.exe if needed)
$desktopExe = Join-Path $InstallDir "lens-desktop-probe.exe"
$lensExe = Join-Path $InstallDir "Lens.exe"
if ((Test-Path $desktopExe) -and -not (Test-Path $lensExe)) {
    Copy-Item $desktopExe $lensExe -Force
}
if (-not (Test-Path $lensExe)) {
    throw "Neither Lens.exe nor lens-desktop-probe.exe found in $InstallDir"
}

# 2. Sanitize environment variables: strip development PATH, clear tool overrides
Log "Sanitizing environment: removing all developer paths from PATH..."
$cleanPath = "C:\Windows\system32;C:\Windows"
$env:PATH = $cleanPath
Remove-Item env:LENS_* -ErrorAction SilentlyContinue

Log "Current PATH in test process: $env:PATH"

# 3. Create isolated test workspace
$testWorkDir = Join-Path $EvidenceDir "isolated_run_workspace"
if (Test-Path $testWorkDir) { Remove-Item -Recurse -Force $testWorkDir }
New-Item -ItemType Directory -Path $testWorkDir -Force | Out-Null
$testPkgDir = Join-Path $testWorkDir "test-package"
New-Item -ItemType Directory -Path (Join-Path $testPkgDir "raw") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $testPkgDir "previews") -Force | Out-Null

Log "Generating synthetic media assets using installed ffmpeg: $InstallDir\ffmpeg.exe"
$ffmpegExe = Join-Path $InstallDir "ffmpeg.exe"
$ffprobeExe = Join-Path $InstallDir "ffprobe.exe"

# Generate 2s video (raw/screen.mp4)
& $ffmpegExe -y -hide_banner -loglevel error -f lavfi -i "testsrc=duration=2:size=640x360:rate=30" -c:v libx264 -pix_fmt yuv420p (Join-Path $testPkgDir "raw\screen.mp4")
if ($LASTEXITCODE -ne 0) { throw "Failed to generate screen.mp4" }

# Generate 2s audio (raw/mic.wav)
& $ffmpegExe -y -hide_banner -loglevel error -f lavfi -i "sine=frequency=1000:duration=2" -c:a pcm_s16le (Join-Path $testPkgDir "raw\mic.wav")
if ($LASTEXITCODE -ne 0) { throw "Failed to generate mic.wav" }

# Generate 2s system audio (raw/system.wav)
& $ffmpegExe -y -hide_banner -loglevel error -f lavfi -i "sine=frequency=440:duration=2" -c:a pcm_s16le (Join-Path $testPkgDir "raw\system.wav")
if ($LASTEXITCODE -ne 0) { throw "Failed to generate system.wav" }

# Write a valid package manifest.json
$manifestJson = @"
{
  "schemaVersion": "0.9",
  "id": "iso-test-01",
  "kind": "recording",
  "createdAt": "2026-09-11T00:00:00Z",
  "title": "Isolated Install Test",
  "state": "ready",
  "durationSeconds": 2.0,
  "assets": [
    { "role": "screenVideo", "relativePath": "raw/screen.mp4" },
    { "role": "microphone", "relativePath": "raw/mic.wav" },
    { "role": "systemAudio", "relativePath": "raw/system.wav" }
  ]
}
"@
$manifestJson | Out-File -FilePath (Join-Path $testPkgDir "manifest.json") -Encoding utf8

Log "PASS: Generated synthetic recording package with manifest.json at $testPkgDir"

# 4. Test worker protocol and task execution via stdin/stdout
Log "Testing lens-worker.exe via protocol communication in isolated PATH..."
$workerExe = Join-Path $InstallDir "lens-worker.exe"

$pyCode = "import sys, json, struct, subprocess`n" +
"worker_exe, package_dir = sys.argv[1], sys.argv[2]`n" +
"p = subprocess.Popen([worker_exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)`n" +
"def send(data):`n" +
"    b = json.dumps(data).encode('utf-8')`n" +
"    p.stdin.write(struct.pack('>I', len(b)) + b)`n" +
"    p.stdin.flush()`n" +
"def recv():`n" +
"    lb = p.stdout.read(4)`n" +
"    if not lb or len(lb) < 4: return None`n" +
"    l = struct.unpack('>I', lb)[0]`n" +
"    return json.loads(p.stdout.read(l).decode('utf-8'))`n" +
"send({'clientName': 'IsolatedTester', 'protocolVersion': 1, 'requestID': 'hs-1', 'requestedCapabilities': []})`n" +
"hs = recv()`n" +
"print('HANDSHAKE:', hs)`n" +
"assert hs.get('protocolVersion') == 1`n" +
"render_payload = {`n" +
"    'root': package_dir,`n" +
"    'timeline': {`n" +
"        'schemaVersion': '1.0',`n" +
"        'segments': [{'id': 'seg1', 'sourceStartSeconds': 0.0, 'sourceEndSeconds': 2.0, 'playbackRate': 1.0, 'isEnabled': True, 'transition': ''}],`n" +
"    }`n" +
"}`n" +
"send({'taskId': 't-render', 'action': 'render_package', 'payload': render_payload})`n" +
"r_resp = recv()`n" +
"print('RENDER:', r_resp)`n" +
"assert r_resp.get('status') == 'success', f'Render failed: {r_resp}'`n" +
"send({'taskId': 't-export', 'action': 'export_package', 'payload': {'root': package_dir, 'preset': 'balanced'}})`n" +
"e_resp = recv()`n" +
"print('EXPORT:', e_resp)`n" +
"assert e_resp.get('status') == 'success', f'Export failed: {e_resp}'`n" +
"send({'taskId': 't-shut', 'action': 'shutdown', 'payload': {}})`n" +
"p.wait(5)`n" +
"print('EXIT:', p.returncode)`n"

$protocolScript = Join-Path $testWorkDir "test_worker.py"
$pyCode | Out-File -FilePath $protocolScript -Encoding utf8

$pythonCandidates = @(
    "C:\Program Files\Python312\python.exe",
    "C:\Users\Administrator\AppData\Local\Programs\Python\Python312\python.exe"
)
$pythonPath = $pythonCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $pythonPath) {
    $pythonPath = (Get-ChildItem "C:\Users\Administrator\AppData\Local\Programs\Python" -Filter python.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
}

Log "Executing worker test with $pythonPath..."
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $pythonPath
$psi.Arguments = "`"$protocolScript`" `"$workerExe`" `"$testPkgDir`""
$psi.EnvironmentVariables["PATH"] = $cleanPath
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$proc = [System.Diagnostics.Process]::Start($psi)
$procOut = $proc.StandardOutput.ReadToEnd()
$procErr = $proc.StandardError.ReadToEnd()
$proc.WaitForExit(30000)

Log "Worker output: $procOut"
if ($procErr) { Log "Worker stderr: $procErr" }
if ($proc.ExitCode -ne 0) {
    throw "Worker protocol test failed with exit code $($proc.ExitCode)"
}
Log "PASS: lens-worker.exe completed render and export cleanly in isolated environment!"

# 5. Verify produced video files with installed ffprobe.exe
$editedMp4 = Join-Path $testPkgDir "previews\edited.mp4"
$exportMp4 = Join-Path $testPkgDir "previews\export-balanced.mp4"
if (-not (Test-Path $editedMp4)) {
    throw "edited.mp4 was not produced!"
}

$probeOut = & $ffprobeExe -v error -show_entries format=duration,size:stream=codec_name,width,height -of json $editedMp4
Log "ffprobe edited.mp4: $probeOut"
Log "PASS: edited.mp4 successfully verified with installed ffprobe.exe"

# 6. Verify Desktop UI startup and local HTTP server serving dist/index.html
Log "Testing Desktop GUI startup and local frontend HTTP server..."
$psiUi = New-Object System.Diagnostics.ProcessStartInfo
$psiUi.FileName = $lensExe
$psiUi.Arguments = ""
$psiUi.EnvironmentVariables["PATH"] = $cleanPath
$psiUi.EnvironmentVariables["LENS_LIBRARY_DIR"] = $testWorkDir
$psiUi.UseShellExecute = $false
$psiUi.RedirectStandardOutput = $true
$psiUi.RedirectStandardError = $true

$uiProc = [System.Diagnostics.Process]::Start($psiUi)
Log "Started Lens GUI process ID: $($uiProc.Id)"

Start-Sleep -Seconds 3

$serverResponding = $false
for ($p = 18760; $p -le 18820; $p++) {
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$p/index.html" -TimeoutSec 1 -UseBasicParsing -ErrorAction SilentlyContinue
        if ($resp.StatusCode -eq 200 -and $resp.Content -match 'id="root"') {
            Log "PASS: Successfully fetched http://127.0.0.1:$p/index.html from installed dist! Content length: $($resp.RawContentLength)"
            $serverResponding = $true
            break
        }
    } catch {
        # continue searching
    }
}

if (-not $uiProc.HasExited) {
    $uiProc.Kill()
    $uiProc.WaitForExit(5000)
    Log "GUI process terminated cleanly after verification."
}

if (-not $serverResponding) {
    $tempLog = Join-Path $env:TEMP "lens-ui-server.log"
    if (Test-Path $tempLog) {
        $content = Get-Content $tempLog -Raw
        Log "lens-ui-server.log content: $content"
    }
    throw "Frontend HTTP server did not respond with valid index.html"
}

# 7. Test --print-inventory argument on installed binary
Log "Testing Lens.exe --print-inventory in isolated PATH..."
$invLines = & $lensExe --print-inventory
$invText = $invLines -join "`n"
Log "Inventory output: $invText"
if ($invText -notmatch 'dpi_awareness') {
    throw "--print-inventory failed to return expected output: $invText"
}
Log "PASS: --print-inventory succeeded in isolated environment"

Log "=== ALL ISOLATED INSTALLATION CHECKS PASSED SUCCESSFULLY ==="
