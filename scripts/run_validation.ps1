param(
    [string]$BaseUrl = 'http://127.0.0.1:8080'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$imageDir = Join-Path $root 'tests\images'
$resultDir = Join-Path $root 'tests\results'
New-Item -ItemType Directory -Force -Path $resultDir | Out-Null

function ConvertFrom-Utf8Base64 {
    param([Parameter(Mandatory)][string]$Value)
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

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
        PromptTokens = [int]$response.usage.prompt_tokens
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

$spatialPrompt = ConvertFrom-Utf8Base64 '7J2066+47KeA7J2YIOyZvOyqvSDsnIQsIOyYpOuluOyqvSDsnIQsIOyZvOyqvSDslYTrnpgsIOyYpOuluOyqvSDslYTrnpjsl5Ag7J6I64qUIO2BsCDrj4TtmJXsnZgg7IOJ6rO8IOuqqOyWkeydhCDtlZzqta3slrTroZwg7ISk66qF7ZWY6rOgLCDqsoDsnYAg7KCQ7J20IOyWtOuKkCDrj4TtmJUg7JWI7JeQIOyeiOuKlOyngOuPhCDrp5DtlZjshLjsmpQu'
$ocrPrompt = ConvertFrom-Utf8Base64 '7J2066+47KeA7JeQ7IScIOuLpOyEryDtlYTrk5zrpbwg6re464yA66GcIOydveqzoCBKU09OIOqwneyytOuhnCDstpzroKXtlZjshLjsmpQuIOyYqOuPhOuKlCA2M8KwQyDtmJXsi53snLzroZwg67O07KG07ZWY7IS47JqULg=='
$naturalPrompt = ConvertFrom-Utf8Base64 '7J6l7IaMLCDrk7HsnqUg64yA7IOBLCDtlonrj5nsnYQg7Y+s7ZWo7ZWY7JesIOydtCDsgqzsp4TsnYQg7J6Q7Jew7Iqk65+s7Jq0IO2VnOq1reyWtCDtlZwg66y47J6l7Jy866GcIOyEpOuqhe2VmOyEuOyalC4='

$spatialExpected = @(
    (ConvertFrom-Utf8Base64 '67mo6rCE7IOJIOybkA=='),
    (ConvertFrom-Utf8Base64 '7YyM656A7IOJIOyCrOqwge2YlQ=='),
    (ConvertFrom-Utf8Base64 '64W57IOJIOyCvOqwge2YlQ=='),
    (ConvertFrom-Utf8Base64 '64W4656A7IOJIOuzhA=='),
    (ConvertFrom-Utf8Base64 '7YyM656A7IOJIOyCrOqwge2YlSDslYg=')
)

$ocrKeys = [ordered]@{
    Name = ConvertFrom-Utf8Base64 '7J6l67mE66qF'
    Date = ConvertFrom-Utf8Base64 '7KCQ6rKA7J28'
    Temperature = ConvertFrom-Utf8Base64 '7Jio64+E'
    Status = ConvertFrom-Utf8Base64 '7IOB7YOc'
    AssetId = ConvertFrom-Utf8Base64 '6rSA66as67KI7Zi4'
}
$ocrExpected = [ordered]@{
    Name = 'RTX 2080 SUPER'
    Date = '2026-07-14'
    Temperature = ConvertFrom-Utf8Base64 'NjPCsEM='
    Status = ConvertFrom-Utf8Base64 '7KCV7IOB'
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
        if ([string]$parsed.($ocrKeys.Name) -ne $ocrExpected.Name) { $passed = $false }
        if ([string]$parsed.($ocrKeys.Date) -ne $ocrExpected.Date) { $passed = $false }
        if ([string]$parsed.($ocrKeys.Temperature) -ne $ocrExpected.Temperature) { $passed = $false }
        if ([string]$parsed.($ocrKeys.Status) -ne $ocrExpected.Status) { $passed = $false }
        if ([string]$parsed.($ocrKeys.AssetId) -ne $ocrExpected.AssetId) { $passed = $false }
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
$naturalPassed = $natural.Content.Contains((ConvertFrom-Utf8Base64 '7ZW067OA')) -and
    $natural.Content.Contains((ConvertFrom-Utf8Base64 '7Jes7ISx')) -and
    ($natural.Content.Contains((ConvertFrom-Utf8Base64 '6rCV7JWE7KeA')) -or $natural.Content.Contains((ConvertFrom-Utf8Base64 '6rCc')))
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
