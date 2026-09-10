param([int]$Port = 8090)

$ErrorActionPreference = 'Stop'
$connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if (-not $connection) {
    "No game UI server is listening on port $Port."
    exit 0
}
$process = Get-CimInstance Win32_Process -Filter "ProcessId=$($connection.OwningProcess)"
# 런처가 쓰는 인자 형태(http.server <포트>)까지 확인해서 무관한 http.server 프로세스를 죽이지 않도록 한다.
if (-not $process -or $process.CommandLine -notmatch "http\.server\s+$Port\b") {
    throw "Refusing to stop PID $($connection.OwningProcess): it is not the game UI server."
}
Stop-Process -Id $connection.OwningProcess -Force
"Stopped game UI server on port $Port."

