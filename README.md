# VoiceType

Local, private, system-wide voice dictation for macOS. Hold a hotkey, speak,
and your words are transcribed **entirely on your Mac** with
[whisper.cpp](https://github.com/ggml-org/whisper.cpp) (GPU-accelerated) and
typed into whatever text field you're in — any browser, any app, the Terminal,
and the Claude Code CLI. Nothing is ever sent to the internet.

> **Status:** v1. You install it by building it on your own Mac (steps below).
> A ready-made download and in-app model downloads will come later.

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
- **Intel Mac:** ✅ supported. Runs CPU-only (no Metal), so it's slower — the
  app automatically picks a smaller model to keep it responsive.
- **8 GB Macs (e.g. M1 8 GB):** ✅ first-class — they get a light quantized
  model, and the model is unloaded when idle to give the RAM back.
- **macOS 14 (Sonoma) or newer** required.
- **~1 GB free disk** for the default model.

**The app picks a model for your chip + RAM by itself** (and setup downloads
that one) — no input needed. You can still pick another in **Settings** (it
switches instantly, no restart) or with `make setup MODEL=…`. What it picks:

| Your Mac      | RAM      | Auto-picked model | Download |
|---------------|----------|-------------------|----------|
| Apple Silicon | ≥ 32 GB  | `medium.en-q8_0`  | 823 MB   |
| Apple Silicon | 16–31 GB | `medium.en-q5_0`  | 539 MB   |
| Apple Silicon | 8–15 GB  | `small.en-q5_1`   | 190 MB   |
| Apple Silicon | < 8 GB   | `base.en-q5_1`    | 60 MB    |
| Intel         | ≥ 16 GB  | `small.en-q5_1`   | 190 MB   |
| Intel         | 8–15 GB  | `base.en-q5_1`    | 60 MB    |
| Intel         | < 8 GB   | `tiny.en-q5_1`    | 32 MB    |

If you set a non-English `language`, it picks the multilingual model of the
same size (e.g. `small-q5_1`). If the picked model isn't downloaded, the app
uses the best one you do have.

<details>
<summary>All models (you can change the model later)</summary>

Every model comes in **English-only** (`.en`) and **multilingual** (no `.en`)
versions, each also **quantized** (`-q5_*` smallest, `-q8_0` near-lossless) —
quantized models use about half the RAM for almost the same accuracy.

| Family           | Full     | q8_0    | q5      | When to use                                 |
|------------------|----------|---------|---------|---------------------------------------------|
| `tiny`           | 78 MB    | 44 MB   | 32 MB   | Fastest, least accurate. Good for testing.  |
| `base`           | 148 MB   | 82 MB   | 60 MB   | Light, low-RAM Macs.                         |
| `small`          | 488 MB   | 264 MB  | 190 MB  | Good balance; the 8 GB default.              |
| `medium`         | 1.5 GB   | 823 MB  | 539 MB  | Most accurate English; the 16 GB+ default.   |
| `large-v3-turbo` | 1.6 GB   | 874 MB  | 574 MB  | Multilingual only; best for other languages. |

Ids look like `small.en-q5_1`, `medium-q8_0`, `large-v3-turbo-q5_0` (medium and
large use `q5_0`, the rest `q5_1`); `large-v3-q5_0` is also available. The full
list with pinned SHA-256 checksums is in `scripts/model_catalog.sh`. On an
Apple-Silicon Mac, every model runs faster than real time.
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
downloads the matching model** (see the table above — on a 16 GB Apple Silicon
Mac that's `medium.en-q5_0`, **~540 MB**), checks its SHA-256, and finally
builds and packages the app. Let it finish.

> Want a specific model instead of the auto-pick? Pass `MODEL=`, e.g.
> `make setup MODEL=small.en-q5_1` (or `medium.en`, `small` for multilingual, …).

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
- Recording **auto-stops** after the max dictation length (Settings; default
  10 min, or "No limit", which still stops at 30 min) so a forgotten recording
  can't run forever. A notification tells you when that happens.
- The indicator near your cursor shows **listening → transcribing → done**.
- Your existing clipboard is restored after each dictation, so dictating never
  overwrites something you copied. (A password-manager copy isn't put back, so
  its auto-clear still holds — the dictation stays on the clipboard instead.)
- Quit anytime from the 🎙️ menu (**Quit VoiceType**).

---

## Changing the model or hotkey

Settings live in a plain text file you can open from the menu
(**Open Config File…**) or at:

```
~/Library/Application Support/VoiceType/config.json
```

**Switch to a different model.** By default the app picks one for your chip +
RAM (**Automatic** in Settings). To use another, download it, then pick it in
**Settings → Model** — it switches right away, no restart (a dictation already
being transcribed finishes on the old model):

```sh
make model MODEL=small.en-q8_0   # downloads it and checks its checksum
```

Or set `"model": "small.en-q8_0"` in `config.json`. Models you haven't
downloaded show under **Not downloaded** in Settings with the command to fetch
them. Downloads land in a `.part` file and only get their real name once
complete and checksum-verified. A file that doesn't match its published SHA-256
is refused; the first use of a new file shows **Verifying…** while it's hashed
(once — the result is cached). If a switch fails, VoiceType keeps (or goes back
to) the model it was using and Settings says why.

**Language.** English-only (`.en`) models always transcribe English. With a
multilingual model, pick the language in Settings (or `"language": "de"`, or
`"auto"` to detect it each time).

**Keep model loaded.** Automatic by default: kept loaded, except on Macs with
8 GB or less, where the model is unloaded after `modelIdleMinutes` (default 5)
without a dictation and reloaded as soon as you start the next recording (it is
never unloaded mid-recording). Settings offers Automatic / Keep loaded /
Unload when idle.

> Curious what the app would auto-pick for this Mac? Run
> `scripts/detect_hardware.sh` — it reports the detected arch, RAM, and the
> model (diagnostic only; it changes nothing). The app logs its pick at launch.

**Where models live.** `~/Library/Application Support/VoiceType/models/`. To
relocate everything (config, models), set `VOICETYPE_APP_SUPPORT` to another
folder — the app (when launched from that shell, e.g. `swift run`) and every
script honour it the same way, using `$VOICETYPE_APP_SUPPORT/models`.

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

Modifier names are case-insensitive and accept aliases: `control`/`ctrl`,
`option`/`alt`, `shift`, `command`/`cmd`, `function`/`fn`/`globe`. Single-key
holds work with the sided modifiers: Left/Right ⌃ (59/62), ⌥ (58/61), ⇧ (56/60),
⌘ (55/54). Easiest of all: Settings → Hotkeys → Record.

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
| `engine`              | Speech engine: `whisper` (default, whisper.cpp, any Mac); `whisperkit` (Core ML, Apple Silicon; models via `make whisperkit-model WHISPERKIT=<id>`); `parakeet` ("Turbo": Apple Silicon, English + 24 EU languages, picked explicitly, not under auto-detect; model via `make parakeet-model`); `apple-speech` (macOS 26; models managed by macOS, downloaded from Settings). If it can't run on this Mac or in the chosen language, VoiceType uses whisper and says why (the setting is kept). |
| `model`               | whisper's model: `auto` (default: pick for this Mac) or a model id, e.g. `small.en-q5_1`. |
| `modelPath`           | A specific whisper model `.bin` file; overrides `model` when set (default empty). |
| `engineModels`        | Other engines' model picks by engine id, e.g. `{"whisperkit": "auto"}` (unset = `auto`). |
| `keepModelWarm`       | Keep the model loaded (`true`) or unload it when idle (`false`). Unset = automatic: unload only on ≤ 8 GB Macs. |
| `modelIdleMinutes`    | Idle minutes before unloading, when not kept warm (default 5). |
| `hold`                | The hold-to-talk hotkey (see above).                |
| `toggle`              | The press-to-start / press-to-stop hotkey.          |
| `cancelKeyCode`       | Key that cancels a recording (default 53 = Esc).    |
| `maxRecordingSeconds` | Auto-stop after this many seconds (default 600; `0` = no limit, capped at 30 min). |
| `trailingSpace`       | Add a space after each dictation (default off).     |
| `language`            | `en` (default), another code like `de`, or `auto`. English-only models always use `en`. |
| `threads`             | CPU threads; `0` = auto (performance cores, max 8). |
| `keepMicWarm`         | Keep the mic on from launch (default off: it stays on 30 s after each dictation). |

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
The model the app wants isn't downloaded. The menu names it: run the
`make model MODEL=…` it shows (or pick a downloaded model in Settings). If you
set `modelPath`, confirm it points at a real file.

**“Model failed to load.”**
Usually a corrupt or incomplete download (it failed its checksum). Delete the
file from the models folder and run `make model MODEL=<name>` again.

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
arch -x86_64 swift build -c release --manifest-cache none
```

Don't use `swift build --arch x86_64` — that still runs the manifest as `arm64`
and selects the Metal branch. `--manifest-cache none` matters too: SwiftPM caches
the compiled manifest by content, not by arch, so a prior `arm64` build can
otherwise shadow the x86 branch and link-fail on duplicate symbols (real Intel
Macs are unaffected — they only ever compile the manifest as x86). Smoke-test the
resulting x86 binary with the [`--selftest` check](#troubleshooting) (a plain
`x86_64` binary runs under Rosetta automatically).

See `plans/IMPLEMENTATION-NOTES.md` for the durable build/integration details.

### Benchmarking an engine

`VoiceType --bench` runs a speech engine over fixed audio fixtures, through the
same engine interface the app uses, and reports dictation latency (p50/p90),
real-time factor on ~10 min of audio, peak memory, model load time and word
error rate — as a table and a JSON file you can compare across Macs:

```sh
bash scripts/fetch_bench_fixtures.sh       # one time: ~331 MiB download → .bench/fixtures
make build
.build/release/VoiceType --bench --git-sha "$(git describe --always --dirty)" \
  --model "$HOME/Library/Application Support/VoiceType/models/ggml-medium.en.bin"
```

See [`plans/benchmark.md`](plans/benchmark.md) for options, what each number
means, the JSON schema, fixture licenses, and how to add an engine.
