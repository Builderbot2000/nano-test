# Research notes

Findings from setting this up (September 2026).

## Ways to reach Gemini Nano on Android

| Approach | Uses real Nano? | Scriptable from PC? | Notes |
|---|---|---|---|
| **Debug APK + ML Kit Prompt API, driven by `am start`** | Yes | Yes | What this project does. |
| Instrumented test via `am instrument` | Yes | Yes, results go to stdout | Test must still bring an activity to the foreground. Not tried. |
| AICore app's Developer Preview UI | Yes (incl. preview models) | No | Only visible after enrolling in the Developer Preview. |
| Google AI Edge Gallery app | No — runs open Gemma models via LiteRT | Manual | Different runtime and weights. |
| Chrome Prompt API (`LanguageModel`) | Not on Android | — | Desktop Chrome only. |
| Old "AI Edge SDK" experimental access | Superseded | — | Replaced by ML Kit GenAI APIs. |

### Why plain adb can't do it

- AICore exposes no shell interface for inference.
- `cmd on_device_intelligence` exists (Android's system `OnDeviceIntelligenceManager`, backed here by
  AICore's `AiCoreIntelligenceService` / `AiCoreIsolatedService`), but it only offers
  `get-services`, `set-temporary-services`, `get-configurations`, and CTS test hooks — no inference.
- The adb shell user *does* hold `android.permission.USE_ON_DEVICE_INTELLIGENCE` (granted for CTS). In
  principle an instrumentation test using `adoptShellPermissionIdentity()` could call the system
  `OnDeviceIntelligenceManager` directly, bypassing ML Kit's foreground and quota rules. The request /
  response bundle format AICore expects there is private and undocumented, so this is untried
  reverse-engineering territory.

## ML Kit Prompt API facts

- Dependency: `com.google.mlkit:genai-prompt:1.0.0-beta4` (beta; no SLA).
- Flow: `Generation.getClient(config)` → `checkStatus()` → (`download()`) → `generateContent(...)` /
  `generateContentStream(...)`.
- `ModelConfig`: `releaseStage` = `STABLE` | `PREVIEW`, `preference` = `FULL` | `FAST`. Status is per
  variant.
- Inference only when the calling app is the **top foreground app**; background calls error.
- Per-app quota → `ErrorCode.BUSY`; back off exponentially.
- **Not supported on devices with an unlocked bootloader.**
- Supported devices vary by Nano version: nano-v2 (some OnePlus/OPPO/Xiaomi…), nano-v3 (Pixel 9–10,
  Galaxy S26, …), nano-v4 (Pixel 11, Galaxy Z Fold8/Flip8).

The API surface was confirmed by inspecting the AAR with `javap`, not just the docs.

## Test device findings (Pixel 11)

| Item | Value |
|---|---|
| Build | Android 17 (SDK 37), `user` / `release-keys` |
| Bootloader | Locked (`ro.boot.flash.locked=1`), verified boot `green` |
| AICore | `0.release.prod_aicore_20260820.00_RC08` |
| Base model | `nano-v4-full`, token limit 8192 |
| Features | System prompt, thinking mode, structured output, caching: all available |
| Variants | stable/full and stable/fast available; preview/* unavailable (not enrolled) |
| Latency (short prompts, in-app) | full ≈ 420 ms, fast ≈ 190 ms |

Asked what it is, the model answers "Gemma 4" — expected, since Gemini Nano 4 is built on Gemma 4.

### "Isn't Nano preinstalled?"

Not necessarily. Google's docs say a device "*probably* already has a stable version of Gemini Nano
downloaded". On this phone both stable variants initially reported `DOWNLOADABLE` ("can be downloaded on
this device, but is not currently downloaded"). Likely causes: a fresh AICore update (the day before)
requiring a newer model build, and AICore deferring background downloads. Downloading via the Prompt API
fetches the **shared system model** into AICore — not into this app — and every app on the phone uses it.

## Troubleshooting

### `adb: more than one device/emulator`
The phone is listed twice: the `ip:port` from `adb connect` and an mDNS alias
(`adb-XXXX._adb-tls-connect._tcp`). Pass `-s <ip>:<port>`; `prompt.ps1` picks the `ip:port` entry
automatically.

### Status stays `DOWNLOADABLE` / `-Download` shows no progress
AICore schedules its model downloads (MobileDataDownload jobs) with constraints such as **charging**,
**device idle**, and **unmetered network**. After a `download()` request it may fetch small assets
immediately (the on-device safety model, ~30 MB, arrived at once here) and defer the main model. Leave the
phone on Wi-Fi and charging, then re-check with `-Status`. To inspect pending jobs:

```powershell
adb shell dumpsys jobscheduler | Select-String aicore -Context 0,12
```

### "No result after N s"
- The app was sent to the background (back gesture, home) mid-request — Android freezes the process.
  Re-run; if a request is stuck, `adb shell am force-stop com.example.nanotest`.
- Check `adb logcat -s NanoTest`.

### Error `BUSY`
Per-app quota. Wait and retry. Enrolled Pixels can toggle "Bypass quota limits" in the AICore Developer
Preview UI.

### AICore settings screen only shows "Open source licenses"
Normal without Developer Preview enrollment. To enroll: join the `aicore-experimental` Google group,
become a tester of "Android AICore testing program" on Play, update AICore
(Settings → Google → All services → System services → AICore), then pick a preview model in the AICore
app. Use it with `-Stage preview`.

### Garbled non-English output
`prompt.ps1` sets the console to UTF-8. If you call adb yourself in Windows PowerShell 5.1, set
`[Console]::OutputEncoding = [Text.Encoding]::UTF8` first.

## Sources

- [ML Kit Prompt API – get started](https://developers.google.com/ml-kit/genai/prompt/android/get-started)
- [ML Kit GenAI overview (devices, foreground & quota rules)](https://developers.google.com/ml-kit/genai)
- [AICore Developer Preview program](https://developers.google.com/ml-kit/genai/aicore-dev-preview)
- [Announcing Gemma 4 in the AICore Developer Preview](https://developer.android.com/blog/posts/announcing-gemma-4-in-the-ai-core-developer-preview)
- [ML Kit Prompt API alpha announcement](https://android-developers.googleblog.com/2025/10/ml-kit-genai-prompt-api-alpha-release.html)
- [Gemini Nano | Android Developers](https://developer.android.com/ai/gemini-nano)
- [Chrome Prompt API (desktop only)](https://developer.chrome.com/docs/ai/prompt-api)
- [AI Edge Gallery issue #554 (Nano via AICore on Pixel 10 Pro XL)](https://github.com/google-ai-edge/gallery/issues/554)
