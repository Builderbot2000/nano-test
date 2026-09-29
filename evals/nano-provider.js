// promptfoo provider for on-device Gemini Nano. Each call runs prompt.ps1 -Json, which drives the phone
// over adb (see docs/how-it-works.md). PowerShell: powershell.exe on Windows, pwsh (PowerShell 7+) on
// Linux/macOS; set NANO_POWERSHELL to use another executable (e.g. pwsh on Windows).
//
// Settings come from the provider `config`, overridden per test by vars of the same name:
//   system, schema (compiled into the app, enforced), jsonSchema (ad-hoc, prompt only),
//   stage, preference, temperature, topK, seed, maxTokens, serial, timeoutSec
// A chat-format prompt ([{role: "system"|"user", content}]) also works: the system message becomes
// the system instruction. Nano takes one user turn, so multi-turn chats are rejected.

const { spawn } = require('node:child_process');
const path = require('node:path');

const SCRIPT = path.join(__dirname, '..', 'prompt.ps1');
const POWERSHELL = process.env.NANO_POWERSHELL || (process.platform === 'win32' ? 'powershell.exe' : 'pwsh');

// setting → [prompt.ps1 parameter, type]; switches are not needed here.
const PARAMS = {
  system: ['System', 'string'],
  schema: ['Schema', 'string'],
  jsonSchema: ['JsonSchema', 'string'],
  stage: ['Stage', 'string'],
  preference: ['Preference', 'string'],
  temperature: ['Temperature', 'number'],
  topK: ['TopK', 'number'],
  seed: ['Seed', 'number'],
  maxTokens: ['MaxTokens', 'number'],
  serial: ['Serial', 'string'],
  timeoutSec: ['TimeoutSec', 'number'],
};

function parsePrompt(prompt) {
  try {
    const messages = JSON.parse(prompt);
    if (Array.isArray(messages) && messages.every((m) => m && typeof m.role === 'string')) {
      const system = messages.filter((m) => m.role === 'system').map((m) => m.content).join('\n\n');
      const users = messages.filter((m) => m.role === 'user');
      if (users.length !== 1 || messages.some((m) => m.role !== 'system' && m.role !== 'user')) {
        throw new Error('Chat prompts must have exactly one user message and optional system messages.');
      }
      return { prompt: users[0].content, system: system || undefined };
    }
  } catch (e) {
    if (!(e instanceof SyntaxError)) throw e;
  }
  return { prompt };
}

// Values travel as environment variables, so quotes and newlines in prompts and schemas survive intact
// (Windows PowerShell 5.1 mangles embedded quotes in command-line arguments).
function runScript(settings) {
  const env = { ...process.env };
  let command = `& '${SCRIPT.replace(/'/g, "''")}' -Json -Prompt $env:NANO_PF_PROMPT`;
  env.NANO_PF_PROMPT = settings.prompt;
  for (const [key, [param, type]] of Object.entries(PARAMS)) {
    let value = settings[key];
    if (value === undefined || value === null || value === '') continue;
    if (key === 'jsonSchema' && typeof value !== 'string') value = JSON.stringify(value);
    if (type === 'number' && Number.isNaN(Number(value))) throw new Error(`${key} must be a number`);
    const name = `NANO_PF_${key.toUpperCase()}`;
    env[name] = String(value);
    command += ` -${param} $env:${name}`;
  }

  return new Promise((resolve, reject) => {
    const child = spawn(
      POWERSHELL,
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', command],
      { env, windowsHide: true },
    );
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => (stdout += d));
    child.stderr.on('data', (d) => (stderr += d));
    child.on('error', (e) =>
      reject(
        e.code === 'ENOENT'
          ? new Error(`${POWERSHELL} not found. Install PowerShell 7 (pwsh), or set NANO_POWERSHELL.`)
          : e,
      ),
    );
    child.on('close', (code) => {
      try {
        resolve(JSON.parse(stdout));
      } catch {
        reject(new Error(`prompt.ps1 exited with ${code}: ${(stderr || stdout).trim()}`));
      }
    });
  });
}

module.exports = class NanoProvider {
  constructor(options = {}) {
    this.providerId = options.id || 'gemini-nano';
    this.config = options.config || {};
  }

  id() {
    return this.providerId;
  }

  async callApi(prompt, context = {}) {
    const vars = context.vars || {};
    const settings = { ...this.config };
    for (const key of Object.keys(PARAMS)) if (vars[key] !== undefined) settings[key] = vars[key];
    try {
      const parsed = parsePrompt(prompt);
      settings.prompt = parsed.prompt;
      if (parsed.system) settings.system = [parsed.system, settings.system].filter(Boolean).join('\n\n');

      const started = Date.now();
      const result = await runScript(settings);
      const metadata = {
        status: result.status,
        stage: result.stage,
        preference: result.preference,
        schema: result.schema,
        finishReason: result.finish_reason,
        deviceLatencyMs: result.latency_ms,
        roundTripMs: Date.now() - started,
      };
      if (!result.ok) {
        const code = result.error_code === undefined ? '' : ` (code ${result.error_code})`;
        return { error: `[${result.status ?? 'ERROR'}] ${result.error}${code}`, metadata };
      }
      return { output: result.text, latencyMs: result.latency_ms, metadata };
    } catch (e) {
      return { error: e.message };
    }
  }
};
