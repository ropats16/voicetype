# Yolk v2 — plan (grilling outcome, 2026-10-29)

Turn VoiceType into **Yolk**: cute, egg-mascot, fully local dictation + silent meeting transcription for macOS, handed out to friends as a case study. Free, MIT, open source.

Research backing: [research-distribution.md](research-distribution.md).

## Decisions

### Product
- **Mascot / name:** TBD in Phase 2 (#16). Want an animatable character w/ eyes, smile, rosy cheeks, hands + legs. Candidates: avocado, orange, peach, plum, egg ("Yolk"), original blob/ghost (no existing-IP likeness). Keep Yolk if it still wins.
- **Rename:** repo, app, bundle ID `voicetype` → Yolk in brand phase, before any friend installs (resets own TCC once).
- **Overlay:** draggable floating egg, remembers position, hidden until active by default. Opt-in "always visible" mini egg; click → start dictation / meeting. Persistent small recording egg during meetings (never record silently).
- **Meetings:** transcript split Me (mic) / Them (system audio). Start = auto-detect Zoom/Meet/Teams mic use → prompt "Record?"; manual fallback (menu, hotkey, egg click). Never auto-record.
- **Meeting pipeline:** audio streamed to disk continuously (crash-safe), chunked background transcription during call, final pass at end. Live captions = later polish.
- **Raw audio:** deleted after transcription by default; "keep audio" setting.
- **Summaries (later phase, optional):** on by default on macOS 26 via Apple Foundation Models (on-device, chunk + merge for ~4k ctx). Other Macs: opt-in OpenRouter, user picks model — explicit warning that text leaves the Mac.
- **Notes library:** Markdown files + metadata sidecar in user-chosen folder (Obsidian = point folder at vault). Add SQLite index only if search slows.
- **Dictation history:** saved to library as lightweight list, "copy again", auto-prune after N days, can disable.
- **Library window:** Dock icon shown only while library window is open; otherwise menu-bar only.
- **Languages:** English default; multilingual models optional.
- **Integrations:** Obsidian via folder (free). Notion etc. deferred.

### Platform / distribution
- **Channel:** direct only — Developer ID signed + notarized DMG, Sparkle 2 auto-update, own Homebrew tap. No Mac App Store (AX banned in sandbox; synthetic ⌘V rejected under 2.4.5 in 2026; no MAS dictation app auto-pastes).
- **Apple Developer ($99/yr):** self-sign during dev; pay right before shipping to friends.
- **Hardware:** distributed build Apple Silicon only (oldest target M1 8 GB). Intel = source build, whisper.cpp CPU.
- **Min macOS:** 14.2 (Core Audio process taps). macOS 26 features gated at runtime.
- **Model delivery:** in-app picker + download on first run; hardware auto-pick moves from `scripts/detect_hardware.sh` into app.
- **License:** MIT repo. Acknowledgements screen w/ Whisper, whisper.cpp/ggml, Sparkle (+ Parakeet CC-BY-4.0 if added) notices.

### Engine / performance
- Pluggable transcription engine (builds on existing `Transcriber` protocol).
- **Benchmark spike first:** whisper.cpp vs WhisperKit vs Apple SpeechAnalyzer vs Parakeet (FluidAudio), on M1 8 GB + newer M-series. Measure latency (short dictation), RTF + battery/heat (60-min meeting), RAM, first-load time, WER. Default chosen from data; whisper.cpp stays fallback.
- Baseline tuning regardless: keep model warm, VAD silence trim.
- **8 GB Macs are first-class:** in-app default model picked by RAM (fix: app default is medium.en regardless), quantized (q5/q8) variants in catalog, "keep warm" setting w/ idle unload on low RAM. Benchmark must run on M1 8 GB.
- Arch review findings: engine module → capture module → dictation session state machine (see /improve-codebase-architecture output, 2026-10-29).

### Security / privacy
- Hardened Runtime + notarization.
- Network allowlist only: Hugging Face model download (pinned SHA-256), Sparkle appcast (EdDSA-signed), opt-in telemetry ping, opt-in OpenRouter. Nothing else.
- Notes local; rely on FileVault.
- README **"Network activity"** section listing every host + when.
- `/cso` audit before first public release.

### Usage metrics (case study)
- GitHub release download counts + opt-in anonymous launch ping (e.g. TelemetryDeck), disclosed.

## Phases
0. **Research** — competitors (Granola, Superwhisper, Wispr Flow, MacWhisper, VoiceInk, Hex, Spokenly) features/UX/overlays; Reddit/HN complaints + gaps; "Yolk" name collision check (MAS, GitHub, domains).
1. **Architecture + perf** — `/improve-codebase-architecture` review; engine seam; benchmark spike; baseline tuning.
2. **Brand + overlay** — rename to Yolk, egg mascot assets/animations, draggable overlay, UI refresh.
3. **Distribution** — Developer ID, notarization, DMG, Sparkle, Homebrew tap, onboarding (permissions + model picker/download w/ checksum), Acknowledgements, README Network activity.
4. **Notes library + dictation history** — Markdown store, library window, Dock-icon toggle.
5. **Meetings** — Core Audio taps + mic, meeting detection prompt, chunked transcription, Me/Them transcript, recording indicator, audio retention setting.
6. **Summaries** — Foundation Models (macOS 26) + OpenRouter opt-in.
7. **Later** — live captions, Notion, more integrations.

Workflow: this plan → `/improve-codebase-architecture` → `/to-spec` → `/to-tickets` (GitHub issues + milestone per phase).

## Unresolved questions
- Dictation history prune window: 30 days?
- Meeting hotkey: which combo?
- Detect browser-based Meet (mic use by Chrome/Safari) or native apps only?
- Telemetry provider: TelemetryDeck ok?
