param(
    [string]$BaseUrl = 'http://127.0.0.1:8080'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$imageDir = Join-Path $root 'tests\images'
$resultDir = Join-Path $root 'tests\results'
New-Item -ItemType Directory -Force -Path $resultDir | Out-Null

function Invoke-ChatRequest {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$ImagePath,
        [int]$MaxTokens = 160,
        [object]$JsonSchema
    )

    $content = @()
    if ($ImagePath) {
        $extension = [IO.Path]::GetExtension($ImagePath).ToLowerInvariant()
        $mime = if ($extension -in @('.jpg', '.jpeg')) { 'image/jpeg' } else { 'image/png' }
        $encoded = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ImagePath))
        $content += [ordered]@{
            type = 'image_url'
            image_url = @{ url = "data:$mime;base64,$encoded" }
        }
    }
    $content += [ordered]@{ type = 'text'; text = $Prompt }

    $payload = [ordered]@{
        model = 'qwen3-vl-2b'
        messages = @([ordered]@{ role = 'user'; content = $content })
        temperature = 0
        seed = 42
        max_tokens = $MaxTokens
        stream = $false
    }
    if ($null -ne $JsonSchema) {
        # llama.cpp-specific parameter; reliable with multimodal requests in b9996.
        $payload['json_schema'] = $JsonSchema
    }

    $body = $payload | ConvertTo-Json -Depth 20 -Compress
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-RestMethod `
        -Method Post `
        -Uri "$BaseUrl/v1/chat/completions" `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
        -TimeoutSec 180
    $watch.Stop()

    return [pscustomobject]@{
        Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 4)
        Content = [string]$response.choices[0].message.content
        CompletionTokens = [int]$response.usage.completion_tokens
    }
}

function Get-Median {
    param([double[]]$Values)
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return 0 }
    $middle = [int][math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) { return $sorted[$middle] }
    return ($sorted[$middle - 1] + $sorted[$middle]) / 2
}

$spatialPrompt = '이미지의 왼쪽 위, 오른쪽 위, 왼쪽 아래, 오른쪽 아래에 있는 큰 도형의 색과 모양을 한국어로 설명하고, 검은 점이 어느 도형 안에 있는지도 말하세요.'
$ocrPrompt = '이미지에서 다섯 필드를 그대로 읽고 JSON 객체로 출력하세요. 온도는 63°C 형식으로 보존하세요.'
$naturalPrompt = '장소, 등장 대상, 행동을 포함하여 이 사진을 자연스러운 한국어 한 문장으로 설명하세요.'

$spatialExpected = @(
    '빨간색 원',
    '파란색 사각형',
    '녹색 삼각형',
    '노란색 별',
    '파란색 사각형 안'
)

$ocrKeys = [ordered]@{
    Name = '장비명'
    Date = '점검일'
    Temperature = '온도'
    Status = '상태'
    AssetId = '관리번호'
}
$ocrExpected = [ordered]@{
    Name = 'RTX 2080 SUPER'
    Date = '2026-07-14'
    Temperature = '63°C'
    Status = '정상'
    AssetId = 'MV-2080S-0714'
}

$ocrProperties = [ordered]@{}
foreach ($key in $ocrKeys.Values) { $ocrProperties[$key] = @{ type = 'string' } }
$ocrSchema = @{
    type = 'object'
    properties = $ocrProperties
    required = @($ocrKeys.Values)
    additionalProperties = $false
}

$results = [Collections.Generic.List[object]]::new()

# Health check.
$healthWatch = [Diagnostics.Stopwatch]::StartNew()
$health = Invoke-RestMethod -Uri "$BaseUrl/health" -TimeoutSec 10
$healthWatch.Stop()
$results.Add([pscustomobject]@{
    Test = 'health'
    Passed = ($health.status -eq 'ok')
    Runs = 1
    MedianSeconds = [math]::Round($healthWatch.Elapsed.TotalSeconds, 4)
    Detail = [string]$health.status
})

# Spatial and Korean response quality, three deterministic runs.
$spatialRuns = @()
for ($i = 0; $i -lt 3; $i++) {
    $run = Invoke-ChatRequest -Prompt $spatialPrompt -ImagePath (Join-Path $imageDir 'shapes_spatial.png')
    $passed = $true
    foreach ($expected in $spatialExpected) {
        if (-not $run.Content.Contains($expected)) { $passed = $false }
    }
    $spatialRuns += [pscustomobject]@{ Passed = $passed; Run = $run }
}
$results.Add([pscustomobject]@{
    Test = 'spatial_korean'
    Passed = (($spatialRuns | Where-Object { -not $_.Passed }).Count -eq 0)
    Runs = 3
    MedianSeconds = [math]::Round((Get-Median @($spatialRuns.Run.Seconds)), 4)
    Detail = $spatialRuns[0].Run.Content
})

# OCR with a strict JSON grammar, three deterministic runs.
$ocrRuns = @()
for ($i = 0; $i -lt 3; $i++) {
    $run = Invoke-ChatRequest -Prompt $ocrPrompt -ImagePath (Join-Path $imageDir 'korean_ocr.png') -MaxTokens 128 -JsonSchema $ocrSchema
    $passed = $true
    try {
        $parsed = $run.Content | ConvertFrom-Json
        foreach ($k in $ocrKeys.Keys) {
            if ([string]$parsed.($ocrKeys[$k]) -ne $ocrExpected[$k]) { $passed = $false }
        }
    } catch {
        $passed = $false
    }
    $ocrRuns += [pscustomobject]@{ Passed = $passed; Run = $run }
}
$results.Add([pscustomobject]@{
    Test = 'korean_ocr_json'
    Passed = (($ocrRuns | Where-Object { -not $_.Passed }).Count -eq 0)
    Runs = 3
    MedianSeconds = [math]::Round((Get-Median @($ocrRuns.Run.Seconds)), 4)
    Detail = $ocrRuns[0].Run.Content
})

# A natural photograph from the official Qwen demo assets.
$natural = Invoke-ChatRequest -Prompt $naturalPrompt -ImagePath (Join-Path $imageDir 'qwen_demo.jpeg') -MaxTokens 96
$naturalPassed = $natural.Content.Contains('해변') -and
    $natural.Content.Contains('여성') -and
    ($natural.Content.Contains('강아지') -or $natural.Content.Contains('개'))
$results.Add([pscustomobject]@{
    Test = 'natural_image_korean'
    Passed = $naturalPassed
    Runs = 1
    MedianSeconds = $natural.Seconds
    Detail = $natural.Content
})

# Ten alternating multimodal requests to catch crashes, OOM, and malformed output.
$stabilityFailures = 0
$stabilitySeconds = @()
for ($i = 0; $i -lt 10; $i++) {
    try {
        if (($i % 2) -eq 0) {
            $run = Invoke-ChatRequest -Prompt $spatialPrompt -ImagePath (Join-Path $imageDir 'shapes_spatial.png') -MaxTokens 128
            $valid = $run.Content.Contains($spatialExpected[0]) -and $run.Content.Contains($spatialExpected[1])
        } else {
            $run = Invoke-ChatRequest -Prompt $ocrPrompt -ImagePath (Join-Path $imageDir 'korean_ocr.png') -MaxTokens 128 -JsonSchema $ocrSchema
            $parsed = $run.Content | ConvertFrom-Json
            $valid = ([string]$parsed.($ocrKeys.AssetId) -eq $ocrExpected.AssetId)
        }
        if (-not $valid) { $stabilityFailures++ }
        $stabilitySeconds += $run.Seconds
    } catch {
        $stabilityFailures++
    }
}
$results.Add([pscustomobject]@{
    Test = 'stability_10_requests'
    Passed = ($stabilityFailures -eq 0)
    Runs = 10
    MedianSeconds = [math]::Round((Get-Median $stabilitySeconds), 4)
    Detail = "failures=$stabilityFailures"
})

# Warm text-generation throughput. Each request should hit the 256-token cap.
$performanceRuns = @()
$performancePrompt = "Repeat the sequence 'alpha beta gamma delta epsilon' continuously until the token limit. Do not add an explanation and do not stop early."
for ($i = 0; $i -lt 5; $i++) {
    $run = Invoke-ChatRequest -Prompt $performancePrompt -MaxTokens 256
    $throughput = if ($run.Seconds -gt 0) { $run.CompletionTokens / $run.Seconds } else { 0 }
    $performanceRuns += [pscustomobject]@{
        Seconds = $run.Seconds
        CompletionTokens = $run.CompletionTokens
        EndToEndTokensPerSecond = [math]::Round($throughput, 2)
    }
}
$medianTextTps = Get-Median @($performanceRuns.EndToEndTokensPerSecond)
$results.Add([pscustomobject]@{
    Test = 'text_generation_speed'
    Passed = (($performanceRuns | Where-Object { $_.CompletionTokens -lt 250 }).Count -eq 0 -and $medianTextTps -ge 25)
    Runs = 5
    MedianSeconds = [math]::Round((Get-Median @($performanceRuns.Seconds)), 4)
    Detail = "median_end_to_end_tokens_per_second=$([math]::Round($medianTextTps, 2))"
})

$summary = [ordered]@{
    Timestamp = (Get-Date).ToString('o')
    BaseUrl = $BaseUrl
    AllPassed = (($results | Where-Object { -not $_.Passed }).Count -eq 0)
    Results = $results
    PerformanceRuns = $performanceRuns
}

$resultPath = Join-Path $resultDir 'validation.json'
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultPath -Encoding UTF8
$results | Format-Table Test, Passed, Runs, MedianSeconds, Detail -Wrap -AutoSize
"Result file: $resultPath"

if (-not $summary.AllPassed) { exit 1 }
