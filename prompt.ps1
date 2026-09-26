<#
.SYNOPSIS
  Send a prompt to the on-device Gemini Nano (via the Nano Test app) and print the reply.

.EXAMPLE
  .\prompt.ps1 -Status
  .\prompt.ps1 -Download -Preference fast
  .\prompt.ps1 "Write a haiku about USB cables"
  .\prompt.ps1 "List 3 colors" -Temperature 0.2 -MaxTokens 64 -Json
#>
param(
    [Parameter(Position = 0)] [string] $Prompt,
    [switch] $Status,
    [switch] $Download,
    [switch] $Json,
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
if ($TimeoutSec -le 0) { $TimeoutSec = if ($Download) { 3600 } else { 120 } }

if (-not $Serial) {
    # Prefer an ip:port entry; the mDNS alias for the same phone also shows up in the list.
    $devices = adb devices | Select-String '^(\S+)\s+device$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
    $Serial = ($devices | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+:\d+$' } | Select-Object -First 1)
    if (-not $Serial) { $Serial = $devices | Select-Object -First 1 }
    if (-not $Serial) { throw 'No adb device connected.' }
}
function Invoke-Adb { adb -s $Serial @args }

$id = [guid]::NewGuid().ToString('N').Substring(0, 12)
$extras = @('--es', 'id', $id)
if ($Status) {
    $extras += @('--es', 'mode', 'status')
} elseif ($Download) {
    $extras += @('--es', 'mode', 'download')
} else {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Prompt))
    $extras += @('--es', 'mode', 'prompt', '--es', 'prompt_b64', $b64)
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
if ($Json -or $Status -or $Download) {
    $result | ConvertTo-Json -Depth 5
} elseif ($result.ok) {
    $result.text
} else {
    Write-Error "[$($result.status)] $($result.error) (code $($result.error_code))"
}
