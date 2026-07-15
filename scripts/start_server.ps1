param(
    [int]$Port = 8080,
    [int]$ContextSize = 4096,
    [int]$ImageMinTokens = 1024,
    [int]$ImageMaxTokens = 1024
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$runtimeDir = Join-Path $root 'runtime\llama.cpp-cuda'
$serverExe = Join-Path $runtimeDir 'llama-server.exe'
$model = Join-Path $root 'models\Qwen3VL-2B-Instruct-Q4_K_M.gguf'
$projector = Join-Path $root 'models\mmproj-Qwen3VL-2B-Instruct-F16.gguf'
$logDir = Join-Path $root 'tests\logs'
$stdoutLog = Join-Path $logDir 'server.stdout.log'
$stderrLog = Join-Path $logDir 'server.stderr.log'

foreach ($required in @($serverExe, $model, $projector)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required file is missing: $required"
    }
}
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$existing = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    $process = Get-Process -Id $existing.OwningProcess -ErrorAction SilentlyContinue
    if ($process -and $process.Path -eq $serverExe) {
        "Server is already running: http://127.0.0.1:$Port (PID $($process.Id))"
        exit 0
    }
    throw "Port $Port is already used by PID $($existing.OwningProcess)"
}

Remove-Item -LiteralPath $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue
$arguments = @(
    '-m', $model,
    '--mmproj', $projector,
    '-ngl', 'all',
    '-c', [string]$ContextSize,
    '-np', '1',
    '-fa', 'on',
    '--image-min-tokens', [string]$ImageMinTokens,
    '--image-max-tokens', [string]$ImageMaxTokens,
    '-lv', '4',
    '--host', '127.0.0.1',
    '--port', [string]$Port,
    '--metrics'
)

$process = Start-Process `
    -FilePath $serverExe `
    -ArgumentList $arguments `
    -WorkingDirectory $runtimeDir `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog `
    -WindowStyle Hidden `
    -PassThru

$ready = $false
for ($attempt = 0; $attempt -lt 120; $attempt++) {
    if ($process.HasExited) { break }
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 1
        if ($health.status -eq 'ok') {
            $ready = $true
            break
        }
    } catch {
        Start-Sleep -Milliseconds 500
    }
}

if (-not $ready) {
    $tail = Get-Content -LiteralPath $stderrLog -Tail 80 -ErrorAction SilentlyContinue
    throw "Server did not become ready.`n$($tail -join [Environment]::NewLine)"
}

[pscustomobject]@{
    Status = 'ready'
    Url = "http://127.0.0.1:$Port"
    ProcessId = $process.Id
    Model = [IO.Path]::GetFileName($model)
    StdoutLog = $stdoutLog
    StderrLog = $stderrLog
} | Format-List
