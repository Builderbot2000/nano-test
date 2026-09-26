# nano-test

Prompt the on-device **Gemini Nano** model on a physical Android phone from a PC, and get the reply back
in the terminal.

```
> .\prompt.ps1 "Write a haiku about USB cables."
Thin wire connects,
Data flows with steady stream,
World in your hand now.
```

Nano can't be prompted directly from `adb shell`. This project uses a tiny debug app on the phone as a
bridge: adb launches it with the prompt, it calls Nano via the ML Kit Prompt API, and writes the reply to a
file that adb reads back. See [docs/how-it-works.md](docs/how-it-works.md).

## Requirements

- A phone that supports the ML Kit GenAI **Prompt API** (tested: Pixel 11, Android 17), with a **locked
  bootloader** and up-to-date AICore.
- Developer options → USB or Wireless debugging enabled.
- Windows PC with the Android SDK (`adb` on PATH) and Android Studio's bundled JDK. Gradle is fetched by
  the wrapper.

## Setup

### 1. Connect the phone (wireless debugging)

On the phone: **Settings → System → Developer options → Wireless debugging → Pair device with pairing
code**. Then on the PC:

```powershell
adb pair <ip>:<pairing-port>      # enter the 6-digit code
adb connect <ip>:<connect-port>   # the port shown on the main Wireless debugging screen
adb devices                        # should show the phone as "device"
```

The connect port changes each time wireless debugging is re-enabled; re-run `adb connect` when it does.
Pairing only has to be done once per PC.

### 2. Build and install

```powershell
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
.\gradlew.bat assembleDebug
adb -s <ip>:<port> install -r app\build\outputs\apk\debug\app-debug.apk
```

### 3. Check the model is present

```powershell
.\prompt.ps1 -Status
```

If the variant you want says `DOWNLOADABLE`, run `.\prompt.ps1 -Download` once (see
[Troubleshooting](docs/research-notes.md#troubleshooting) — AICore may finish it later in the background).

## Usage

```powershell
.\prompt.ps1 "your prompt"                                   # prints just the reply
.\prompt.ps1 "your prompt" -Json                             # full result: text, latency, status…
.\prompt.ps1 "17 * 23?" -Preference fast -Temperature 0      # fast variant, deterministic-ish
.\prompt.ps1 -Status                                         # model availability + capabilities
.\prompt.ps1 -Download                                       # ask AICore to fetch the model
```

| Option | Meaning |
|---|---|
| `-Stage stable\|preview` | Model release track. `preview` needs the AICore Developer Preview enrollment. |
| `-Preference full\|fast` | Full (higher quality) or fast (lower latency) variant. |
| `-Temperature`, `-TopK`, `-Seed`, `-MaxTokens` | Generation parameters. |
| `-Json` | Print the whole result JSON instead of just the text. |
| `-Serial` | adb device (or set `$env:NANO_SERIAL`). Default: first `ip:port` device. |
| `-TimeoutSec` | Wait limit (default 120 s, 3600 s for `-Download`). |

Example `-Json` result:

```json
{ "id": "7ca4b42c12e6", "mode": "prompt", "status": "AVAILABLE", "stage": "default",
  "preference": "fast", "ok": true, "text": "391", "finish_reason": 0, "latency_ms": 186 }
```

## Rules of thumb

- Keep the phone awake and **don't navigate away** while a request runs — AICore only serves the
  foreground app. The app can show over the lock screen.
- Only `-Download` ever fetches a model; everything else uses what's already on the device.
- AICore enforces a per-app quota; `BUSY` errors mean back off and retry.

## Docs

- [docs/how-it-works.md](docs/how-it-works.md) — architecture, request flow, file layout.
- [docs/research-notes.md](docs/research-notes.md) — ways to reach Nano, device findings, troubleshooting.
