param([int]$Port = 8090)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$gameDir = Join-Path $root 'games'
$logDir = Join-Path $root 'tests\logs'
$stdoutLog = Join-Path $logDir 'game-ui.stdout.log'
$stderrLog = Join-Path $logDir 'game-ui.stderr.log'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$existing = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    "A server is already listening at http://127.0.0.1:$Port (PID $($existing.OwningProcess))."
    exit 0
}

Remove-Item -LiteralPath $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue
$process = Start-Process `
    -FilePath 'python' `
    -ArgumentList @('-m', 'http.server', [string]$Port, '--bind', '127.0.0.1') `
    -WorkingDirectory $gameDir `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog `
    -WindowStyle Hidden `
    -PassThru

$ready = $false
for ($attempt = 0; $attempt -lt 40; $attempt++) {
    if ($process.HasExited) { break }
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 1
        if ($response.StatusCode -eq 200) { $ready = $true; break }
    } catch {
        Start-Sleep -Milliseconds 250
    }
}
if (-not $ready) { throw "Game UI server did not become ready. See $stderrLog" }

"Game UI is ready: http://127.0.0.1:$Port (PID $($process.Id))"

