# nano-test

Prompt the on-device **Gemini Nano** model on a physical Android phone from a PC, and get the reply back
in the terminal.

```
> ./prompt.ps1 "Write a haiku about USB cables."
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
- A Windows, Linux or macOS PC with:
  - the Android SDK platform-tools (`adb`). The script finds `adb` on PATH, in `ANDROID_HOME`, or in
    Android Studio's default SDK location.
  - a JDK to build the app (Android Studio's bundled JBR works). Gradle is fetched by the wrapper.
  - PowerShell to run `prompt.ps1`. It is built into Windows. On Linux/macOS install
    [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
    (`pwsh`): e.g. `brew install powershell` on macOS, or `sudo snap install powershell --classic` on
    Linux.
  - Node.js 22.22+ for the [test suites](#test-suites-promptfoo) only.

The commands below are written as `./prompt.ps1 …`, which works in PowerShell on any OS and in bash/zsh on
Linux/macOS (the script has a `pwsh` shebang). In Windows `cmd.exe`, use
`powershell -File prompt.ps1 …` instead.

## Setup

### 1. Connect the phone

Either USB or wireless debugging works; nothing else in the setup changes.

**USB:** enable **Developer options → USB debugging**, plug the phone in, and accept the "Allow USB
debugging?" prompt on the phone. `adb devices` should show its serial as `device`.

**Wireless:** on the phone, **Settings → System → Developer options → Wireless debugging → Pair device with pairing
code**. Then on the PC:

```sh
adb pair <ip>:<pairing-port>      # enter the 6-digit code
adb connect <ip>:<connect-port>   # the port shown on the main Wireless debugging screen
adb devices                        # should show the phone as "device"
```

The connect port changes each time wireless debugging is re-enabled; re-run `adb connect` when it does.
Pairing only has to be done once per PC.

### 2. Build and install

Point `JAVA_HOME` at a JDK, then build with the Gradle wrapper and install the APK.

Windows (PowerShell):

```powershell
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
.\gradlew.bat assembleDebug
adb -s <serial> install -r app\build\outputs\apk\debug\app-debug.apk
```

Linux / macOS:

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"   # macOS
export JAVA_HOME="$HOME/android-studio/jbr"   # Linux: wherever Android Studio is unpacked (e.g. /opt/android-studio/jbr)
./gradlew assembleDebug
adb -s <serial> install -r app/build/outputs/apk/debug/app-debug.apk
```

Gradle finds the Android SDK through `local.properties` (`sdk.dir=…`, written by Android Studio when it
opens the project) or the `ANDROID_HOME` environment variable. Set one of them before a command-line-only
build.

### 3. Check the model is present

```sh
./prompt.ps1 -Status
```

If the variant you want says `DOWNLOADABLE`, run `./prompt.ps1 -Download` once (see
[Troubleshooting](docs/research-notes.md#troubleshooting) — AICore may finish it later in the background).

## Usage

```sh
./prompt.ps1 "your prompt"                                   # prints just the reply
./prompt.ps1 "your prompt" -Json                             # full result: text, latency, status…
./prompt.ps1 "17 * 23?" -Preference fast -Temperature 0      # fast variant, deterministic-ish
./prompt.ps1 -Status                                         # model availability + capabilities
./prompt.ps1 -Download                                       # ask AICore to fetch the model
./prompt.ps1 "Is the sky blue?" -System "Be terse."          # with a system instruction
./prompt.ps1 "The food was cold." -Schema sentiment          # structured output, enforced on device
./prompt.ps1 "Extract the contact: ..." -JsonSchema evals/schemas/contact.json  # ad-hoc schema
```

Quoting follows the shell you type in. In bash/zsh, use single quotes for prompts that contain `$` or
`` ` ``.

| Option | Meaning |
|---|---|
| `-Stage stable\|preview` | Model release track. `preview` needs the AICore Developer Preview enrollment. |
| `-Preference full\|fast` | Full (higher quality) or fast (lower latency) variant. |
| `-Temperature`, `-TopK`, `-Seed`, `-MaxTokens` | Generation parameters. |
| `-Json` | Print the whole result JSON instead of just the text. |
| `-System` | System instruction. |
| `-Schema` | Structured output using a schema compiled into the app ([Schemas.kt](app/src/main/java/com/example/nanotest/Schemas.kt): `sentiment`, `recipe`). Decoding is constrained, so the reply is always valid JSON of that shape. |
| `-JsonSchema` | Any JSON Schema (text or file path). It is appended to the prompt, not enforced — validate the reply (the test suite does). |
| `-Serial` | adb device (or set the `NANO_SERIAL` environment variable). Default: first `ip:port` device, else the first device (e.g. USB). |
| `-TimeoutSec` | Wait limit (default 120 s, 3600 s for `-Download`). |

Example `-Json` result:

```json
{ "id": "7ca4b42c12e6", "mode": "prompt", "status": "AVAILABLE", "stage": "default",
  "preference": "fast", "ok": true, "text": "391", "finish_reason": 0, "latency_ms": 186 }
```

### Structured output: which one?

| | `-Schema` | `-JsonSchema` |
|---|---|---|
| Guaranteed to match | Yes (constrained decoding in AICore) | No — the model is only asked |
| A new shape needs | A `@Generable` data class in `Schemas.kt`, registered in `SCHEMAS`, then rebuild + reinstall | Nothing |

ML Kit only supports compile-time schemas; it has no API for a JSON Schema supplied at runtime.

## Test suites (promptfoo)

[promptfoo](https://www.promptfoo.dev/) (open source) runs collections of test cases against the phone,
checks the replies, and keeps a history of results. It is set up in [evals/](evals/):

```sh
npm install        # once; needs Node.js 22.22+
npm run eval       # run evals/promptfooconfig.yaml against the phone
npm run view       # browse results, compare runs, see latency (web UI)
npx promptfoo eval -c evals/promptfooconfig.yaml -o results.csv   # also export (.csv / .json / .html)
```

A test case sets vars and assertions:

```yaml
- description: Sentiment (compiled schema, enforced on device)
  vars:
    schema: sentiment            # provider setting: overrides the provider config for this test
    input: I waited an hour and the food arrived cold.
  assert:
    - type: is-json
    - type: javascript
      value: JSON.parse(output).label === 'negative'
```

- **Provider settings** (`system`, `schema`, `jsonSchema`, `stage`, `preference`, `temperature`, `topK`,
  `seed`, `maxTokens`, `serial`, `timeoutSec`) go in the provider `config`, or per test in `vars`.
- **Prompts** can be plain templates (`'{{input}}'`) or chat format
  (`[{"role": "system", ...}, {"role": "user", ...}]`). Nano takes a single user turn.
- **Ad-hoc schemas**: put `jsonSchema: file://schemas/contact.json` in vars, and use the same file as the
  `is-json` assertion's `value` to validate the reply.
- **Results** are stored locally (`~/.promptfoo`) with pass/fail, the reply, and `latencyMs` (time on
  the device). Metadata also records round-trip time, variant, schema and finish reason.
- Tests run one at a time (`maxConcurrency: 1`), since the phone serves one foreground request at a time.

The provider, [evals/nano-provider.js](evals/nano-provider.js), runs `prompt.ps1 -Json` for each test. It
uses `powershell.exe` on Windows and `pwsh` on Linux/macOS. To use a different PowerShell, set
`NANO_POWERSHELL` (e.g. `NANO_POWERSHELL=pwsh` to use PowerShell 7 on Windows).

## Rules of thumb

- Keep the phone awake and **don't navigate away** while a request runs — AICore only serves the
  foreground app. The app can show over the lock screen.
- Only `-Download` ever fetches a model; everything else uses what's already on the device.
- AICore enforces a per-app quota; `BUSY` errors mean back off and retry.

## Docs

- [docs/how-it-works.md](docs/how-it-works.md) — architecture, request flow, file layout.
- [docs/research-notes.md](docs/research-notes.md) — ways to reach Nano, device findings, troubleshooting.
