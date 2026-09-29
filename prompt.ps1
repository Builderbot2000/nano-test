#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Send a prompt to the on-device Gemini Nano (via the Nano Test app) and print the reply.

.EXAMPLE
  .\prompt.ps1 -Status
  .\prompt.ps1 -Download -Preference fast
  .\prompt.ps1 "Write a haiku about USB cables"
  .\prompt.ps1 "List 3 colors" -Temperature 0.2 -MaxTokens 64 -Json
  .\prompt.ps1 "I loved it" -System "Be strict." -Schema sentiment
  .\prompt.ps1 "Name a fruit" -JsonSchema '{"type":"object","properties":{"fruit":{"type":"string"}}}'

.NOTES
  Runs on Windows PowerShell 5.1 and on PowerShell 7+ (pwsh) on Windows, Linux and macOS.
  On Linux/macOS, call it as ./prompt.ps1 (or: pwsh ./prompt.ps1).
#>
param(
    [Parameter(Position = 0)] [string] $Prompt,
    [switch] $Status,
    [switch] $Download,
    [switch] $Json,
    [string] $System,
    [string] $Schema,       # structured output: a schema compiled into the app (Schemas.kt); enforced
    [string] $JsonSchema,   # ad-hoc JSON Schema (text or file path): added to the prompt, not enforced
    [string] $Serial = $env:NANO_SERIAL,
    [ValidateSet('stable', 'preview')] [string] $Stage,
    [ValidateSet('full', 'fast')] [string] $Preference,
    [Nullable[double]] $Temperature,
    [Nullable[int]] $TopK,
    [Nullable[int]] $Seed,
    [Nullable[int]] $MaxTokens,
    [int] $TimeoutSec = 0
)

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$pkg = 'com.example.nanotest'

if (-not $Status -and -not $Download -and -not $Prompt) { throw 'Give a prompt, or use -Status / -Download.' }
if ($Schema -and $JsonSchema) { throw 'Use -Schema or -JsonSchema, not both.' }
if ($TimeoutSec -le 0) { $TimeoutSec = if ($Download) { 3600 } else { 120 } }

# adb: from PATH, else the platform-tools of the Android SDK (ANDROID_HOME, or Android Studio's default location).
$adb = (Get-Command adb -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Path
if (-not $adb) {
    $sdks = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)
    if ($env:LOCALAPPDATA) { $sdks += Join-Path $env:LOCALAPPDATA 'Android/Sdk' }       # Windows
    if ($HOME) { $sdks += (Join-Path $HOME 'Library/Android/sdk'), (Join-Path $HOME 'Android/Sdk') }  # macOS, Linux
    $adb = $sdks | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'platform-tools' } |
        ForEach-Object { Join-Path $_ 'adb.exe'; Join-Path $_ 'adb' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $adb) { throw 'adb not found. Put Android SDK platform-tools on PATH, or set ANDROID_HOME.' }
}

if (-not $Serial) {
    # Prefer an ip:port entry; the mDNS alias for the same phone also shows up in the list.
    $devices = & $adb devices | Select-String '^(\S+)\s+device$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
    $Serial = ($devices | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+:\d+$' } | Select-Object -First 1)
    if (-not $Serial) { $Serial = $devices | Select-Object -First 1 }
    if (-not $Serial) { throw 'No adb device connected.' }
}
function Invoke-Adb { & $adb -s $Serial @args }

function ConvertTo-Base64([string] $text) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)) }

$id = [guid]::NewGuid().ToString('N').Substring(0, 12)
$extras = @('--es', 'id', $id)
if ($Status) {
    $extras += @('--es', 'mode', 'status')
} elseif ($Download) {
    $extras += @('--es', 'mode', 'download')
} else {
    if ($JsonSchema) {
        if (Test-Path -LiteralPath $JsonSchema -PathType Leaf) { $JsonSchema = Get-Content -LiteralPath $JsonSchema -Raw -Encoding UTF8 }
        $Prompt += "`n`nRespond with only a JSON value that conforms to this JSON Schema, and no other text:`n$JsonSchema"
    }
    $extras += @('--es', 'mode', 'prompt', '--es', 'prompt_b64', (ConvertTo-Base64 $Prompt))
    if ($System) { $extras += @('--es', 'system_b64', (ConvertTo-Base64 $System)) }
    if ($Schema) { $extras += @('--es', 'schema', $Schema) }
}
if ($Stage)                 { $extras += @('--es', 'stage', $Stage) }
if ($Preference)            { $extras += @('--es', 'preference', $Preference) }
if ($null -ne $Temperature) { $extras += @('--es', 'temperature', $Temperature.ToString([Globalization.CultureInfo]::InvariantCulture)) }
if ($null -ne $TopK)        { $extras += @('--es', 'top_k', "$TopK") }
if ($null -ne $Seed)        { $extras += @('--es', 'seed', "$Seed") }
if ($null -ne $MaxTokens)   { $extras += @('--es', 'max_tokens', "$MaxTokens") }

Invoke-Adb shell input keyevent KEYCODE_WAKEUP | Out-Null
Invoke-Adb shell am start -n "$pkg/.PromptActivity" @extras | Out-Null

$file = "files/results/$id.json"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$raw = $null
while ((Get-Date) -lt $deadline) {
    $raw = Invoke-Adb shell run-as $pkg cat $file 2>$null
    if ($LASTEXITCODE -eq 0 -and $raw) { break }
    $raw = $null
    if ($Download) {
        $p = Invoke-Adb shell run-as $pkg cat "files/results/$id.progress" 2>$null
        if ($LASTEXITCODE -eq 0 -and $p) {
            $p = ($p -join '') | ConvertFrom-Json
            $pct = if ($p.total -gt 0) { [math]::Min(100, [int](100 * $p.downloaded / $p.total)) } else { 0 }
            Write-Progress -Activity 'Downloading Gemini Nano' -Status ('{0:N0} / {1:N0} MB' -f ($p.downloaded / 1MB), ($p.total / 1MB)) -PercentComplete $pct
        }
        Start-Sleep -Seconds 2
    } else {
        Start-Sleep -Milliseconds 300
    }
}
if ($Download) { Write-Progress -Activity 'Downloading Gemini Nano' -Completed }
if (-not $raw) { throw "No result after $TimeoutSec s (check: adb logcat -s NanoTest)" }
Invoke-Adb shell run-as $pkg rm -f $file "files/results/$id.progress" | Out-Null

$raw = $raw -join "`n"
$result = $raw | ConvertFrom-Json
if ($JsonSchema -and $result.ok) {
    # The model often wraps JSON in a Markdown code fence; keep just the JSON.
    $result.text = $result.text -replace '^\s*```(?:json)?\s*([\s\S]*?)\s*```\s*$', '$1'
}
if ($Json -or $Status -or $Download) {
    $result | ConvertTo-Json -Depth 5
} elseif ($result.ok) {
    $result.text
} else {
    Write-Error "[$($result.status)] $($result.error) (code $($result.error_code))"
}
