# Plan: Local Whisper Speech-to-Text for macOS

> Source PRD: `plans/speech-to-text-prd.md`

## Framing (v1)

This **is** a real native macOS menu-bar app — a proper `.app` you launch that lives in your menu bar, with the recording indicator, settings, and launch-at-login. The only thing deferred is **distribution**: for now you install it by **cloning the GitHub repo and building it locally** (one setup command builds `whisper.cpp` with Metal, downloads the default model, and produces the `.app`); then grant Microphone + Accessibility and run. Building requires Xcode command-line tools.

What comes **later**: a **signed + notarized download** so others can install without build tools (App Store / DMG), an in-app model picker/download, and a fuller settings GUI.

## Model management — how it works (plain explanation)

A Whisper "model" is a single weights file (e.g. `ggml-medium.en.bin`, ~1.5 GB). The app needs one on disk to transcribe. For v1 the **setup script downloads it once** into the models dir from the public `ggml` model host, and the app loads it by path from config. Switching models = run setup for a different size, or edit one config line to point at another downloaded file. No in-app download UI in v1.

## Architectural decisions (durable)

- **App**: native Swift + SwiftUI, menu-bar-only agent (`LSUIElement`/accessory policy — no Dock icon).
- **Engine**: `whisper.cpp` vendored as a git submodule, built with **Metal**, linked via SwiftPM/xcframework.
- **Models**: GGML English models (`.bin`) in a known dir (`./models` or `~/Library/Application Support/<app>/models`). Default `medium.en`, fetched by setup.
- **Audio**: `AVAudioEngine` → 16 kHz mono Float32 PCM buffer.
- **Hotkeys**: global `CGEventTap` (requires Accessibility).
- **Insertion**: write transcript to `NSPasteboard` → synthesize ⌘V via `CGEvent` → restore prior clipboard.
- **Config**: human-editable config file (JSON) for hotkeys, model path, mic, options — until a settings GUI exists.
- **Build/setup**: a `Makefile`/`setup.sh` as the single entry point (e.g. `make setup`, `make run`), documented in `README`. README includes the PRD's hardware/compatibility notes.
- **Permissions**: Microphone + Accessibility; the app detects missing perms and guides the user (deep-link to System Settings).
- **Bundle & permission persistence**: the build produces a proper `.app` bundle with a **stable bundle identifier and signature** (ad-hoc or Developer-ID), installed to a stable path (e.g. `/Applications`). macOS ties Accessibility/Microphone (TCC) grants to the app's identity, so a stable signed bundle means permissions are granted once, not re-prompted on every rebuild.

---

## Phase 1 — Clone-and-run dictation spine (usable day one)

**User stories**: 1, 2, 5, 6, 7, 8, 9, 10, 11, 12, 13, 17, 18, 25, 28, 32, 34

### What to build

A cloneable repo that builds and runs a menu-bar-only app delivering the full dictation loop, plus the setup tooling and docs to get there.

- **Setup**: `Makefile`/`setup.sh` that vendors + builds `whisper.cpp` (Metal), downloads `ggml-medium.en.bin` into the models dir, and builds the Swift app. `README` with clone → setup → permissions → run steps and a hardware/compatibility section.
- **Runtime**: a single hold-to-talk global hotkey records the mic; on release it transcribes locally via `whisper.cpp` and inserts text into the focused field via clipboard paste + restore. Works across browsers, native apps, Terminal, and the Claude Code CLI.
- **Feedback**: on-screen indicator near the caret — recording (waveform) → processing (spinner) → dismiss — with the fallback positioning chain (caret → element frame → mouse → bottom-center).
- **Permissions**: first run detects/requests Microphone + Accessibility and deep-links to System Settings if missing.

### Acceptance criteria

- [ ] Fresh clone + one documented setup command builds `whisper.cpp`, fetches `medium.en`, and produces a launchable `.app` bundle (stable identity so permissions persist).
- [ ] App runs as menu-bar-only (no Dock icon).
- [ ] Holding the hotkey records; releasing inserts accurate, punctuated text at the caret in TextEdit.
- [ ] Same works in Chrome, Slack, VS Code, Terminal, and Claude Code CLI.
- [ ] Indicator shows record → process → dismiss near the caret, and falls back gracefully where caret bounds are unavailable.
- [ ] Prior clipboard contents are restored after insertion.
- [ ] Missing Mic/Accessibility permission is detected and the user is guided to grant it.
- [ ] `README` documents which Macs can run it and expected performance.

---

## Phase 2 — Recording controls & hotkey configuration

**User stories**: 3, 4, 21, 26, 29

### What to build

- Toggle mode (press to start / press to stop) alongside hold-to-talk; both bindings configurable via the config file.
- Esc-to-cancel an in-progress recording (no insertion).
- Max-duration auto-stop.

### Acceptance criteria

- [ ] Toggle and hold-to-talk both work and can be rebound via config.
- [ ] Esc during recording cancels with nothing inserted.
- [ ] Recording auto-stops at the configured max duration.
- [ ] Invalid/conflicting bindings are reported clearly.

---

## Phase 3 — Robustness, errors & model selection

**User stories**: 16, 27, 30

### What to build

- No-focused-field handling: keep transcript on the clipboard and notify rather than dropping it.
- Clear error surfaces: mic unavailable, model file missing (point to setup), transcription failure.
- Model selection across `tiny/base/small/medium .en` via config + a setup option to fetch a chosen size; app loads by path.

### Acceptance criteria

- [ ] Dictating with no editable field focused keeps text on the clipboard and shows a notification.
- [ ] Missing model / mic errors are actionable and point to the fix.
- [ ] User can switch model size via config/setup and the app uses it.
- [ ] Clipboard restore is reliable under rapid successive dictations.

---

## Phase 4 — Settings GUI & system integration (toward a real app)

**User stories**: 14, 15, 20, 22, 23, 24, 31

### What to build

- Minimal settings surface (menu-bar menu and/or small window): hotkey editing, model picker, mic device selection, sound-cue toggle, launch-at-login.
- Launch at login via `SMAppService`.
- Subtle start/stop sound cues (mutable).
- Mic device selection.
- Menu-bar polish; keep footprint small.

### Acceptance criteria

- [ ] Settings are editable from a GUI (no manual config-file editing required).
- [ ] Launch-at-login works after reboot.
- [ ] Sound cues play on start/stop and can be muted.
- [ ] A non-default microphone can be selected and is used.
- [ ] Idle CPU ~0% and low memory; app stays unobtrusive.

---

## Out of scope for this plan (later)

Packaged signed/notarized `.app` + auto-update; in-app model download store/UI; live streaming; multilingual; transcription history; custom dictionary; iOS.

## Verification

Work to each phase's acceptance criteria, demoing the slice end-to-end. Final pass: run the PRD's Verification checklist — clone → setup → dictate in 5+ apps incl. the CLI, clipboard safety, indicator fallback, cancel path, no-field path, latency on the M3 Max, and no network traffic during dictation.

## Unresolved questions

1. Default hotkeys OK? (hold = Right ⌥, toggle = ⌃⌥Space, cancel = Esc)
2. Min macOS target = 14 (Sonoma)? Apple-Silicon-only, or Intel best-effort too?
3. Build system: SwiftPM-only (CLI-buildable, no Xcode project) vs Xcode project? (SwiftPM keeps "clone and `make run`" cleanest.)
4. Models dir location: in-repo `./models` (simple, gitignored) vs `~/Library/Application Support`?
5. App/repo name — "VoiceType" placeholder, keep or rename?
