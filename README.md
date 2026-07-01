# VoiceType

Local, private, system-wide voice dictation for macOS. Hold a hotkey, speak,
and your words are transcribed **entirely on your Mac** with
[whisper.cpp](https://github.com/ggml-org/whisper.cpp) (GPU-accelerated) and
typed into whatever text field you're in — any browser, any app, the Terminal,
and the Claude Code CLI. Nothing is ever sent to the internet.

> **Status:** v1. You install it by building it on your own Mac (steps below).
> A ready-made download and an in-app model picker will come later.

---

## What it does

- **Hold-to-talk:** hold **Control + Shift**, speak, release — your words appear
  at the cursor.
- **Toggle mode:** press **⌃⌥Space** to start, press again to stop — for longer
  dictation without holding a key. Press **Esc** while recording to cancel.
- **On-screen indicator** next to your cursor: a waveform while it listens, a
  spinner while it transcribes, then it disappears.
- **Works everywhere** by pasting (and restoring your clipboard afterward), so it
  works in browsers, native apps, terminals, and CLIs alike.
- **Notifies you** on errors (mic unavailable, model missing, transcription
  failure) and when no text field is focused, instead of failing silently.
- **Menu-bar only** — a small 🎙️ icon, no Dock icon, stays out of your way.
- **100% private.** The only time it uses the internet is the one-time model
  download during setup.

---

## Will it run on my Mac?

- **Apple Silicon Mac (M1, M2, M3, M4 — any model from 2020 on):** ✅ ideal.
  Metal (GPU) accelerated; the default model transcribes a sentence in about a
  second.
- **Intel Mac:** ✅ supported. Runs CPU-only (no Metal), so it's slower — setup
  automatically picks a smaller model to keep it responsive.
- **macOS 14 (Sonoma) or newer** required.
- **~2 GB free disk** for the default model.

**Setup auto-detects your chip + RAM and picks a default model for you** — no
input needed. You can still override it (see
[Setup step 3](#3-build-it-and-download-the-speech-model) and
[Changing the model](#changing-the-model-or-hotkey)). What it picks:

| Your Mac      | RAM     | Auto-picked model |
|---------------|---------|-------------------|
| Apple Silicon | ≥ 16 GB | `medium.en`       |
| Apple Silicon | < 16 GB | `small.en`        |
| Intel         | ≥ 16 GB | `small.en`        |
| Intel         | 8–16 GB | `base.en`         |
| Intel         | < 8 GB  | `tiny.en`         |

<details>
<summary>Model sizes & speed (you can change the model later)</summary>

| Model       | Disk / RAM   | When to use                                  |
|-------------|--------------|----------------------------------------------|
| `tiny.en`   | ~75 MB       | Fastest, least accurate. Good for testing.   |
| `base.en`   | ~140 MB      | Light, low-RAM Macs.                          |
| `small.en`  | ~460 MB      | Good balance.                                 |
| `medium.en` | ~1.5 GB      | **Default on 16 GB+ Apple Silicon.** Most accurate; instant on M-series. |

On an Apple-Silicon Mac, every model runs faster than real time.
</details>

---

## Setup (start to finish)

You'll run a few commands in **Terminal** (open it from Spotlight: press ⌘-Space,
type "Terminal", hit Return). Copy-paste each block.

### 1. Install the build tools (one time)

```sh
xcode-select --install
```

A dialog appears — click **Install** and wait for it to finish (a few minutes).
If it says the tools are already installed, you're good.

### 2. Get the code

```sh
git clone https://github.com/ropats16/voicetype.git voicetype
cd voicetype
```

(Every command after this is run from inside the `voicetype` folder.)

### 3. Build it and download the speech model

```sh
make setup
```

This fetches the speech engine, then **auto-detects your chip + RAM and
downloads the matching model** (see the table above — on a typical Apple Silicon
Mac that's `medium.en`, **~1.5 GB, which takes a while on the first run**), and
finally builds and packages the app. Let it finish.

> Want a specific model instead of the auto-pick? Pass `MODEL=`, e.g.
> `make setup MODEL=small.en` (or `tiny.en`, `base.en`, `medium.en`).

### 4. Install the app

```sh
make install
```

This copies **VoiceType.app** to your Applications folder and opens it. Look for
a small **🎙️ microphone icon in your menu bar** (top-right of the screen). Click
it to see the app's status and controls.

### 5. Grant the two permissions

VoiceType needs two macOS permissions. Click the 🎙️ menu-bar icon to see their
status; both must say **Granted** before dictation works.

1. **Microphone** — so it can hear you. The first time you dictate, macOS asks
   for permission; click **Allow**.
2. **Accessibility** — so the hotkey works and it can type into other apps. Open
   **System Settings → Privacy & Security → Accessibility**, find **VoiceType**
   in the list, and turn its switch **on**. (The menu's "Accessibility: Not
   granted" line opens this screen for you.)

When both show **Granted**, the menu status changes to **Ready**. 🎉

> ⚠️ **If you just granted Accessibility but it still says "Not granted,"** see
> [Troubleshooting](#troubleshooting) below — there's a quick one-time reset.

### 6. Dictate!

Put your cursor in any text field, **hold Control + Shift**, speak a sentence,
then **release**. After a moment your words appear, with punctuation and
capitalization. Try it in Notes, Chrome, Slack, or the Terminal.

---

## Using VoiceType day to day

- **Hold Control + Shift** to record; **release** to transcribe and insert.
- Or **toggle**: press **⌃⌥Space** once to start, press again to stop — handy for
  longer passages where you don't want to hold a key down.
- **Press Esc while recording to cancel** — nothing is transcribed or inserted.
- Recording **auto-stops** after `maxRecordingSeconds` (default 120) so a
  forgotten recording can't run forever.
- The indicator near your cursor shows **listening → transcribing → done**.
- Your existing clipboard is restored after each dictation, so dictating never
  overwrites something you copied.
- Quit anytime from the 🎙️ menu (**Quit VoiceType**).

---

## Changing the model or hotkey

Settings live in a plain text file you can open from the menu
(**Open Config File…**) or at:

```
~/Library/Application Support/VoiceType/config.json
```

**Switch to a different model.** Your starting model was auto-selected at setup
from your chip + RAM; to change it, download another and point `config.json` at
it:

```sh
make model MODEL=small.en      # downloads it
```

Then set `"modelPath"` in `config.json` to the new file (same folder, named
`ggml-small.en.bin`) and relaunch VoiceType.

> Curious what setup would auto-pick for this Mac? Run
> `scripts/detect_hardware.sh` — it reports the detected arch, RAM, and the
> model it would choose (diagnostic only; it changes nothing).

**Change the hotkey.** The `hold` setting is the trigger. The default is a
pure-modifier combo (it types no character anywhere):

```json
"hold": { "keyCode": -1, "modifiers": ["control", "shift"] }
```

Other good no-character options (edit the `modifiers` list):
- `["control", "option"]` → ⌃⌥
- `["command", "shift"]` → ⌘⇧
- `["function", "shift"]` → fn+Shift *(note: the Globe/fn key is ignored on some Macs)*
- A single key: `{ "keyCode": 61, "modifiers": [] }` → hold **Right Option**

**Change the toggle key.** `toggle` is the press-to-start / press-to-stop hotkey.
Unlike `hold`, it fires on a single press, so it usually pairs a normal key with
modifiers. The default is ⌃⌥Space:

```json
"toggle": { "keyCode": 49, "modifiers": ["control", "option"] }
```

(`keyCode` 49 is Space.) Pick modifiers that aren't a normal typing combo so the
keypress isn't inserted into your text.

**Cancel key.** `cancelKeyCode` is the key that aborts an in-progress recording
(default `53` = Esc).

After editing, relaunch VoiceType (quit from the menu, reopen from Applications).
If a binding is empty, unmatchable, or `hold` and `toggle` collide, VoiceType
logs the problem at startup and the menu shows a **Config issue** warning.

| Setting               | What it does                                        |
|-----------------------|-----------------------------------------------------|
| `modelPath`           | Full path to the speech model `.bin` file.          |
| `hold`                | The hold-to-talk hotkey (see above).                |
| `toggle`              | The press-to-start / press-to-stop hotkey.          |
| `cancelKeyCode`       | Key that cancels a recording (default 53 = Esc).    |
| `maxRecordingSeconds` | Auto-stop after this many seconds (default 120).    |
| `trailingSpace`       | Add a space after each dictation (default off).     |
| `language`            | `en`.                                               |
| `threads`             | CPU threads; `0` = pick automatically.              |

---

## Troubleshooting

**“I granted Accessibility but it still says Not granted.”**
Setup signs the app with a **stable self-signed certificate**, so once you grant
Accessibility it should keep working across rebuilds. If it ever gets stuck
(e.g. you built once before the certificate existed), reset it once and grant
again:

```sh
pkill -x VoiceType                                  # quit the app
tccutil reset Accessibility com.local.VoiceType     # clear the stale grant
open /Applications/VoiceType.app                    # relaunch
```

Then re-grant Accessibility in **System Settings → Privacy & Security →
Accessibility** (remove any old "VoiceType" entry with the **–** button first,
then toggle the new one on).

**The hotkey does nothing.**
Make sure the menu says **Ready** (both permissions granted). If your chosen
combo still doesn't fire, try a different one (see *Changing the hotkey*). For
`hold`, prefer a pure-modifier combo — a bare normal key gets typed into your
text. For `toggle`, keep at least one modifier with the key for the same reason.

**“Model missing” in the menu.**
The model file isn't where `config.json` points. Run `make setup` (or
`make model MODEL=medium.en`) and confirm `modelPath` matches the downloaded
file in `~/Library/Application Support/VoiceType/models/`.

**Text doesn't appear after I speak.**
If no text field is focused, VoiceType copies the transcript to your clipboard
and shows a notification — click into a field first, or just paste with ⌘V.
Very short recordings (a fraction of a second) are ignored on purpose.

**Build failed.**
Confirm the build tools are installed (`xcode-select --install`) and you're on
macOS 14+ with an Apple-Silicon Mac.

**Check the engine without any of the UI/permissions** (handy sanity test):

```sh
.build/release/VoiceType --selftest \
  --model "$HOME/Library/Application Support/VoiceType/models/ggml-medium.en.bin" \
  --wav Sources/CWhisper/whisper.cpp/samples/jfk.wav
```

It should print the transcript of the sample audio.

---

## Privacy

Everything runs on your Mac. The only network request the app ever makes is the
one-time model download during setup. No accounts, no telemetry, no audio or text
leaves your machine.

---

## For developers

```sh
make run          # build (release) and run from the source tree
make build        # compile only
make package      # assemble dist/VoiceType.app
make install      # build + package + copy to /Applications
make clean        # remove build artifacts
```

whisper.cpp is vendored as a git submodule under `Sources/CWhisper/whisper.cpp`
and built purely with SwiftPM (no cmake).

**The build is arch-conditional** — `Package.swift` branches on the arch of the
machine running SwiftPM:

- **Apple Silicon (`arm64`):** the Metal build, unchanged from before Phase 5.
  whisper + ggml + the Metal backend, with the shader **embedded** into the
  binary at build time (no Xcode Metal toolchain needed) and compiled on the GPU
  at runtime, so the `.app` is self-contained.
- **Intel (`x86_64`):** a CPU-only build — no Metal at all; x86 CPU kernels built
  with AVX2/FMA/F16C plus the Accelerate/BLAS backend. `embed_metal_shader.sh`
  self-skips on x86, so `make`/`setup`/`package` need no arch branching.

Because the manifest branches on the **host** arch (not on any `--arch` flag),
to exercise the Intel path on an Apple Silicon Mac you must run the whole
toolchain under Rosetta:

```sh
arch -x86_64 swift build -c release
```

Don't use `swift build --arch x86_64` — that still runs the manifest as `arm64`
and selects the Metal branch. Smoke-test the resulting x86 binary with the
[`--selftest` check](#troubleshooting) (a plain `x86_64` binary runs under
Rosetta automatically).

See `plans/IMPLEMENTATION-NOTES.md` for the durable build/integration details.
