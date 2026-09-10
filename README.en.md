# Sente

English | [日本語](./README.md)

**A coding agent you use with your voice.** One terminal — or one menu bar icon — and you just talk.

```sh
curl -fsSL https://teai.io/te | sh
```

- **macOS / Linux** — works as-is
- **Windows** — inside WSL (full functionality). Native Windows has a PowerShell installer (binary only)
- Requires: `python3` (preinstalled on most systems)

---

## Start in 30 seconds

```sh
te register          # email only, no browser needed
te "what should I do first?"
```

With your voice:

```sh
koe                  # talk, and hear the answer back (Ctrl-C to quit)
```

On macOS, the **Sente.app** menu bar app is also available:

```sh
te app install
```

---

## For you

### Developers

```sh
te run "fix the tests in this repo"   # run inside your working directory
te -m teai/auto "..."                 # pick a model
te resume                             # resume the last session
te models                             # list available models
te doctor                             # diagnose the environment
```

The `/v1/chat/completions`-compatible API works directly, and existing coding-agent CLIs can connect to it.

### Non-developers

You don't need to memorize commands. Install Sente.app, click the icon, and talk. The answer comes back as speech.

### IT / security

Run `te privacy` — it prints exactly what this build sends and where, so you can check it against your own security policy before rollout or deployment. It is more accurate than any README.

In short:

- Prompts and code context → `teai.io` (for inference and billing)
- Voice → `koe.live` for transcription. **Audio retention is off by default** (`te privacy stt-log on` to opt in)
- **PII scrubbing** (optional, opt-in): `te privacy scrub on` detects names, addresses, phone numbers, and API keys locally — with a local Ollama model plus pattern matching — and replaces them with placeholders before sending. If Ollama is unavailable it **stops with an error rather than sending plaintext** (fail-closed)
- **BYOK**: `te byok add <provider> <key>` lets you register your own API keys (run `te byok` for supported providers)

### Cost-conscious

```sh
te stats            # balance and per-model breakdown
te topup 10000      # top up (¥1 = 6 credits)
```

`te fast` selects a cheaper model. `te stats` shows exactly where your credits go.

### Batch / high volume

Built for volume: thousands of requests a day go through the same endpoint without extra setup.

Run large batches by calling the `/v1/chat/completions`-compatible endpoint in parallel — it handles high volume as-is. `te run` retries once with the next model when a failure is model-related (disable with `TE_NO_FALLBACK=1`), so a long batch is less likely to stop halfway.
You can retry per request, and failures are reported per item rather than aborting the whole run.

### Japanese-first

Both the UI and the voice default to Japanese. `te lang en` switches to English. Speech synthesis and recognition run on koe.live, which is strong in Japanese.

### Voice creators

```sh
te voice enroll     # register your own voice from a 15-second recording
te voice <that-id>  # replies come back in your voice
koe "text to speak" # one-off synthesis
```

### Built in Japan

teai.io and koe.live are operated by Enabler Inc., based in Tokyo, Japan. The speech stack is developed in Japan as well.

### Researchers

```sh
te bench                          # run the public benchmark on your model
te bench jp-business teai/auto    # pick an eval set and a model
```

The questions and answers are public data, so anyone can reproduce the same comparison — you can compare models on identical problems, and the result holds up when others run it.

### Executives

`te stats` is the single source of truth for cost. For team rollout, `te byok add` lets you register your company's own API keys.

---

## Voice (KOE)

| Command | What it does |
|---|---|
| `koe` / `te talk` | continuous voice conversation |
| `te v` | one-shot voice instruction |
| `te voice on` / `off` | toggle spoken replies (takes effect immediately) |
| `te voice <id>` | switch voice (`te voice enroll` to register your own) |
| `te voice queue` | show queued utterances |
| `te voice stop` / `skip` | stop / skip to the next |

**Voices never overlap, even when you run several terminals at once.** When Sente detects multiple concurrent sessions, it queues the utterances and speaks them together. With a single session it speaks immediately. Three or more queued items are summarized into one concise report.

---

## Where your data goes

Run `te privacy`. It describes the implementation as it actually is.

---

## Building Sente.app

```sh
cd sente-app
./build.sh              # → build/Sente.app
./build.sh --install    # → installs to /Applications
```

Requires Xcode Command Line Tools (`swiftc`). No Xcode project needed — one `swiftc` invocation plus a hand-assembled bundle.

---

## License

MIT License. Copyright (c) 2026 Yuki Hamada.

Covers both `te-install.sh` (the command) and `sente-app/` (the macOS app).
