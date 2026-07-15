param([int]$Port = 8080)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$expectedExe = Join-Path $root 'runtime\llama.cpp-cuda\llama-server.exe'
$connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue

if (-not $connection) {
    "No server is listening on port $Port."
    exit 0
}

$process = Get-Process -Id $connection.OwningProcess -ErrorAction Stop
if ($process.Path -ne $expectedExe) {
    throw "Refusing to stop PID $($process.Id): it is not this workspace's llama-server."
}

Stop-Process -Id $process.Id -Force
"Stopped llama-server on port $Port (PID $($process.Id))."

