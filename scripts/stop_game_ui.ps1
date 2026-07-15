param([int]$Port = 8090)

$ErrorActionPreference = 'Stop'
$connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if (-not $connection) {
    "No game UI server is listening on port $Port."
    exit 0
}
$process = Get-CimInstance Win32_Process -Filter "ProcessId=$($connection.OwningProcess)"
if (-not $process -or $process.CommandLine -notmatch 'http\.server') {
    throw "Refusing to stop PID $($connection.OwningProcess): it is not the game UI server."
}
Stop-Process -Id $connection.OwningProcess -Force
"Stopped game UI server on port $Port."

