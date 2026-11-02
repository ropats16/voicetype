# Research: licensing, App Store viability, distribution, meeting audio, ASR alternatives

Date: 2026-10-29. Sources are primary where possible. Confidence: H/M/L. **UNCERTAIN** marks open points.

## TL;DR
- Licensing is fine. Whisper code and weights, whisper.cpp, and the HF ggml weights are all MIT. Runtime download is OK for free or paid apps, including the App Store. The only obligation is to ship the MIT notices. (H)
- The Mac App Store is effectively a dead end for the core UX as built. AX (reading the focused element, AXManualAccessibility) is sandbox-incompatible. Cmd-V via CGEventPost works technically in the sandbox, but App Review rejected it under 2.4.5 in 2026. Spokenly says *every* MAS dictation app lacks auto-paste. (H on technical, M on review)
- Recommended path: Developer ID + notarization ($99/yr), with Sparkle, a DMG, and optionally a Homebrew cask. Homebrew now requires notarization.
- Meeting audio: use Core Audio process taps (macOS 14.2+, "system audio recording" permission only, no screen access). Fall back to ScreenCaptureKit only if <14.2 is needed. The app's min target is already macOS 14.
- ASR: Parakeet TDT v3 via FluidAudio is the fastest (~190x RTF on M4 Pro), but covers 25 European languages only. WhisperKit keeps Whisper's ~99 languages. Apple SpeechAnalyzer is free, system-managed, and streaming, but requires macOS 26 and fewer locales.

---

## 1. Licensing
- **OpenAI Whisper**: README says "Whisper's code and model weights are released under the MIT License"; LICENSE "Copyright (c) 2022 OpenAI". (H) https://github.com/openai/whisper , https://github.com/openai/whisper/blob/main/LICENSE
- **whisper.cpp**: MIT, "Copyright (c) 2023-2026 The ggml authors". (H) https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE
- **HF `ggerganov/whisper.cpp` ggml weights**: repo license tag MIT. Described as "OpenAI's Whisper models converted to ggml format". (H) https://huggingface.co/ggerganov/whisper.cpp
- **Redistribution / runtime download**: MIT allows commercial use, redistribution, and sale. This holds for bundling or downloading at runtime, in free, paid, and App Store apps. MIT has no App Store incompatibility, unlike GPL. (H)
- **Attribution obligation**: include the copyright and permission notice "in all copies or substantial portions". In practice, add an Acknowledgements/About screen or a bundled LICENSES file that lists the OpenAI Whisper (MIT), whisper.cpp/ggml (MIT), and Sparkle (MIT) notices. (H)
- **Note**: downloading from the HF CDN at runtime is fine for a small user base. Hard-coded HF URLs could rate-limit or move, so consider mirroring the files on GitHub Releases or R2. (M, opinion)
- **If switching models**: Parakeet v3 is **CC-BY-4.0**, so it needs attribution to NVIDIA and is commercial-OK. https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 . FluidAudio is Apache-2.0 (keep the NOTICE). WhisperKit is MIT.

## 2. Mac App Store sandbox compatibility
DTS (Quinn) mapping, Mar 2026: three TCC privileges. **PostEvent** (CGEventPost) and **Accessibility** both appear under *Accessibility* in Settings. **ListenEvent** (CGEventTap) appears under *Input Monitoring*. "The APIs gated by the Accessibility privilege are not compatible with the App Sandbox. The APIs gated by the other two privileges *are* compatible." (H) https://developer.apple.com/forums/thread/820594

| Feature | Sandbox technically | App Review | Conf |
|---|---|---|---|
| (1) CGEventTap `.listenOnly` hotkey (the app already uses listenOnly) | Works with Input Monitoring via `CGRequestListenEventAccess`. Quinn: "I regularly test this." https://developer.apple.com/forums/thread/780626 | Probably OK. No known rejections found. | H tech / M review |
| (1b) Current gating on `AXIsProcessTrusted` | Must change to `CGPreflightListenEventAccess`/`CGRequestListenEventAccess`. AX trust prompt never appears in the sandbox. https://developer.apple.com/forums/thread/810677 | n/a | H |
| (2) AXUIElementCreateSystemWide / focused element / AXManualAccessibility | **Not possible** without temporary-exception entitlements. "DTS doesn't support folks using general accessibility APIs in sandboxed apps." https://developer.apple.com/forums/thread/780626 , https://developer.apple.com/forums/thread/794253 | Temp exceptions are rarely granted for AX. Treat as no. | H |
| (3) Pasteboard + CGEventPost Cmd-V | Works with PostEvent via `CGRequestPostEventAccess`/`CGPreflightPostEventAccess`. https://developer.apple.com/forums/thread/708652 | **Rejected**: a sandboxed clipboard manager doing exactly this was rejected twice under **2.4.5** ("Accessibility features should not be used for non-accessibility purposes"). Unresolved as of Sep 2026, and another dev reported the same rejection. https://developer.apple.com/forums/thread/820594 | H tech / M-H review |

- **Grandfathered or inconsistent**: some MAS clipboard apps (Maccy, Paste) still advertise auto-paste with Accessibility permission. https://apps.apple.com/us/app/maccy/id1527619437 , https://pasteapp.io/help/direct-paste-50 . **UNCERTAIN**: these may be older approvals, and review appears inconsistent.
- **Dictation-app precedent**: Spokenly docs say "The Mac App Store version of Spokenly can't paste text automatically ... App Store rules don't allow it to use Accessibility". The workaround: the user presses Cmd-V, which stops dictation and pastes. (H) https://spokenly.app/docs/mac-app-store
- **Guideline text**: 2.4.5(i) requires the sandbox, 2.4.5(iv) forbids downloading code/resources that add functionality, and 2.4.5(vii) requires MAS-only updates, so Sparkle is not allowed. 2.5.14 requires consent and a visible indicator when recording. https://developer.apple.com/app-store/review/guidelines/
- **A possible MAS-lite build**: sandboxed, listen-only tap, clipboard write only, user pastes manually, no AX context. This matches what Spokenly and MacWhisper ship on the MAS. Not worth it for friends-only distribution.

## 3. System audio capture for meeting transcription
- **Core Audio process taps** (`CATapDescription` + `AudioHardwareCreateProcessTap`, then an aggregate device and IOProc).
  - macOS **14.2+**. (H) https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)
  - Requires `NSAudioCaptureUsageDescription`. The prompt appears on the first start of an aggregate device containing a tap. https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
  - Can target specific PIDs (e.g. Zoom, the Chrome helper), or do a global tap that excludes processes.
  - The permission is "system audio recording" (Settings > Privacy & Security > Screen & System Audio Recording, audio-only section). It does not grant screen access. https://nonstrict.eu/recordkit/guides/system-audio-recording.html
  - Gotchas:
    - There is **no public API to preflight or request** this permission. AudioCap uses private TCC calls, which is not MAS-safe. https://github.com/insidegui/AudioCap
    - A missing plist key means silent zero buffers. https://dev.to/nickdelv/2000-buffers-of-nothing-3i8
    - Xcode's INFOPLIST_KEY_ build setting drops the key, so add it to Info.plist manually.
  - On macOS 26, the Screen Recording permission also covers Core Audio system audio (nonstrict). (M)
  - Sandbox: **UNCERTAIN, probably works**. Community POCs run sandboxed with only the plist key. Some add `com.apple.security.device.audio-input`. No Apple statement. https://github.com/sbetko/catap
  - Does not handle the mic. Capture the mic separately with AVAudioEngine and handle echo yourself. https://www.recall.ai/blog/how-to-access-to-system-audio
- **ScreenCaptureKit audio**
  - SCK is macOS 12.3+. `capturesAudio` is macOS 13+, and `captureMicrophone` is macOS 15+. https://developer.apple.com/videos/play/wwdc2024/10088
  - Needs the full **Screen Recording** permission, even for audio-only, because the stream must target a display, window, or app. The app must restart after the grant (nonstrict).
  - Sequoia added periodic (monthly) re-approval nags for screen capture. https://tidbits.com/2024/08/19/apple-reduces-excessive-sequoia-permission-requests-shifts-to-monthly
  - Sandbox-compatible (H). Worse UX for an "audio-only" product.
- **What Granola uses**
  - Granola requires macOS 13 but "works best on 14.2+". https://docs.granola.ai/article/setting-up-granola-for-the-first-time
  - It asks for Mic + "Screen & System Audio Recording". https://www.granola.ai/blog/granola-cisco-webex-bot-free-meeting-notes
  - Inference (**M, not confirmed by Granola**): Core Audio taps on 14.2+, SCK fallback on 13–14.1. This is the same pattern as RecordKit, which defaults to Core Audio on 14.2+ and SCK below.
- **Recommendation**: Core Audio taps plus the mic via AVAudioEngine. The app is already at min macOS 14, so either bump to 14.2 or gate the feature. Granola-style "silent" capture still requires a visible recording indicator. This is a legal/consent concern, and 2.5.14 if the app is ever on the MAS.

## 4. Downloading ML models after install (2.5.2 / 2.4.5(iv))
- 2.5.2 forbids downloading "code which introduces or changes features". 2.4.5(iv) forbids downloading "additional code, or resources to add functionality or significantly change the app". https://developer.apple.com/app-store/review/guidelines/
- DTS, Jul 2025: "updating your app's ML models after installation isn't in conflict with App Store guidelines. There are existing apps that depend on this behavior." It still recommends confirming with App Review. (M-H) https://developer.apple.com/forums/thread/793131
- Precedent: MacWhisper's MAS twin, "Whisper Transcription", has users pick and download Whisper models on first launch. https://podfeet.com/blog/?p=28907 . Apple's own SpeechAnalyzer downloads models via AssetInventory.
- Verdict: model weights are data, so this is allowed. Keep the inference code in the binary and show the download UI in the review build. (M-H)

## 5. Competitors' distribution

| App | Channel | MAS feature-limited? | Engine / notes |
|---|---|---|---|
| MacWhisper | Direct (Gumroad, lifetime key). MAS as "Whisper Transcription" (subscription) | **Yes**: direct-only "dictate into any text field", meeting detection, all AI providers, CLI, MDM. https://docs.macwhisper.com/article/40-macwhisper-whisper-transcription-difference | whisper.cpp + ggml models |
| Spokenly | Direct + MAS | **Yes**: MAS has no auto-paste, so the user presses Cmd-V. https://spokenly.app/docs/mac-app-store | |
| Superwhisper | Direct download from superwhisper.com (Accessibility needed to paste). https://superwhisper.com/docs/get-started/quickstart . The App Store listing is iOS-only. https://apps.apple.com/us/app/superwhisper/id6471464415 . Third-party claims of a Mac MAS version are **UNCERTAIN/likely wrong**. | n/a | |
| VoiceInk | Direct (tryvoiceink.com, paid license). Source is GPLv3 on GitHub. Docs list only website install, and Accessibility is used for paste. https://tryvoiceink.com/docs/installation | No MAS found (**M**) | whisper.cpp, Parakeet |
| Wispr Flow | Direct DMG/PKG. Needs Mic + Accessibility. macOS 12+. https://docs.wisprflow.ai/articles/1036674442-supported-devices-and-system-requirements | No MAS found (M) | Cloud ASR |
| Hex | Open source **MIT**. DMG + `brew install --cask kitlangton-hex`. Apple Silicon only. Accessibility for paste. https://github.com/kitlangton/Hex | n/a | Parakeet TDT v3 (FluidAudio) + WhisperKit. Closest analogue to this app. |
| Aiko | **MAS only** ($24). File/recording transcription, **no live dictation**. https://sindresorhus.com/aiko | n/a | Whisper large-v2 |
| Granola | Direct DMG (also a Homebrew cask). Not on MAS. macOS 13+. https://docs.granola.ai/article/setting-up-granola-for-the-first-time | n/a | OS-level audio capture, cloud transcription |

- **No MAS app was found with working system-wide auto-paste dictation.** Spokenly states it applies to all MAS dictation apps. (M-H)

## 6. Direct distribution
- **Cost**: Apple Developer Program costs **$99/yr**. Developer ID signing and notarization are included. https://developer.apple.com/programs/
- **Notarization**: requires a Developer ID Application cert and Hardened Runtime. Submit with `xcrun notarytool submit --wait`, then `xcrun stapler staple` the .app or DMG. Do this for every release. (H, standard Apple flow)
  - The app needs Hardened Runtime entitlements for mic access (`com.apple.security.device.audio-input`) and possibly none else.
  - whisper.cpp's Metal shaders compile at runtime, which is fine. If you dlopen unsigned libs, you would need `disable-library-validation`, so avoid that.
- **Sparkle 2**: MIT. Works for Developer ID apps (sandboxing optional). Updates are signed with EdDSA keys (`generate_keys`, `sign_update`). It is **not allowed on MAS** per 2.4.5(vii). https://sparkle-project.org/documentation/ , https://sparkle-project.org/documentation/sandboxing/
- **Homebrew cask**
  - Homebrew 5.0.0 (Nov 2025): "Casks without codesigning are deprecated". "We will disable all Homebrew/homebrew-cask casks that fail Gatekeeper checks in **September 2026**". `--no-quarantine` is deprecated. https://brew.sh/2025/11/12/homebrew-5.0.0/
  - The official tap therefore needs **signed + notarized** apps (H).
  - Notability: ≥75 stars, 30 forks, or 30 watchers. Self-submitted casks need **225 stars, 90 forks, or 90 watchers**, and the repo must be at least 30 days old. https://docs.brew.sh/Package-Acceptance-Policy
  - Alternative: your own tap (`brew tap ropats16/tap`), which has no notability bar. Quarantine is still applied, so unsigned apps still hit Gatekeeper. (M)
- **Unsigned / ad-hoc for friends**
  - Apple Silicon requires at least an ad-hoc signature to run arm64. SwiftPM/linker adds one automatically.
  - Sequoia removed Control-click > Open as a Gatekeeper override. Users must go to **System Settings > Privacy & Security > "Open Anyway"**, then authenticate. This is a one-time step per app version. https://developer.apple.com/news/?id=saqachfa (Aug 6 2024), https://www.idownloadblog.com/apple-macos-sequoia-gatekeeper-change-install-unsigned-apps-mac/
  - Same behavior assumed on macOS 26 (**M**: no reversal found).
  - Alternative for technical friends: `xattr -dr com.apple.quarantine /Applications/VoiceType.app`.
  - Reports that 15.1 fully blocks unsigned apps are **unconfirmed/likely wrong**. https://www.osnews.com/story/141055/
- **Big practical issue with ad-hoc signing**: TCC grants (Accessibility, Input Monitoring, Mic) are pinned to the cdhash for ad-hoc signed code. **Every update silently revokes Accessibility**: the app still shows as ticked in Settings, but it is not trusted. A stable Developer ID (or even a stable self-signed cert) keeps the designated requirement constant, so grants survive updates. (M: secondary sources, consistent with known TCC behavior.) https://nickboy-github-io.pages.dev/posts/tcc-cdhash-trap/
  - A free middle ground for friends: a self-signed code-signing cert, used consistently. It fixes TCC persistence but not Gatekeeper. (M)

## 7. Faster on-device ASR on Apple Silicon

| Engine | License | Speed | Languages | Streaming | Min OS |
|---|---|---|---|---|---|
| whisper.cpp (current) | MIT | Baseline; Metal/CoreML encoder option | ~99 (Whisper) | Chunked/pseudo | — |
| **WhisperKit** (Argmax) | MIT (Argmax OSS) | Large-v3-turbo recommended. ANE-optimized CoreML. No headline RTF in README. | ~99 (Whisper) | Yes (`--stream`, SSE server). Real-time + speaker labels are in the paid Pro SDK. | Package: macOS 14 | https://github.com/argmaxinc/WhisperKit |
| **Parakeet TDT 0.6B v3 via FluidAudio** | FluidAudio Apache-2.0. Model **CC-BY-4.0** (commercial OK, attribution required). | **~190x RTF on M4 Pro** (1 h audio in ~19 s), per vendor | v3: **25 European langs**, auto-detect. v2: English only. Includes punctuation, capitalization, word timestamps. | Batch for v2/v3. Streaming via `SlidingWindowAsrManager`, plus a 120M "Parakeet EOU" streaming model (English). Includes Silero VAD and diarization (pyannote, LS-EEND, Sortformer), which suits meeting transcription. | Swift 6.0+. Some models need macOS 15. **UNCERTAIN** exact min for ASR (likely 14). | https://github.com/FluidInference/FluidAudio , https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 |
| **Apple SpeechAnalyzer / SpeechTranscriber** | System API (free) | MacStories: 34-min file in ~45 s vs Whisper large-v3 1m41s (~2.2x faster). Vendor benchmarks show lower WER than Whisper Small on LibriSpeech (**M**). | Locale set is runtime-queried (`supportedLocales`). The doc lists en-US, de-DE, es-419, fr-FR, it-IT, ja-JP, ko-KR, pt-BR, zh-CN. ~30 locales per secondary sources (**M**). | Yes: volatile + final results via AsyncSequence. `DictationTranscriber` exists for older hardware. | **macOS 26** | https://developer.apple.com/documentation/speech/speechanalyzer , https://developer.apple.com/documentation/speech/speechtranscriber , https://www.gigazine.net/gsc_news/en/20250619-apple-speech-analyzer |

- SpeechAnalyzer's models are downloaded and managed by the OS (AssetInventory). This sidesteps the model-hosting and 2.4.5(iv) questions and adds zero bundle size.
- Suggested direction (opinion):
  - Add Parakeet v3 via FluidAudio as the default English/EU engine for dictation latency. Hex proves the stack.
  - Keep whisper.cpp or switch to WhisperKit for other languages.
  - Optionally add SpeechAnalyzer when running on macOS 26+.

## Unresolved questions
- MAS at all, or direct-only? (Direct strongly recommended.)
- Pay $99 for Developer ID now, or use a self-signed cert for friends first?
- Bump min macOS to 14.2 for Core Audio taps?
- Need non-EU languages (e.g. Hindi)? Parakeet v3 doesn't cover them.
- Meeting transcripts: local-only, or will a cloud LLM summarize them? (Affects privacy copy and consent UI.)
