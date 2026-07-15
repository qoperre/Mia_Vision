param(
    [ValidateSet('game1', 'game2', 'all')][string]$Game = 'all',
    [int]$Seed = 20260714,
    [switch]$Headed,
    [int]$Game2Target = 21,
    [double]$Game2Timeout = 75
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

try {
    $health = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/health' -TimeoutSec 3
} catch {
    & (Join-Path $PSScriptRoot 'start_server.ps1')
    $health = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/health' -TimeoutSec 5
}
if ($health.status -ne 'ok') { throw 'Qwen server is not ready.' }

$arguments = @(
    (Join-Path $root 'agents\vision_game_agent.py'),
    $Game,
    '--seed', [string]$Seed,
    '--game2-target', [string]$Game2Target,
    '--game2-timeout', [string]$Game2Timeout
)
if ($Headed) { $arguments += '--headed' }

& python @arguments
exit $LASTEXITCODE

