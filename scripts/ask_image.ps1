param(
    [Parameter(Mandatory)][string]$ImagePath,
    [Parameter(Mandatory)][string]$Prompt,
    [int]$Port = 8080,
    [int]$MaxTokens = 256
)

$ErrorActionPreference = 'Stop'
$resolvedImage = (Resolve-Path -LiteralPath $ImagePath).Path
$extension = [IO.Path]::GetExtension($resolvedImage).ToLowerInvariant()
$mime = if ($extension -in @('.jpg', '.jpeg')) { 'image/jpeg' } elseif ($extension -eq '.png') { 'image/png' } else { throw 'Only JPG/JPEG/PNG images are supported by this helper.' }
$encoded = [Convert]::ToBase64String([IO.File]::ReadAllBytes($resolvedImage))

$payload = [ordered]@{
    model = 'qwen3-vl-2b'
    messages = @([ordered]@{
        role = 'user'
        content = @(
            [ordered]@{ type = 'image_url'; image_url = @{ url = "data:$mime;base64,$encoded" } },
            [ordered]@{ type = 'text'; text = $Prompt }
        )
    })
    temperature = 0.2
    max_tokens = $MaxTokens
    stream = $false
}
$body = $payload | ConvertTo-Json -Depth 12 -Compress
$response = Invoke-RestMethod `
    -Method Post `
    -Uri "http://127.0.0.1:$Port/v1/chat/completions" `
    -ContentType 'application/json; charset=utf-8' `
    -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
    -TimeoutSec 180

$response.choices[0].message.content

