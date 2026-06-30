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

## Phase 5 — Hardware-aware setup & Intel support

**User stories**: 16, 34 (+ new: Intel Macs are usable)

### What to build

Auto-detect the machine at setup time and provision the **right model + the right build packages** for that chip — while keeping the Apple-Silicon path exactly as it is today (no new packages on Silicon). Intel Macs become first-class via a CPU-only build. Manual model override is preserved.

- **Detection** (`scripts/detect_hardware.sh`, pure shell): architecture (`uname -m` → `arm64` vs `x86_64`), chip (`sysctl -n machdep.cpu.brand_string`), RAM (`sysctl -n hw.memsize`). Emits the recommended default model and whether the Metal path applies.
- **Auto-pick default model** (overridable) — by chip + RAM:

  | Hardware | Default model |
  |---|---|
  | Apple Silicon, ≥16 GB | `medium.en` (today's default) |
  | Apple Silicon, 8 GB | `small.en` |
  | Intel, ≥16 GB | `small.en` |
  | Intel, 8 GB | `base.en` |
  | Intel, <8 GB / very old | `tiny.en` |

- **Modular, arch-conditional `Package.swift`** (the load-bearing piece — the manifest is Swift compiled for the host, so it branches on the build machine's chip):
  - `#if arch(arm64)` → **byte-for-byte today's `CWhisper` target**: Metal backend, `ggml-cpu/arch/arm/*`, embedded Metal shader. Unchanged; no new dependencies.
  - `#else` (x86_64) → CPU build: `ggml-cpu/arch/x86/*` sources (already vendored), **Metal backend excluded** (no `GGML_USE_METAL`, no `ggml-metal/*`, no embedded shader), keep BLAS/Accelerate (Accelerate ships on Intel Macs), add x86 CPU flags (AVX2/FMA/F16C). Executable target drops the `Metal`/`MetalKit` framework links on x86.
- **Setup flow** (`setup.sh` / `Makefile`): run detection first; on Silicon run the Metal `embed` step + Metal build as now; on Intel **skip the embed step** and do the CPU build; download the auto-picked model. `make embed`/`build` become arch-aware (embed is a no-op on x86).
- **Manual override preserved**: `modelPath` in config and `make model MODEL=…` still switch models at any time (Phase 3 mechanism). Auto-pick only sets the *default*.
- **Docs**: update the README compatibility section — Intel is now supported (CPU-only, smaller models), and setup auto-selects the model; document the override.

### Acceptance criteria

- [ ] Setup auto-detects chip + RAM and picks an appropriate default model with no user input.
- [ ] On Apple Silicon the build is identical to today's Metal path — no new packages/sources/defines added to the arm64 branch.
- [ ] On Intel (x86_64) the project builds and transcribes **CPU-only** (no Metal), verified at minimum by an `--arch x86_64` build run under **Rosetta on Apple Silicon**, and ideally on real Intel hardware.
- [ ] The user can still override the model via config / `make model` after setup.
- [ ] README documents auto-detection, the Intel/CPU path, and the override.

### Notes / risks

- **Verification without an Intel Mac:** `swift build --arch x86_64` + run under Rosetta 2 on the M3 Max proves the x86 build compiles and transcribes (correctness, not representative perf). Real Intel hardware is the final smoke test (a friend's machine).
- **Intel = CPU-only by design.** Some Intel Macs expose a Metal GPU, but ggml's Metal backend targets Apple-Silicon unified memory and is fragile elsewhere — out of scope; the Intel path stays on Accelerate/BLAS CPU.
- **macOS floor unchanged** (14+); independent of chip.

---

## Out of scope for this plan (later)

Packaged signed/notarized `.app` + auto-update; in-app model download store/UI; live streaming; multilingual; transcription history; custom dictionary; iOS.

## Verification

Work to each phase's acceptance criteria, demoing the slice end-to-end. Final pass: run the PRD's Verification checklist — clone → setup → dictate in 5+ apps incl. the CLI, clipboard safety, indicator fallback, cancel path, no-field path, latency on the M3 Max, and no network traffic during dictation.

## Unresolved questions

1. Default hotkeys OK? (hold = Right ⌥, toggle = ⌃⌥Space, cancel = Esc)
2. ~~Min macOS target = 14 (Sonoma)? Apple-Silicon-only, or Intel best-effort too?~~ → **Resolved:** macOS 14+; Intel supported CPU-only via **Phase 5**.
3. Build system: SwiftPM-only (CLI-buildable, no Xcode project) vs Xcode project? (SwiftPM keeps "clone and `make run`" cleanest.)
4. Models dir location: in-repo `./models` (simple, gitignored) vs `~/Library/Application Support`?
5. App/repo name — "VoiceType" placeholder, keep or rename?
6. Phase 5 model thresholds — Intel ≥16 GB default `small.en` (accuracy) vs `base.en` (snappier)? And Apple-Silicon 8 GB → `small.en` vs keep `medium.en`?
