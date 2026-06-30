# PRD: Local Whisper Speech-to-Text for macOS ("VoiceType")

## Context

The user wants frictionless, fully-private voice dictation that works **system-wide** on macOS — in any browser, any installed app, and the terminal/CLI — using **local compute only** (OpenAI Whisper running on-device via `whisper.cpp`). No cloud, no per-use cost, no data leaving the machine. macOS's built-in dictation is cloud-leaning and limited; commercial tools exist (Superwhisper, VoiceInk, MacWhisper) but the user wants their own lightweight, native, clean build.

The trigger: typing is slower than speaking, and the user wants to dictate into *any* text field with a single hotkey, see a clear indicator while it listens/processes, and have the text dropped in automatically.

Target machine: **Apple M3 Max, 48 GB RAM, macOS 26.3** — far more than enough; hardware is a non-issue for this user (see Hardware section). The app is still designed to degrade gracefully to weaker Macs.

## Problem Statement

As a Mac user, I want to speak into any text field instead of typing — in my browser, native apps, and the terminal — by holding (or toggling) a single hotkey, and have my words appear as text where my cursor is. I want it to run entirely on my own machine for privacy and zero cost, with a clean indicator so I always know when it's listening and when it's working, and it should be lightweight and stay out of my way.

## Solution

A small native macOS **menu-bar app** that runs quietly in the background. When the user presses their hotkey, the app records the microphone and shows a subtle indicator near the text cursor. On release (hold mode) or second press (toggle mode), it transcribes the audio locally with a Whisper model via `whisper.cpp` (Metal-accelerated), shows a brief processing spinner, then inserts the resulting text into whatever field is focused by pasting it (restoring the previous clipboard afterward). It works in any app that accepts text — Chrome, Safari, Notes, Slack, VS Code, Terminal, and Claude Code in the CLI — because it uses the universal paste mechanism rather than per-app integrations. Everything is on-device; the only network use is the optional one-time model download.

---

## User Stories

1. As a user, I want a menu-bar icon that shows the app is running, so that I know it's ready and can reach its controls.
2. As a user, I want to hold a global hotkey to start recording and release it to transcribe, so that dictation feels like a walkie-talkie ("push-to-talk").
3. As a user, I want an alternative toggle hotkey (press once to start, press again to stop), so that I can dictate long passages without holding a key.
4. As a user, I want both hotkey modes available and configurable, so that I can pick what fits each situation.
5. As a user, I want a visible indicator near my text cursor while recording, so that I'm confident the app is listening.
6. As a user, I want the indicator to show a live mic/waveform animation, so that I get feedback that my voice is being captured.
7. As a user, I want the indicator to switch to a processing spinner after I stop, so that I know it's transcribing and hasn't frozen.
8. As a user, I want the transcribed text inserted automatically at my cursor, so that I don't have to copy/paste manually.
9. As a user, I want my previous clipboard contents restored after insertion, so that dictation never clobbers what I had copied.
10. As a user, I want it to work in any browser (Chrome, Safari, Arc, Firefox), so that I can dictate into web text fields.
11. As a user, I want it to work in any native app (Notes, Slack, Mail, VS Code), so that I'm not limited to specific apps.
12. As a user, I want it to work in the Terminal and in the Claude Code CLI, so that I can dictate commands and prompts.
13. As a user, I want all processing to happen locally, so that my voice and text never leave my machine.
14. As a user, I want the app to be lightweight (small footprint, low idle CPU/RAM), so that it doesn't slow down my Mac.
15. As a user, I want a clean, native-looking UI, so that it feels like a first-class macOS app.
16. As a user, I want to choose which Whisper model to use (tiny/base/small/medium English), so that I can trade speed for accuracy.
17. As a user, I want the app to download my chosen model on first run with a progress bar, so that setup is simple.
18. As a user, I want medium.en accuracy by default, so that transcriptions are reliable out of the box.
19. As a user, I want a guided permissions setup (Microphone + Accessibility), so that I can grant what's needed without confusion.
20. As a user, I want to pick which microphone is used, so that I can use my preferred input device.
21. As a user, I want to remap the hotkeys, so that they don't conflict with my other shortcuts.
22. As a user, I want the app to launch at login, so that it's always ready without me starting it.
23. As a user, I want subtle start/stop sound cues, so that I get audio confirmation of recording state without looking at the screen.
24. As a user, I want to mute/unmute the sound cues, so that I can keep it silent in meetings.
25. As a user, I want Whisper's automatic punctuation and capitalization, so that the inserted text is clean.
26. As a user, I want recording to stop automatically if I hold too long or hit a max duration, so that runaway recordings don't happen.
27. As a user, I want a clear error if a model isn't downloaded or the mic is unavailable, so that I know how to fix it.
28. As a user, I want the indicator to fall back to a sensible position (mouse, then bottom-center) when the caret location can't be detected, so that I always get feedback even in apps that don't expose it.
29. As a user, I want to cancel an in-progress recording (e.g. press Esc), so that I can abort a mistaken dictation without inserting text.
30. As a user, I want the app to handle the case where no text field is focused gracefully (e.g. keep text on the clipboard / notify), so that nothing is lost.
31. As a user, I want quick access to settings from the menu-bar icon, so that I can change options easily.
32. As a user, I want the app to not appear in the Dock (menu-bar only), so that it stays unobtrusive.
33. As a user, I want low latency (≈1–2s or less for a sentence) on my M3 Max, so that dictation feels responsive.
34. As a user, I want to understand which Macs can run this and how fast, so that I know the limits before relying on it.

---

## Implementation Decisions

### App shape
- **Native Swift + SwiftUI**, menu-bar-only agent app (`LSUIElement` / accessory activation policy — no Dock icon).
- Target macOS 14 (Sonoma) or newer to use modern SwiftUI, `SMAppService` (launch-at-login), and current Accessibility APIs. (User is on macOS 26.3.)
- Distributed for **personal use** (developer-ID or ad-hoc signed). Public notarized release is out of scope for v1.

### Speech engine
- **`whisper.cpp`** embedded as a static library / `xcframework`, built with **Metal** acceleration (GPU). Optional Core ML encoder is a later optimization, not required.
- Models: GGML/GGUF Whisper **English** models — `tiny.en`, `base.en`, `small.en`, `medium.en`. **Default: `medium.en`.** User-selectable in settings.
- Models downloaded on demand from the public `ggml` Whisper model repository, stored in Application Support, with download progress + integrity check. App ships without bundling large model files.

### Audio capture
- `AVAudioEngine` tapping the selected input device, converted to **16 kHz mono Float32 PCM** (Whisper's expected format) into an in-memory buffer.
- Max recording duration cap (e.g. 60–120s) with auto-stop to avoid runaway captures.
- Selected mic device persisted in settings.

### Hotkeys (global)
- Global key monitoring via a **`CGEventTap`** (requires Accessibility permission).
- Two independently-configurable bindings: **hold-to-talk** (record while key down, transcribe on key up) and **toggle** (press to start, press to stop).
- Proposed defaults (configurable): hold-to-talk = **Right ⌥ (Option)**; toggle = **⌃⌥Space**. `Esc` while recording = cancel.

### Text insertion
- **Clipboard paste + restore**: save current `NSPasteboard` contents → write transcript → synthesize **⌘V** via `CGEvent` → restore prior clipboard after a short delay.
- Works universally including terminals and the Claude Code CLI.
- If no editable field is focused, keep the transcript on the clipboard and surface a notification rather than silently dropping it.

### On-screen indicator (near text cursor, with fallback)
- A borderless, non-activating floating panel (`NSPanel`, `.nonactivatingPanel`, ignores focus) that does not steal keyboard focus from the target field.
- **Primary positioning:** query the focused UI element via Accessibility — `AXUIElementCopyAttributeValue` for the focused element, then `kAXSelectedTextRangeAttribute` + `kAXBoundsForRangeParameterizedAttribute` to get caret bounds — and place the indicator just beside/below the caret.
- **Fallback hierarchy** (many web/Electron/terminal apps don't expose caret bounds): (1) caret bounds → (2) focused element's frame → (3) current mouse location → (4) fixed bottom-center HUD. Ensures feedback is always shown.
- States: **recording** (animated mic/waveform) → **processing** (spinner) → dismiss on insert. Clean, minimal, native styling.

### Permissions & onboarding
- First-run onboarding flow requesting **Microphone** (`AVCaptureDevice` authorization) and **Accessibility** (`AXIsProcessTrusted`, deep-link to System Settings). Accessibility is needed for the event tap, caret lookup, and synthetic paste.
- Clear status indicators showing which permissions are granted and how to fix missing ones.

### Settings window
- Hotkey bindings (both modes), model selection + download/manage, default insertion behavior, microphone selection, launch-at-login toggle, sound-cue on/off, max recording duration.

### System integration
- **Launch at login** via `SMAppService`.
- **Sound cues**: subtle start/stop chimes, mutable; respect Do-Not-Disturb where reasonable.

### Privacy
- 100% on-device transcription. The only outbound network request is the optional model download. No telemetry.

---

## Hardware Requirements & Mac Compatibility

(The user explicitly asked about hardware limits and which Macs can run this.)

**How it runs:** `whisper.cpp` runs the Whisper model on the CPU and, on Apple Silicon, the GPU via Metal. Apple Silicon Macs run all English models *faster than real-time*; the bottleneck is mostly RAM for the larger models, not speed.

**Approximate runtime memory footprint per model** (model weights + working memory):
- `tiny.en` ≈ 150–250 MB
- `base.en` ≈ 250–400 MB
- `small.en` ≈ 600 MB–1 GB
- `medium.en` ≈ 1.7–2.5 GB
- (`large-v3` ≈ ~4 GB — multilingual only, out of scope but for reference)

**Mac tiers:**
- **Apple Silicon (M1–M4, all variants; 2020+):** Ideal. Metal-accelerated, far faster than real-time even at `medium.en`. 8 GB Macs comfortably run up to `small.en`/`medium.en`; 16 GB+ runs anything. This is the recommended baseline.
- **Intel Macs (≈2016–2020, AVX2 CPUs):** Works CPU-only. `tiny.en`/`base.en` are usable; `small.en` is slower; `medium.en` is sluggish but functional. Fine for casual use, not snappy.
- **Older/low-RAM Macs (pre-2016, 8 GB or less):** Limited to `tiny.en`/`base.en`. Larger models will be slow or memory-pressured.

**For this user (M3 Max, 48 GB):** Zero constraints. `medium.en` transcribes a short sentence in well under a second to ~1.5s; even `large-v3` would run real-time. RAM is a non-factor. The app will feel instant.

**Practical minimum to ship against:** Any Apple Silicon Mac on macOS 14+. Intel support is "best effort" (CPU build) and not a v1 priority.

---

## Out of Scope (v1)

- **Live streaming / partial transcription** while speaking (transcribe-on-stop only).
- **Non-English / multilingual** models and auto language detection.
- **Transcription history** UI / searchable log.
- **Custom word replacements / personal dictionary** post-processing.
- **Voice commands / voice editing** ("delete that", "new line", etc.).
- **iOS / iPadOS** versions.
- **App Store distribution / public notarized release** and auto-update.
- **Core ML / ANE-optimized encoder** (Metal-only is enough for v1; can revisit for battery/latency).
- **Per-app insertion profiles** beyond the global paste/restore default.

---

## Further Notes

- **Why paste over simulated typing:** clipboard paste is fast and reliable across browsers, native apps, terminals, and the CLI; simulated per-character typing can drop characters and is slower. Clipboard is always restored.
- **Caret-position caveat:** "near the cursor" is best-effort. Native AppKit/text apps expose caret bounds well; many Electron, web, and terminal apps do not — hence the documented fallback chain down to a bottom-center HUD. This keeps the chosen UX without it breaking anywhere.
- **Accessibility is load-bearing:** the global hotkey tap, caret lookup, and synthetic ⌘V all depend on Accessibility permission. Onboarding must make granting it painless, since it's the most common setup friction point for tools like this.
- **Model storage:** keep models out of the app bundle so the app stays small (~5–15 MB); download on first run.
- **Battery:** `medium.en` is fine on the M3 Max; for laptops on battery, the model selector lets users drop to `small.en`/`base.en` to save power.

---

## Verification (how we'll confirm it works)

1. **Build & launch:** app appears as a menu-bar icon only (no Dock icon); idle CPU ~0% and low RAM.
2. **Permissions onboarding:** fresh run prompts for Microphone + Accessibility; granting them flips status to "ready".
3. **Model download:** selecting `medium.en` downloads with a progress bar and stores locally; re-launch reuses it.
4. **Hold-to-talk:** in TextEdit, hold the hotkey, speak a sentence, release → indicator shows record→process→dismiss, correct text appears at the caret, punctuation/caps present.
5. **Toggle mode:** press to start, speak, press to stop → same result without holding.
6. **Universality:** repeat the dictation test in Chrome (a web input), Slack, VS Code, **Terminal**, and **Claude Code CLI** — text lands correctly in each.
7. **Clipboard safety:** copy something first, dictate, confirm the original clipboard is restored afterward.
8. **Indicator positioning:** verify it appears near the caret in a native app, and falls back to mouse / bottom-center in an app that doesn't expose caret bounds.
9. **Cancel path:** start recording, press Esc → nothing is inserted.
10. **No-field path:** dictate with no editable field focused → transcript stays on clipboard + a notification appears.
11. **Sound cues + launch-at-login:** toggles take effect; app auto-starts after reboot.
12. **Latency check:** confirm a typical sentence on `medium.en` completes in ≈1–2s on the M3 Max.
13. **Privacy check:** with a network monitor, confirm no outbound traffic during dictation (only during model download).

---

## Unresolved Questions

1. Default hotkeys OK? (proposed: hold = Right ⌥, toggle = ⌃⌥Space, cancel = Esc) — or preferred combos?
2. Min macOS target = 14 (Sonoma) acceptable? Need Intel-Mac support at all, or Apple-Silicon-only?
3. App name "VoiceType" placeholder — keep or rename?
4. Want a notarized/shareable build later, or strictly personal/local?
5. Auto-insert a trailing space after each dictation, or none?
