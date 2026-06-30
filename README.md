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
- **On-screen indicator** next to your cursor: a waveform while it listens, a
  spinner while it transcribes, then it disappears.
- **Works everywhere** by pasting (and restoring your clipboard afterward), so it
  works in browsers, native apps, terminals, and CLIs alike.
- **Menu-bar only** — a small 🎙️ icon, no Dock icon, stays out of your way.
- **100% private.** The only time it uses the internet is the one-time model
  download during setup.

---

## Will it run on my Mac?

- **Apple Silicon Mac (M1, M2, M3, M4 — any model from 2020 on):** ✅ ideal. The
  default model transcribes a sentence in about a second.
- **macOS 14 (Sonoma) or newer** required.
- **~2 GB free disk** for the default model.
- Intel Macs: works but CPU-only and slower; not a priority for v1.

<details>
<summary>Model sizes & speed (you can change the model later)</summary>

| Model       | Disk / RAM   | When to use                                  |
|-------------|--------------|----------------------------------------------|
| `tiny.en`   | ~75 MB       | Fastest, least accurate. Good for testing.   |
| `base.en`   | ~140 MB      | Light, low-RAM Macs.                          |
| `small.en`  | ~460 MB      | Good balance.                                 |
| `medium.en` | ~1.5 GB      | **Default.** Most accurate; instant on M-series. |

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
git clone <repository-url> voicetype
cd voicetype
```

(Replace `<repository-url>` with this project's Git URL. Every command after this
is run from inside the `voicetype` folder.)

### 3. Build it and download the speech model

```sh
make setup
```

This fetches the speech engine, downloads the default `medium.en` model
(**~1.5 GB — this part takes a while on the first run**), builds the app, and
packages it. Let it finish.

> Want a faster, smaller download to try things out first? Run
> `make setup MODEL=small.en` (or `tiny.en`) instead.

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

**Switch to a different model:**

```sh
make model MODEL=small.en      # downloads it
```

Then set `"modelPath"` in `config.json` to the new file (same folder, named
`ggml-small.en.bin`) and relaunch VoiceType.

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

After editing, relaunch VoiceType (quit from the menu, reopen from Applications).

| Setting               | What it does                                        |
|-----------------------|-----------------------------------------------------|
| `modelPath`           | Full path to the speech model `.bin` file.          |
| `hold`                | The hold-to-talk hotkey (see above).                |
| `maxRecordingSeconds` | Auto-stop after this many seconds (default 120).    |
| `trailingSpace`       | Add a space after each dictation (default off).     |
| `language`            | `en`.                                               |
| `threads`             | CPU threads; `0` = pick automatically.              |

---

## Troubleshooting

**“I granted Accessibility but it still says Not granted.”**
This happens after rebuilding the app: the app is re-signed and macOS no longer
recognizes the old permission. Reset it once and grant again:

```sh
pkill -x VoiceType                                  # quit the app
tccutil reset Accessibility com.local.VoiceType     # clear the stale grant
open /Applications/VoiceType.app                    # relaunch
```

Then re-grant Accessibility in **System Settings → Privacy & Security →
Accessibility** (remove any old "VoiceType" entry with the **–** button first,
then toggle the new one on). *(A permanent fix that survives rebuilds — signing
with a stable certificate — is on the roadmap.)*

**The hotkey does nothing.**
Make sure the menu says **Ready** (both permissions granted). If your chosen
combo still doesn't fire, try a different one (see *Changing the hotkey*). Avoid
hotkeys that include a normal key like Space — they get typed into your text.

**“Model missing” in the menu.**
The model file isn't where `config.json` points. Run `make setup` (or
`make model MODEL=medium.en`) and confirm `modelPath` matches the downloaded
file in `~/Library/Application Support/VoiceType/models/`.

**Text doesn't appear after I speak.**
Make sure a text field is actually focused (click into it first). Very short
recordings (a fraction of a second) are ignored on purpose.

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
and built purely with SwiftPM (no cmake). Its Metal shader is **embedded** into
the binary at build time (no Xcode Metal toolchain needed) and compiled on the
GPU at runtime, so the `.app` is self-contained. See
`plans/IMPLEMENTATION-NOTES.md` for the durable build/integration details.
