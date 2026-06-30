# VoiceType

Local, private, system-wide voice dictation for macOS. Hold a hotkey, speak,
and your words are transcribed **entirely on-device** with
[whisper.cpp](https://github.com/ggml-org/whisper.cpp) (Metal-accelerated) and
pasted into whatever text field is focused — any browser, any native app, the
Terminal, and the Claude Code CLI. Nothing leaves your machine.

> **Status:** v1, installed by cloning and building locally. A signed/notarized
> download and an in-app model picker come later.

---

## What it does

- **Hold-to-talk:** hold the hotkey (default **fn + Shift**) to record;
  release to transcribe and insert at your cursor.
- **On-screen indicator** near the caret: a live waveform while recording, a
  spinner while transcribing, then it disappears.
- **Universal insertion** via clipboard paste + restore — works everywhere,
  including terminals and CLIs. Your previous clipboard is restored afterward.
- **Menu-bar only** — no Dock icon, stays out of your way.
- **100% on-device.** The only network access is the one-time model download.

---

## Requirements

- **Apple Silicon Mac** (M1–M4). Intel is best-effort/CPU-only and not a v1
  priority.
- **macOS 14 (Sonoma) or newer.**
- **Xcode command-line tools** (`xcode-select --install`) to build.
- ~2 GB free disk for the default `medium.en` model.

### Which Macs can run it, and how fast?

`whisper.cpp` runs the Whisper model on the CPU and, on Apple Silicon, the GPU
via Metal. Apple Silicon Macs run every English model **faster than real-time**;
the practical limit is RAM for the larger models, not speed.

| Model       | Approx. RAM | Notes                                            |
|-------------|-------------|--------------------------------------------------|
| `tiny.en`   | 150–250 MB  | Fastest, least accurate.                         |
| `base.en`   | 250–400 MB  | Good for low-RAM/Intel Macs.                     |
| `small.en`  | 0.6–1 GB    | Solid balance.                                   |
| `medium.en` | 1.7–2.5 GB  | **Default.** Reliable accuracy; instant on M-series. |

- **Apple Silicon (8 GB):** comfortably up to `small.en`/`medium.en`.
- **Apple Silicon (16 GB+):** anything, instantly.
- **Intel (AVX2, ~2016–2020):** CPU-only; `tiny.en`/`base.en` usable, larger
  models sluggish.

On an M3 Max a typical sentence with `medium.en` transcribes in well under ~1.5s.

---

## Install

```sh
git clone <this-repo> voicetype && cd voicetype
make setup        # fetch whisper.cpp, download medium.en, build, package the .app
make install      # copy VoiceType.app to /Applications
open /Applications/VoiceType.app
```

To use a smaller/faster model:

```sh
make model MODEL=small.en      # downloads ggml-small.en.bin
# then point config.json's "modelPath" at it (see Configuration)
```

### Grant permissions (first run)

VoiceType needs two macOS permissions; the menu-bar menu shows their status and
links to the right Settings pane:

1. **Microphone** — to record your voice. You'll be prompted on first launch.
2. **Accessibility** — for the global hotkey, caret lookup, and synthetic paste.
   Open **System Settings → Privacy & Security → Accessibility** and enable
   **VoiceType**.

Grant both, and the menu-bar status flips to **Ready**. Then hold **fn + Shift**,
speak, and release.

> **Note on permissions persisting:** macOS ties these grants to the app's code
> signature. The build signs ad-hoc, so a *rebuild* may ask you to re-grant
> Accessibility. Installing once to `/Applications` and not rebuilding keeps the
> grants stable across launches and reboots.

---

## Configuration

Settings live in a JSON file you can edit (a GUI comes in a later phase):

```
~/Library/Application Support/VoiceType/config.json
```

Open it from the menu bar (**Open Config File…**). Keys:

| Key                   | Meaning                                                    |
|-----------------------|------------------------------------------------------------|
| `modelPath`           | Absolute path to the GGML model `.bin`.                    |
| `hold`                | Hold-to-talk binding (`keyCode`, `modifiers`).            |
| `maxRecordingSeconds` | Auto-stop after this many seconds (default 120).          |
| `trailingSpace`       | Append a space after each dictation (default `false`).    |
| `language`            | `en`.                                                      |
| `threads`             | Inference threads; `0` = auto.                            |

The default hold key is **fn + Shift** — a pure-modifier combo (`keyCode: -1`,
`modifiers: ["function","shift"]`) chosen so it never types a character into the
focused field. A single modifier like Right Option (`keyCode: 61`, no modifiers)
also works. Toggle mode, Esc to cancel, and full rebinding land in Phase 2.

---

## Privacy

All transcription happens on-device. The only outbound network request is the
one-time model download during `make setup`. No telemetry.

---

## Building / developing

```sh
make run          # build (release) and run from the source tree
make build        # just compile
make package      # assemble dist/VoiceType.app
make clean        # remove build artifacts
```

whisper.cpp is vendored as a git submodule under `Sources/CWhisper/whisper.cpp`.
Its Metal shader is embedded into the binary at build time (no Xcode Metal
toolchain required) and JIT-compiled at runtime, so there is nothing extra to
bundle into the `.app`.

To verify the engine without the UI or any permissions, run the diagnostic:

```sh
VoiceType --selftest --model <ggml.bin> --wav <16kHz.wav>
```
