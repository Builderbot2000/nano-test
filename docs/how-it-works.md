# How it works

## The problem

Gemini Nano runs inside **AICore** (`com.google.android.aicore`), an Android system service. There is no
shell command, binder call, or content provider that lets `adb shell` send it a prompt. The only supported
entry point is a client library inside an app — here, the **ML Kit GenAI Prompt API**
(`com.google.mlkit:genai-prompt`). AICore also only serves an app that is the **top foreground app**.

adb *can* launch an app and read a debug app's private files. So the project is two halves bridged by adb:

```
 PC (prompt.ps1)                 Phone
 ───────────────                 ─────────────────────────────────────────────
 1. encode prompt ──adb am start──▶ PromptActivity (our app, now foreground)
                                        │ 2. ML Kit Prompt API
                                        ▼
                                    AICore (system service) ──▶ Gemini Nano
                                        │ 3. reply text
                                        ▼
                                    files/results/<id>.json
 4. poll with ◀──adb run-as cat──────────┘
    print reply
```

## Request lifecycle

### 1. PC sends the request — [prompt.ps1](../prompt.ps1)

1. Picks the device (`-Serial`, `$env:NANO_SERIAL`, or the first `ip:port` entry in `adb devices` — the
   phone also appears under an mDNS alias, which is skipped; with no `ip:port` entry, e.g. USB only, the
   first device). USB and wireless behave identically from here on.
2. Generates a random 12-char request **id**.
3. Base64-encodes the prompt (UTF-8). This avoids quoting problems through PowerShell → adb → device shell
   and keeps non-ASCII text intact.
4. Wakes the screen (`input keyevent KEYCODE_WAKEUP`) and launches:

   ```
   adb shell am start -n com.example.nanotest/.PromptActivity \
       --es id <id> --es mode prompt --es prompt_b64 <base64> [--es temperature 0.2 ...]
   ```

   All options travel as string intent extras. `-System` is sent base64-encoded as `system_b64`, and
   `-Schema` as `schema`. `-JsonSchema` never reaches the app: the script appends the schema to the
   prompt and strips a Markdown code fence from the reply.

### 2. App runs the request — [PromptActivity.kt](../app/src/main/java/com/example/nanotest/PromptActivity.kt)

- `onCreate` / `onNewIntent` read the extras. Launched by hand (no `id`), it just shows status on screen.
- A `GenerativeModel` client is created per (stage, preference) and cached for the life of the process
  (`Nano` object), so repeat requests skip setup.
- `checkStatus()` must return `AVAILABLE`; otherwise the request fails with a clear error. The app never
  downloads unless `mode=download`.
- `generateContent(generateContentRequest(TextPart(prompt)) { temperature/topK/seed/maxOutputTokens })`
  sends the prompt through ML Kit → AICore → Nano.
- With a `schema` extra the request becomes a typed request (`generateTypedContentRequest`) for the
  matching `@Generable` class in [Schemas.kt](../app/src/main/java/com/example/nanotest/Schemas.kt).
  The `genai-schema-compiler` KSP processor generates a schema provider for each class at build time;
  AICore constrains decoding to that schema, and the app serializes the typed reply back to JSON (Gson).
- Prompt requests are serialized with a `Mutex`; status and download requests are not, so a long download
  can't block a status check.

Manifest details that matter ([AndroidManifest.xml](../app/src/main/AndroidManifest.xml)):

| Attribute | Why |
|---|---|
| `exported="true"` | So `am start` from adb can launch it. |
| `showWhenLocked` / `turnScreenOn` | The activity becomes the foreground app even over the lock screen. |
| `launchMode="singleTop"` | A request arriving while the activity is up goes to `onNewIntent`. |

### 3. App writes the result

The result JSON is written to the app's private storage at `files/results/<id>.json` — first to
`<id>.json.tmp`, then renamed, so the PC never reads a partial file. It is also logged under the
`NanoTest` logcat tag. When no requests are pending, the activity finishes.

Result fields:

| Field | Meaning |
|---|---|
| `ok` | `true` on success. |
| `text` | Model reply (prompt mode). |
| `status` | `AVAILABLE` / `DOWNLOADABLE` / `DOWNLOADING` / `UNAVAILABLE` for the chosen variant. |
| `stage`, `preference` | Which variant was used (`default` = ML Kit's defaults). |
| `schema` | Compiled schema used, if any; `text` is then its JSON. |
| `finish_reason` | ML Kit candidate finish reason (0 = normal stop). |
| `latency_ms` | Time inside the app for the whole request, including `checkStatus()`. |
| `error`, `error_code` | On failure; `error_code` is ML Kit's `GenAiException` code. |
| `schemas`, `variants`, `base_model`, `token_limit`, `system_prompt`, `thinking`, `structured_output`, `caching` | Status mode only. |

### 4. PC reads the result

The script polls every 300 ms:

```
adb shell run-as com.example.nanotest cat files/results/<id>.json
```

`run-as` lets adb act as the app's user — possible only because the APK is a **debug** build; no root
needed. Once the file exists, the script deletes it, parses the JSON, and prints `text` (or the full JSON
with `-Json` / `-Status` / `-Download`).

## Modes

| Mode | Script flag | What the app does |
|---|---|---|
| `prompt` | *(default)* | Runs the prompt on an already-present model. |
| `status` | `-Status` | Reports status of all four variants (stable/preview × full/fast) plus model name, token limit and feature flags. |
| `download` | `-Download` | Calls `model.download()`, writes `files/results/<id>.progress` as bytes arrive (the script shows a progress bar), and keeps the screen on while waiting. |

## Project layout

```
nano-test/
├── prompt.ps1                     PC-side client
├── package.json                   promptfoo (dev dependency) + npm scripts
├── evals/
│   ├── promptfooconfig.yaml       test suite
│   ├── nano-provider.js           promptfoo provider → prompt.ps1 -Json
│   └── schemas/                   ad-hoc JSON Schemas used by tests
├── app/
│   ├── build.gradle.kts           minSdk 31, targetSdk 36, genai-prompt 1.0.0-beta4, KSP schema compiler
│   └── src/main/
│       ├── AndroidManifest.xml
│       └── java/com/example/nanotest/
│           ├── PromptActivity.kt
│           └── Schemas.kt         @Generable output classes
├── build.gradle.kts               AGP 9.4.1 (built-in Kotlin)
├── settings.gradle.kts
├── gradle/wrapper/                Gradle 9.8.0 (checksums pinned)
└── docs/
```

## Limits

- The phone must be awake, and the app must stay in front while a request runs.
- Per-app inference quota (AICore returns `BUSY`); the Prompt API input limit is about 4K tokens for
  earlier Nano versions — query `-Status` for the device's `token_limit` (8192 on nano-v4).
- Text-only and single-turn for now. The API also supports image+text prompts, streaming, and context
  caching.
- Enforced structured output only works with schemas compiled into the app (see the README).
