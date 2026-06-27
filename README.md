# Speechy

A local, private dictation floaty for macOS — a self-hosted Wispr Flow. Hold a hotkey, speak,
release, and your words are transcribed by an **on-device Whisper model** and pasted into whatever
text field has focus. No cloud, no word caps, no audio ever leaving your Mac.

- 🎙 **Hold-to-talk** (hold Right-Option) or **double-tap to lock** hands-free.
- 🧠 **Local Whisper** via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Core ML, Apple-Silicon-optimized).
- ✨ **Cleanup pass** — a small local LLM (via Ollama) adds punctuation, removes filler, applies
  spoken commands ("new line"). Falls back to fast rule-based cleanup if Ollama isn't running.
- 📋 **Pastes anywhere** — clipboard + ⌘V, then restores your clipboard. Works in Mail, Slack,
  browsers, IDEs, Notes, everything.
- 🗂 **24-hour history** — every transcript is saved locally *before* pasting, so nothing is ever
  lost to a crash or failed paste. Re-copy any of the last 20 from the menu bar.

## Requirements

- Apple Silicon Mac, macOS 14+ (built/tested on M2 / 16 GB / macOS 15).
- Xcode Command Line Tools (no full Xcode needed).
- *(Optional, for LLM cleanup)* [Ollama](https://ollama.com): `brew install ollama && ollama pull qwen2.5:3b-instruct`

## Build & run

```bash
./scripts/build_app.sh            # builds + assembles + ad-hoc-signs Speechy.app
cp -R Speechy.app /Applications/  # install to a stable path so permissions stick
open /Applications/Speechy.app
```

A 🎙 icon appears in the menu bar. On first launch Speechy downloads the default model
(`large-v3-turbo`, ~1.5 GB) and prompts for permissions.

### Grant permissions (first launch)

Speechy needs three macOS privacy grants. Settings → Privacy & Security:

1. **Microphone** — to record.
2. **Accessibility** — to send the ⌘V paste and watch for the hotkey.
3. **Input Monitoring** — required by the global hotkey listener.

The floaty links you straight to each pane if a grant is missing. After granting Accessibility/Input
Monitoring you may need to quit and reopen Speechy once.

## Usage

| Gesture | Action |
|---|---|
| **Hold** Right-Option, speak, release | Transcribe + paste at the cursor |
| **Double-tap** Right-Option | Toggle hands-free "locked" recording; double-tap again to stop |
| Menu bar 🎙 → History | Re-copy any transcript from the last 24h |
| Menu bar 🎙 → Model | Switch Whisper model |
| Menu bar 🎙 → Cleanup | Toggle the LLM/rule cleanup pass |
| Menu bar 🎙 → Edit custom vocabulary… | Bias Whisper toward your jargon/names |

## Tuning for better transcription

The knobs that actually move accuracy (defaults in parentheses):

**Model** (`large-v3-turbo`) — switch to `large-v3` for max accuracy, or `small.en`/`base.en` for speed.
`.en` variants are more accurate if you only speak English.

**Custom vocabulary / prompt** (empty) — *the single biggest lever for domain words.* Menu → Edit
custom vocabulary. Add names, product terms, acronyms; Whisper is biased toward them.

**Cleanup** (on, `qwen2.5:3b-instruct`) — the Wispr-style finish. Edit the model in
`Settings.cleanupModel` or the prompt in `Cleanup.swift`.

Hardcoded defaults in `Transcriber.swift` you can tweak:
- `language` (`en`) — force a language; empty = auto-detect.
- `temperature` 0 with `temperatureFallbackCount` 5 — deterministic, falls back only on bad chunks.
- `compressionRatioThreshold` / `logProbThreshold` / `noSpeechThreshold` — the anti-hallucination trio.
- `withoutTimestamps` true — dictation doesn't need word timings → cleaner, faster.

## Where data lives

- Transcripts: `~/Library/Application Support/Speechy/history.jsonl` (auto-pruned to 24h).
- Models: WhisperKit's cache under Application Support.
- Settings: `UserDefaults` (`com.speechy.app`).

## Architecture

```
hotkey → AudioRecorder (16kHz mono) → Transcriber (WhisperKit)
       → Cleanup (Ollama / rules) → HistoryStore.append → TextInjector (⌘V) → floaty
```

See `Sources/Speechy/` — one file per component. `CLAUDE.md` has the full map.

## Roadmap / non-goals (v1)

- One-shot decode on release; live streaming partials are a planned fast-follow (WhisperKit supports it).
- Ad-hoc signed for personal use; no notarization/distribution.
- English-first (multilingual works, defaults to `en`).
