# CLAUDE.md

Guidance for working in this repo.

## What this is

**Speechy** — a local, private macOS dictation floaty (a self-hosted Wispr Flow). Global hotkey →
on-device Whisper transcription → optional local-LLM cleanup → paste into the focused app's text
field. Menu-bar-only (`LSUIElement`), no Dock icon, no main window. Everything runs offline; the only
network call is to `localhost` (Ollama, optional).

## Build & run

```bash
swift build                  # debug compile (fast iteration)
./scripts/build_app.sh        # release build → assembles + signs Speechy.app (stable self-signed id)
open Speechy.app              # run (or install to /Applications first for stable TCC grants)
./scripts/lint.sh             # build + SwiftLint + swift-format (use --fix to auto-format)
```

- **Swift 5 language mode** is set in `Package.swift` (`.swiftLanguageMode(.v5)`) — the app is
  singleton/AppKit-heavy and we deliberately opt out of Swift 6 strict concurrency. Keep it that way
  unless you're prepared to actor-annotate everything.
- Requires macOS 14+ (WhisperKit constraint). Builds with Command Line Tools; **no Xcode needed**.
- The release build recompiles WhisperKit (~70s cold).
- **Signing:** `build_app.sh` signs with a stable self-signed identity ("Speechy Self-Signed") so the
  Accessibility/Mic grants survive rebuilds. Create it once via `scripts/make_signing_identity.sh`;
  it falls back to ad-hoc if absent.

## Code quality

- **SwiftLint** (`.swiftlint.yml`) + **swift-format** (`.swift-format`) — run via `./scripts/lint.sh`.
  `--fix` auto-formats. CI (`.github/workflows/ci.yml`) runs build + both linters (strict) on every push/PR.
- Keep the tree at **zero** lint findings.

## Layout (`Sources/Speechy/`, one file per responsibility)

| File | Responsibility |
|---|---|
| `main.swift` | Entry point; `MainActor.assumeIsolated` bootstraps `NSApplication` as `.accessory`. |
| `AppDelegate.swift` | Orchestrator. Owns the status item + menu, wires hotkey → pipeline, manages permissions/model load. **The pipeline lives in `stopAndProcess()`.** |
| `AppState.swift` | `@MainActor ObservableObject` the floaty binds to (`phase`, `audioLevel`, `lastText`). |
| `FloatingPanel.swift` | Fixed-size, non-activating, all-Spaces `NSPanel`; pill animates inside it (no hover jitter); draggable, position persists. |
| `FloatyView.swift` | SwiftUI pill UI: collapsed dots / hover hint / live waveform / processing oscillation; click-to-toggle. |
| `HotkeyManager.swift` | Active `CGEventTap`: **hold Fn** = push-to-talk, **tap Fn+Space** = lock toggle (Space consumed). |
| `AudioRecorder.swift` | `AVAudioEngine` capture → `AVAudioConverter` → 16 kHz mono `[Float]` + RMS level. |
| `Transcriber.swift` | `actor` wrapping WhisperKit; tuned `DecodingOptions`, real download progress, 0-byte self-heal. |
| `Prettifier.swift` | **Deterministic** zero-latency layer: spoken commands, filler, capitalization, spacing. Never changes words. |
| `Cleanup.swift` | LLM **structure-only** pass via Ollama (paragraphs/lists), **streamed**; Prettifier as fallback. |
| `Ollama.swift` | Local Ollama client: list installed models + pull on demand. |
| `TextContext.swift` | Reads cursor context via AX; `SmartJoin` (spacing/casing on insert) + `StreamInserter` (live typing). |
| `TextInjector.swift` | Clipboard paste (atomic) **and** synthetic Unicode typing (`type`) for streaming insertion. |
| `HistoryStore.swift` | JSONL log in App Support, 24h prune. |
| `PermissionsManager.swift` | Mic / Accessibility checks + deep links into System Settings panes. |
| `Settings.swift` | `UserDefaults`-backed tuners (model, language, cleanup, custom prompt, hotkey). |

## Key conventions & gotchas

- **The pipeline** (`AppDelegate.stopAndProcess`): transcribe → cleanup → `HistoryStore.append` →
  paste. History append always precedes paste; the final text is also left recoverable on the clipboard.
- **Permissions are the #1 source of "it doesn't work."** The hotkey `CGEventTap` silently fails to
  create without Accessibility + Input Monitoring; `AppDelegate.requestPermissions()` detects this and
  deep-links the user, then retries once.
- **The floaty must never become key/main** (`canBecomeKey == false`) or it would steal focus from the
  app you're dictating into.
- **Default hotkey** is Right-Option (key code 61). Modifier keys are tracked via `.flagsChanged`;
  regular keys via `.keyDown/.keyUp`. See `HotkeyManager.modifierMask(for:)`.
- **Whisper tuning** lives in `Transcriber.transcribe()`. The custom prompt (`Settings.customPrompt`)
  is the highest-impact accuracy lever — it's tokenized and passed as `promptTokens`.
- **Cleanup is best-effort and never throws** — if Ollama is down it falls back to rules so dictation
  never blocks.

## Testing changes end-to-end

No unit tests yet. Manual loop: focus TextEdit → hold Right-Option, say a sentence → confirm cleaned
text pastes at the cursor and appears in `~/Library/Application Support/Speechy/history.jsonl`. Repeat
in Slack / a browser / an IDE to confirm the paste path. Stop Ollama to verify the rule-based fallback.
