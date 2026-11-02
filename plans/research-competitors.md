# Research: competitors + user complaints (issue #2)

Date: 2026-11-02. Parent spec: #1. Distribution/licensing/App Store/system-audio facts are already in [research-distribution.md](research-distribution.md) and are not repeated here.

Conventions: **(unverified)** = secondary source only, or inferred. **(stale?)** = source older than ~18 months (before ~May 2025). "n/d" = not documented in the vendor docs I read.

Method + gaps:
- Primary sources: vendor docs/changelogs, GitHub READMEs/source/issues, HN threads (pulled via the Algolia API), Product Hunt reviews, the MacPowerUsers forum.
- **Reddit could not be read.** It blocks this tool's crawler and the browser route was denied. So no Reddit quotes appear below. The one Reddit-originated story (the Wispr Flow screenshots incident) is marked unverified. To fill this in, run a manual pass of r/macapps and r/ObsidianMD.
- Aiko, Otter, Krisp, Fireflies and Jamie were skipped. They are cloud/bot or file-only, and Aiko is already covered in research-distribution §5.

---

## TL;DR
- **The local dictation market is crowded and commoditised.** Parakeet + FluidAudio/WhisperKit is the default stack. HN threads are full of "I built my own" posts. Hex, Handy, VoiceInk and Spokenly are free or cheap. Yolk can't win on model speed. It can win on **reliability fundamentals + personality + meetings-into-Markdown**.
- **Nobody ships a mascot.** Overlays are waveforms, pills, notch panels, or Wispr's dockable "Flow Bar". A character overlay is open space (unverified: I found none in searches).
- **Hex is the closest analogue, and it has converged on Yolk's v2 plan.**
  - Meetings are opt-in (Labs).
  - "You/Them" Markdown goes to `~/Documents/Hex Meetings`.
  - Apple Intelligence summaries are on by default.
  - Call detection has a per-provider Ask / Always / Never setting.
  - There is a corner-snapping recording capsule.
  - Use it as the reference point, and stay different on brand/UX polish.
- **Top recurring complaints:**
  1. Cloud/privacy surprises (Wispr screenshots; Granola folders shared org-wide by default).
  2. Resource bloat (Wispr Flow ~800 MB RAM, Electron).
  3. **First words clipped.**
  4. **Paste races in Chromium/Electron.**
  5. Hotkey breakage/crashes.
  6. Meeting apps losing audio on crash, filling disks with WAV, and mic bleed.
  7. No speaker separation.
  8. Notes locked in a cloud DB (Granola exports CSV only).
- Most of these are already ticketed (#4, #5, #10, #31). The NEW items are mic-bleed/echo handling, hiding the overlay from screen share, auto-stop when a call ends, and "key moment" markers.

---

## 1. Competitor matrix (summary)

| App | Distribution / price | ASR | LLM | Meetings | Notes storage |
|---|---|---|---|---|---|
| Granola | Direct DMG; sign-in required. Basic free (notes >30 days hidden), Business $14/user/mo, Enterprise from $35 [billing](https://docs.granola.ai/help-center/managing-your-account/subscriptions-and-billing.md) | Cloud, live [transcription](https://docs.granola.ai/help-center/taking-notes/transcription.md) | Cloud | Core product | AWS US + local cache; export CSV only [export](https://docs.granola.ai/help-center/sharing/exporting-notes.md) |
| Superwhisper | Direct. Free (local Whisper, unlimited); Pro $8.49/mo, $84.99/yr or $249.99 lifetime [plans](https://superwhisper.com/docs/billing/plans.md) | Local (Whisper free; Parakeet/Cohere Pro) + cloud (Pro) | Local (S1-mini, Qwen, Tiny Aya) or cloud | Yes, bot-free, live [meetings](https://superwhisper.com/docs/meetings/overview.md) | Local `~/superwhisper/recordings`; audio kept **forever by default** [history](https://superwhisper.com/docs/get-started/history.md) |
| Wispr Flow | Direct DMG/PKG. Free (limited words/week); Pro $15/mo ($12 annual) [pricing](https://wisprflow.ai/pricing) | **Cloud** (no local option found) | Cloud | "Notetaker" beta, bot-free, live [docs](https://docs.wisprflow.ai/articles/9238501024-recording-a-meeting-with-notetaker-beta) | Wispr cloud (sync can be turned off) |
| MacWhisper | Direct (Gumroad lifetime key) + MAS twin as subscription [diff](https://docs.macwhisper.com/article/40-macwhisper-whisper-transcription-difference) | Local whisper.cpp/Parakeet; cloud optional | BYO key / Assistant sub | Beta, post-call; direct build only [meetings](https://docs.macwhisper.com/article/30-record-meetings) | Inside app (Recordings tab) |
| VoiceInk | Direct + `brew`; GPLv3 source. One-time $25 / $39 / $49 for 1/2/3 Macs [pricing](https://tryvoiceink.com/pricing) | Local + BYO cloud | Local "Refine" or BYO cloud | No (system audio is the most-upvoted open request, [#31](https://github.com/Beingpax/VoiceInk/issues/31)) | Local SQLite; auto-delete options [history](https://tryvoiceink.com/docs/transcription-history) |
| Hex | Free, MIT. The Swift app is now legacy; the Rust rewrite is at [anomalyco/hex](https://github.com/anomalyco/hex) (Mac/Win/Linux) | Local only | Apple Intelligence / OpenCode | Beta (Labs), bot-free [meetings.md](https://github.com/anomalyco/hex/blob/main/docs/features/meetings.md) | Markdown in `~/Documents/Hex Meetings` |
| Spokenly | Direct + MAS. Free (local Whisper/Parakeet, BYO key); Local+ $29 one-time; Pro $12/mo [pricing](https://spokenly.app/pricing) | Local + cloud | Cloud (Pro) / BYO | Records mic + system audio, transcribes after [docs](https://spokenly.app/docs) | History (n/d) |
| anarlog (ex-Hyprnote / Char) | MIT community app; managed "Pro (Cloud)" tier [README](https://github.com/fastrepl/hyprnote) | Local (Apple Speech/Soniqo) or cloud (Soniox) | Local / BYO / OpenRouter | Core product, bot-free | Local SQLite; Markdown is export only |

---

## 2. Per-competitor detail

### Granola (cloud meeting notes; the UX benchmark)
- **Onboarding** ([setup](https://docs.granola.ai/help-center/getting-started/setting-up-granola-for-the-first-time.md)):
  - DMG, then **mandatory Google/Microsoft SSO**, then a calendar "Select all" grant, then Mic + system-audio prompts.
  - Then a one-time 2-minute **demo meeting** video from the co-founder.
- **Starting a meeting** ([notifications](https://docs.granola.ai/help-center/taking-notes/notifications.md)):
  - Calendar notification 1 minute before events with ≥2 attendees. Clicking it opens the call link and starts transcription.
  - Ad hoc: "By detecting that your microphone is in use, Granola will prompt you to take notes".
  - **Never auto-records.** Prompts are Granola's own pop-ups, top right.
- **Audio and labels** ([transcription](https://docs.granola.ai/help-center/taking-notes/transcription.md)):
  - Captures all system audio. It "can't isolate individual apps".
  - Labels: mic = **"Me"**, system = **"Them"**, plus display-name speaker tags for Meet/Zoom/Teams. This validates Yolk's Me/Them choice.
  - Live only, no file upload. "does not record or save audio or video at any point during the call".
- **Note format:** the user types rough notes, then AI produces an "Enhanced" version shaped by a template ([templates](https://docs.granola.ai/help-center/taking-notes/customise-notes-with-templates.md)).
- **Integrations:** Notion, Slack, Zapier, CRMs, MCP; API on paid plans ([integrations](https://docs.granola.ai/help-center/sharing/integrations/integrations-with-granola.md)). **No Obsidian or Markdown export.** Community tools scrape the local cache instead, e.g. [granary](https://github.com/wassimk/granary) (unverified).
- **Privacy** ([FAQ](https://docs.granola.ai/help-center/consent-security-privacy/security-privacy-data-faqs.md)):
  - Data is on AWS US.
  - Anonymised data "may be used for Granola's own model improvements" by default on Free/Business (opt-out).
  - Transcript auto-delete is opt-in, from 1 day to 1 year ([retention](https://docs.granola.ai/help-center/consent-security-privacy/transcript-auto-deletion.md)).
- **Security:** a one-click account takeover in the Electron app. It was reported 2026-06-23 and fixed server-side the next day ([Strix](https://www.strix.ai/blog/granola)).

### Superwhisper
- **Onboarding** ([quickstart](https://superwhisper.com/docs/get-started/quickstart.md)):
  - macOS 14+.
  - Permissions: Mic, Accessibility "to insert your dictation into apps", and optional System audio.
  - The default mode uses **cloud** models. Local is a later choice.
- **Hotkey:** hold Right ⌘ by default; ⌥Space toggles.
- **Overlay** ([rec window](https://superwhisper.com/docs/get-started/interface-rec-window.md), [menu bar](https://superwhisper.com/docs/get-started/interface-menu-bar.md)):
  - A recording window with waveform, mode, Stop/Cancel, and live words with realtime models.
  - A "mini window" that can stay visible as a small indicator. Hovering lets you start or change mode.
  - The menu-bar dot is colour-coded: yellow = loading, red = recording, blue = processing, green = done. Position and dragging are n/d.
- **Paste** ([pasting issues](https://superwhisper.com/docs/common-issues/pasting-issues.md)):
  - Clipboard paste. The default "Keep what I have copied" restores the old clipboard, and "If the target app reads the clipboard late, it can pick up the restored content". This is exactly Yolk's #10 bug class.
  - The vendor's fix is to stop restoring the clipboard at all.
- **History:** every dictation is kept: audio, transcript and AI output. Default **"Forever"**. Reprocess with another mode.
- **Meetings** ([overview](https://superwhisper.com/docs/meetings/overview.md), [record](https://superwhisper.com/docs/meetings/record.md)):
  - Detection setting Off / Notify / **Auto** for Zoom, Meet, Teams and Slack huddles.
  - On-device diarization (~150 MB model), live transcript, "Speaker 1/2" with names suggested from the call.
  - ⌘M shrinks the window "to a small pill". When the call ends: "Meeting ending in 9s".
  - Dictation still works mid-meeting and "stays out of the meeting recording". This matches Yolk #33.
  - Summaries are local (Qwen 3.5 2B / Tiny Aya 3B) or cloud. File format/path n/d. No Markdown/Obsidian mentioned ([offline](https://superwhisper.com/docs/meetings/offline.md)).

### Wispr Flow
- **Onboarding** ([product-aware onboarding](https://docs.wisprflow.ai/articles/5926242953-product-aware-onboarding-choosing-dictation-notetaker-or-both-macos)):
  - Choose Dictation, Notetaker or both, then a meeting questionnaire, then permissions, then an optional calendar.
  - A dictation "practice" step exists.
  - macOS 14.4+ needs no restart for System Audio Recording Only.
- **Hotkey:** hold Fn by default ([launch post, 2024](https://news.ycombinator.com/item?id=41696153), stale?).
- **Overlay** ([Flow Bar](https://docs.wisprflow.ai/articles/1790396454-move-and-dock-the-flow-bar-on-desktop)):
  - "a small floating bubble showing your dictation status: resting, recording, or processing".
  - Bottom edge by default. **Drag to snap to the bottom, left or right edge**; it remembers the edge.
  - Right-click → "Hide for 1 hour". Clicks pass through when hidden.
  - Option to hide the Notepad and Flow Bar from screen capture/shares ([settings](https://docs.wisprflow.ai/articles/9319084321-notetaker-settings-explained-beta)).
- **ASR is cloud.** Turning off model improvement "does not stop cloud processing" ([data](https://docs.wisprflow.ai/articles/9609615338-private-cloud-sync-and-data-sharing-preferences-in-wispr-flow)).
- **Context Awareness** is on by default and sends textbox/on-screen text. It now "does not take screenshots" ([doc](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness)).
- **Notetaker** (beta) ([record](https://docs.wisprflow.ai/articles/9238501024-recording-a-meeting-with-notetaker-beta), [settings](https://docs.wisprflow.ai/articles/9319084321-notetaker-settings-explained-beta)):
  - "Automatically detect any call" is on by default. Auto-start is off by default; when on, it uses a ~10 s countdown card.
  - Max length 2 h by default. "Stop Notetaker when a call ends" is on.
  - Live transcript, summary afterwards, speaker reassignment after stop.
  - Offline: it records locally and uploads later ([offline](https://docs.wisprflow.ai/articles/5810080970-offline-meeting-recording-in-notetaker)).
  - It **posts a consent notice into meeting chat** (Meet/Zoom/Teams), on by default ([consent](https://docs.wisprflow.ai/articles/3808660402-the-meeting-recording-consent-notice-how-it-s-posted-and-how-admins-control-it)).
  - It imports from Granola/Otter.

### MacWhisper
- **Distribution:** dictation into any field and meeting detection are **direct-only** ([diff](https://docs.macwhisper.com/article/40-macwhisper-whisper-transcription-difference)).
- **Dictation** ([dictation](https://docs.macwhisper.com/article/14-how-to-use-the-dictation-feature)): per-app AI prompts (BYO OpenAI key + Pro). Hold vs toggle and overlay are n/d.
- **Meetings** ([record meetings](https://docs.macwhisper.com/article/30-record-meetings)):
  - A "Meeting Detected" notification with a 10 s timeout, for an app list that includes browsers (Arc, Chrome, Safari…), Zoom, Teams, Slack and others.
  - "FaceTime is not available due to privacy restrictions". It needs **Screen Recording** permission.
  - Others are lumped under one label; diarization is "when … released".
  - Transcribed **after** the call. Stored inside the app. The feature is beta, and its docs warn of "occasional issues or data loss".

### VoiceInk
- **Distribution and platform:** GPLv3, macOS 15+ per the [README](https://github.com/Beingpax/VoiceInk) (the pricing page says 14.4+), Apple Silicon only, ~7k stars.
- **Hotkeys** ([shortcuts](https://tryvoiceink.com/docs/shortcuts)): Toggle / Push-to-talk / **Hybrid** (short press toggles, hold ≥0.5 s = PTT) / Double-tap; mouse buttons; Esc×2 cancels.
- **Overlay:** two styles in source:
  - `NotchRecorderPanel`: centred under the notch, `isMovable = false`.
  - `MiniRecorderPanel`: floating, `isMovable = true`, joins all Spaces.
  - Sources: [NotchRecorderPanel.swift](https://github.com/Beingpax/VoiceInk/blob/main/VoiceInk/Features/Recording/Presentation/NotchRecorderPanel.swift), [MiniRecorderPanel.swift](https://github.com/Beingpax/VoiceInk/blob/main/VoiceInk/Features/Recording/Presentation/MiniRecorderPanel.swift).
- **Modes:** per-app/URL "Modes" (Paste / Respond / shell Custom Command) ([intro](https://tryvoiceink.com/docs/introduction)).
- **History:** local, searchable, replay/retry. Separate auto-delete for transcripts (immediately to 7 days) and audio (1–30 days) ([history](https://tryvoiceink.com/docs/transcription-history)).
- **Privacy page** lists exactly what leaves the device per feature ([privacy](https://tryvoiceink.com/docs/privacy-and-data)). This is a good model for Yolk's README "Network activity" (#21).
- **No meetings.** System-audio capture is its most-upvoted request ([#31](https://github.com/Beingpax/VoiceInk/issues/31), [#199](https://github.com/Beingpax/VoiceInk/issues/199)).

### Hex (closest analogue)
- **Legacy Swift app** ([kitlangton/Hex](https://github.com/kitlangton/Hex)):
  - Hold to talk, or double-tap to "lock recording".
  - Parakeet v3 via FluidAudio + WhisperKit. Mic + Accessibility. Apple Silicon only.
  - Now unmaintained; it "has moved to anomalyco/hex".
- **Rust rewrite** ([anomalyco/hex](https://github.com/anomalyco/hex), created 2026-07, ~3.5k stars, MIT):
  - Mac/Win/Linux. "We don't take pull requests… our agents usually turn it around fast."
- **Dictation** ([dictation.md](https://github.com/anomalyco/hex/blob/main/docs/features/dictation.md)):
  - Option is the default hotkey. Modifier-only/Fn/mouse bindings.
  - "dictation has no cancel: every intentional dictation finishes and pastes" (#786).
  - The HUD is a shader "Dot scope" ([design-system.md](https://github.com/anomalyco/hex/blob/main/docs/design-system.md)).
- **Meetings** ([meetings.md](https://github.com/anomalyco/hex/blob/main/docs/features/meetings.md)):
  - Opt-in (Labs). Separate mic/system tracks, local transcription, Markdown with **`You` / `Them`** turns in `~/Documents/Hex Meetings`.
  - "Recording starts automatically only for calls from a website or app set to Always record, and never stops automatically".
  - Per-provider **Ask / Always record / Never offer** (Slack, Zoom, Meet, Teams, FaceTime, WhatsApp, Gather).
  - Corner-snapping recording capsule (default top-right).
  - Apple Intelligence summary **on by default**.
  - Read-only MCP server; SRT/VTT export.
- **Permission UX worth copying** (same meetings.md):
  - The system-audio permission is asked only when Meetings is enabled.
  - If already denied, it opens the Privacy pane plus a drag guide.
  - It polls TCC with no reopen needed, and has a "Still grey? Fix it" path that resets stale TCC entries for retired bundle IDs.

### Spokenly
- **Pricing and models** ([pricing](https://spokenly.app/pricing)):
  - Free: local Whisper/Parakeet, offline, real-time, BYO OpenAI/Deepgram/Groq keys.
  - **Local+ $29 one-time** unlocks "Notch and Capsule recording styles".
  - Pro $12/mo adds managed cloud models and AI.
- **Hotkey:** hold the shortcut to talk ([docs](https://spokenly.app/docs)).
- **Meetings:** records "system audio and your microphone… without a bot joining", saved to History and transcribed afterwards. Detection, speaker labels and format are n/d.
- **MAS build** can't auto-paste (see research-distribution §2).
- **Agents:** an MCP voice-input tool lets Claude Code/Codex/Cursor ask for spoken answers ([site](https://spokenly.app)).

### anarlog (formerly Hyprnote, briefly "Char")
- **Product:** open-source, bot-free Granola alternative. Local or cloud ASR/LLM; "Cloud is opt-in, not required" ([README](https://github.com/fastrepl/hyprnote)).
- **Storage:** notes live in **SQLite**, with Markdown export.
- **Name churn:** the team's new product "char" is a separate, private-beta AI notepad ([char.com](https://char.com)).
- **Perception:** a user reported in 2026-04 that "Char/Hyprnote… have stopped supporting local models" ([HN](https://news.ycombinator.com/item?id=47701485)). This conflicts with the current README, so (unverified). The perception itself is the lesson: rebrands plus moves to the cloud erode trust.

---

## 3. Cross-cutting UX patterns

| Pattern | Who | Notes for Yolk |
|---|---|---|
| Hold-to-talk default; toggle/double-tap lock as options | Superwhisper, Hex, Spokenly, VoiceInk (Hybrid) | Yolk already has hold + toggle. VoiceInk's **Hybrid** (tap = toggle, hold = PTT on one key) is a cheap win for #5 |
| Overlay = waveform pill / notch panel / dot | All | No character overlay found. Notch styles are a *paid* upsell at Spokenly. Wispr is the only one with documented drag-to-dock |
| Persistent "resting" indicator you can click | Wispr Flow Bar, Superwhisper mini window | Matches Yolk #20 mini mode. Wispr adds "Hide for 1 hour" and click-through when hidden |
| Hide overlay from screen share | Wispr | NEW for Yolk: don't show the egg in Zoom screen shares (`NSWindow.sharingType = .none`, unverified that it hides from SCK captures) |
| Meeting start = prompt on mic use; auto-record opt-in | Granola, Superwhisper, MacWhisper, Wispr, Hex | Yolk #32 (never auto-record) matches the Granola/MacWhisper default. Hex/Superwhisper add per-app "Always" |
| Auto-stop/end prompt when call ends | Superwhisper ("ending in 9s"), Wispr (on by default) | Hex explicitly never auto-stops. NEW for Yolk: at least a prompt |
| Me/Them (You/Them) labels | Granola fallback, Hex | Validated. True diarization is the top complaint for 1:many calls (§4) |
| Dictation during meeting kept separate | Superwhisper, Wispr | Already #33 |
| Notes as plain Markdown in a user folder | Hex, Trace, Muesli; **not** Granola, Superwhisper, MacWhisper, anarlog | Yolk #28 is a real differentiator vs the big names |
| On-device summary by default | Hex (Apple Intelligence), Superwhisper (local option) | Matches #34 |

---

## 4. Recurring complaints + praise (with sources)

Reddit wasn't readable (see Method). Dates are post dates. Product Hunt shows relative dates only; approximate absolute dates are given.

### 4.1 Privacy / cloud surprises
- **Wispr Flow screenshots (unverified, secondary only).** Reviews say a Feb-2026 Reddit thread showed Context Awareness sending active-window screenshots to the cloud, followed by a CTO apology ([doolpa](https://www.doolpa.com/article/wispr-flow), [laxis](https://laxis.com/blog/wispr-flow/)). Corroborated by a PH review: "That taking screenshots thing was inexcusable." (Shaunny, ~Mar 2026, [PH](https://www.producthunt.com/products/wisprflow/reviews)). The current doc says "does not take screenshots" ([doc](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness)).
- **Granola default sharing:** "I was extremely disturbed to find out that Granola was automatically making each of my notes folders public to the entire organization. Including 1:1s" ([HN, 2025-07-30](https://news.ycombinator.com/item?id=44736878), ~15 months old).
- **Cloud is a deal-breaker for some:** "clearly the _leader_ in the space is granola, but I'm just not going to use a cloud provider for this" ([HN, 2026-08-10](https://news.ycombinator.com/item?id=49244333)).
- **Wanting privacy made explicit:** "A more explicit offline or privacy-first mode would make it easier to recommend for sensitive work." (Yangyang Dai, ~May 2026, [PH](https://www.producthunt.com/products/wisprflow/reviews)).
- **Churn toward local:** "Just canceled my WisprFlow subscription a few days ago to switch to a open source, free, local alternative" ([HN, 2026-08-17](https://news.ycombinator.com/item?id=49334327)).

### 4.2 Resource weight
- **Wispr RAM:** "it's electron based and uses 800 megabytes of RAM" (Shaunny, ~Mar 2026, [PH](https://www.producthunt.com/products/wisprflow/reviews)). A competitor's own benchmark puts Flow at ~748 MB at rest on an 8 GB Mac ([tl;dv](https://tldv.io/blog/wispr-flow-notetaker-review/), vendor-biased, unverified).
- **Long sessions:** "lowering resource usage would make it even smoother for long sessions." (Dario Pironi, ~Feb 2026, [PH](https://www.producthunt.com/products/wisprflow/reviews)).
- **Battery** comes up repeatedly for local pipelines ([HN, 2026-02-16](https://news.ycombinator.com/item?id=47040867); [HN, 2026-07-20](https://news.ycombinator.com/item?id=48973768)).

### 4.3 Dictation fundamentals
- **First words lost:**
  - VoiceInk: "the feedback sound plays immediately — but audio capture only begins ~1 second later… your first words are consistently lost" ([VoiceInk #572, 2026-03-07](https://github.com/Beingpax/VoiceInk/issues/572)).
  - Handy: "it cut off the words [I'm using] at the beginning" ([HN, 2026-02-17](https://news.ycombinator.com/item?id=47052621)).
- **Paste races in Chromium:**
  - Hex: "About 1 in 7 dictations into Chromium 155 browsers inserts nothing, while Hex logs a successful paste… the 150 ms delay… still fails" ([anomalyco/hex #212, 2026-10-26](https://github.com/anomalyco/hex/issues/212)).
  - Superwhisper documents the same stale-clipboard race ([doc](https://superwhisper.com/docs/common-issues/pasting-issues.md)).
- **Hotkey/event-tap fragility:**
  - Hex crash: "crashes immediately on every launch — dispatch_sync deadlock on the KeyEventMonitor queue" (22 👍, [kitlangton/Hex #258, 2026-07-13](https://github.com/kitlangton/Hex/issues/258)).
  - Hex: "Hotkey doesn't work on M1 Mac Sequoia" (19 👍, [#126, 2025-11-22](https://github.com/kitlangton/Hex/issues/126)).
  - opensuperwhisper: "something is overriding the default Opt+` shortcut" ([HN, 2026-09-23](https://news.ycombinator.com/item?id=49815368)).
- **Permissions broken by a bundle-ID change:** Hex beta couldn't be granted Input Monitoring/Accessibility because of a "possible bundle identifier mismatch" (`com.kitlangton.hex2`) ([anomalyco/hex #127, 2026-10-10](https://github.com/anomalyco/hex/issues/127)). This is directly relevant to the Yolk rename (#17).
- **Hallucinated tails:** "Inserting 'thank you' at the end of dictation sometimes" ([anomalyco/hex #108](https://github.com/anomalyco/hex/issues/108)). "That happens in most speech to text systems, even Superwhisper, Monologue and Wispr Flow… when there is silence" ([HN, 2026-05-02](https://news.ycombinator.com/item?id=47990553)).
- **Wanting live text:**
  - "I wish that it would slowly roll out the text as you talk instead of waiting to transcribe into the very end" ([HN, 2026-02-17](https://news.ycombinator.com/item?id=47052621)).
  - "the current non-streaming mode feels slow for longer content" (~Sep 2026, [PH](https://www.producthunt.com/products/wisprflow/reviews)).
  - Hex "Live transcription preview while speaking" ([#237](https://github.com/kitlangton/Hex/issues/237)).
- **Praise for the simple option:** "macwhisper is overkill, superwhisper too clever, and handy too buggy. hex fits just right" ([HN, 2026-02-17](https://news.ycombinator.com/item?id=47042753)). "tried em all. much love for HEX" ([HN, 2026-09-23](https://news.ycombinator.com/item?id=49824166)).
- **Praise for "it's just there":** "Flow just… appears wherever I'm typing. That's the difference between a feature and a behavior change." (~Apr 2026, [PH](https://www.producthunt.com/products/wisprflow/reviews)).

### 4.4 Meeting capture
- **The fundamentals list** ([HN, 2026-06-14](https://news.ycombinator.com/item?id=48533220)): "they all… skip the fundamentals":
  - "Crash recovery. Most of these apps are incredibly buggy and crash all the time, taking the recorded audio with them. Macwhisper is incredibly bad at this."
  - "Disk space. Many of these apps save wav files to disk."
  - "Microphone bleed… the system mic will pick up the speaker sounds, causing duplicate… transcriptions."
- **Proposed fixes** for that list: "use ADTS aac (even if process crashes, audio is saved up until it does)… AAC 64kbps mono… macOS voice isolation processing solves [bleed]" ([HN, 2026-06-15](https://news.ycombinator.com/item?id=48535750)).
- **Speaker separation:**
  - "the inability to tell who said what is a show stopper. You'll need to add speaker diarization for this to be useful for more than 1:1s." ([HN, 2025-07-30](https://news.ycombinator.com/item?id=44736736), ~15 months old).
  - VoiceInk diarization requests ([#529](https://github.com/Beingpax/VoiceInk/issues/529), [#202](https://github.com/Beingpax/VoiceInk/issues/202)).
- **Forgetting to start:** "there was enough fiddling before each call that I'd forget to start it and walk out of an hour-long meeting with nothing written down" (Trace author on MacWhisper, [HN, 2026-06-13](https://news.ycombinator.com/item?id=48521236)).
- **Wish list:** "save meetings in a simple transcription format in a local folder - connect with my calendar… name meeting transcripts accordingly - for recurring meetings, append rather than create a new transcript" ([HN, 2026-06-15](https://news.ycombinator.com/item?id=48539830)).
- **Markdown/Obsidian demand:**
  - "An OSS on device version where I can store transcripts as markdowns in my file system." ([HN, 2026-05-04](https://news.ycombinator.com/item?id=48012136)).
  - "fit my 'I just want markdown' case better" ([HN, 2026-06-15](https://news.ycombinator.com/item?id=48545225)).
  - "getting data in has consistently been the point of failure" for Obsidian ([HN, 2025-07-29](https://news.ycombinator.com/item?id=44728215), ~15 months old).
- **Key moments praised:** Trace's mid-call "key moment" hotkey + note gets called "interesting and unusual" ([HN, 2026-06-14](https://news.ycombinator.com/item?id=48529911)).
- **Anti-bloat:** "Many alternative solutions in this space are bolting on lots of 'AI frills'… what makes them start to feel heavy" ([HN, 2026-06-16](https://news.ycombinator.com/item?id=48559040)).
- **Consent:** "Is this legal to use in 2 party consent states?" ([HN, 2026-06-15](https://news.ycombinator.com/item?id=48536276)). Germany: wants to "only record my own voice due to privacy laws" ([HN](https://news.ycombinator.com/item?id=48537604)).

### 4.5 Pricing / trust
- **Price:** "floored to learn how expensive the Pro option is" (MacWhisper, [HN, 2026-06-14](https://news.ycombinator.com/item?id=48529911)). "love the return of the good old you buy, you own it mentality" ([HN](https://news.ycombinator.com/item?id=48535517)).
- **Stagnation:** "frustrated by its slow development and lack of focus [on] dictation" (MacWhisper, [HN, 2026-07-28](https://news.ycombinator.com/item?id=49081002)). "MacWhisper used to be great, but is kinda of a buggy mess now" ([HN](https://news.ycombinator.com/item?id=48533220)).
- **Overstated features:** Hyprnote advertised speaker ID before it worked. "it put the entire conversation under a single speaker" ([HN, 2025-07-30](https://news.ycombinator.com/item?id=44734986)). The founder: "I acknowledge that it's outdated" ([HN](https://news.ycombinator.com/item?id=44735152)).
- **Setup friction:** "Initial setup and permissions took a bit longer than expected" (Wispr, ~Aug 2026, [PH](https://www.producthunt.com/products/wisprflow/reviews)).

---

## 5. Ideas to adopt / avoid (ranked)

Impact: H = directly addresses a top complaint or a core differentiator; M = noticeable polish; L = nice-to-have.

| # | Idea | Adopt/Avoid | Evidence | Impact | Ticket |
|---|---|---|---|---|---|
| 1 | Pre-roll ring buffer, so the start cue never precedes capture (first word never lost) | Adopt | VoiceInk #572; HN Handy clip | H | #4 (+ #9 cue timing) |
| 2 | Paste verified against Chromium/Electron. No fixed delay; restore only after the target has read the clipboard, plus copy-with-notice fallback. Add a Chrome 20-phrase repro to the manual checklist | Adopt | Hex #212 (1 in 7 fail); Superwhisper paste doc | H | #10 |
| 3 | Event tap on its own thread, never `dispatch_sync` onto it; survive tap resets | Adopt | Hex #258 crash (22 👍), #126 | H | #5 |
| 4 | Crash-safe meeting audio in an append-safe compressed format (ADTS AAC / CAF), not raw WAV; delete after transcription by default | Adopt | HN fundamentals list (crash, disk) | H | #31 |
| 5 | Mic-bleed handling: voice-processing I/O / echo cancellation on the mic, or dedupe Me vs Them | Adopt | HN mic-bleed complaint; Trace shipped echo cancel | H | **NEW** (fits under #30/#31) |
| 6 | Plain Markdown + YAML frontmatter in a user folder; no DB lock-in | Adopt | Granola CSV-only export; anarlog SQLite; HN "I just want markdown" | H | #28, #29 |
| 7 | Mascot overlay as the brand: nobody has a character, and notch/capsule styles are a paid upsell elsewhere | Adopt | §3; Spokenly pricing; search found none (unverified) | H | #16, #19 |
| 8 | Publish verifiable privacy: per-feature "what leaves the Mac" table, in VoiceInk style; no default cloud, no screenshots, no default sharing | Adopt / avoid Wispr-Granola defaults | Wispr screenshots (unverified); Granola public folders; VoiceInk privacy page | H | #21 |
| 9 | Keep RAM/idle CPU tiny and say so (native, no Electron); state the idle RAM figure in the README | Adopt | Wispr ~800 MB complaints | M-H | #15, #8 (README line **NEW**) |
| 10 | Permission onboarding with live TCC polling, "Still grey? Fix it" deep link + drag guide; ask for system audio only when meetings are first enabled | Adopt | Hex meetings.md; Wispr setup-friction review | M-H | #22, #11 |
| 11 | Rename safety: after changing the bundle ID, detect stale TCC entries and guide a re-grant (or `tccutil reset` instructions) | Adopt | Hex #127 bundle-ID mismatch | M | #17, #22 |
| 12 | Per-app meeting policy: Ask / Always / Never per Zoom/Meet/Teams/etc. Keep "never auto-record" as the default | Adopt (opt-in "Always") | Hex, Superwhisper Auto mode; Trace "forgot to start" | M | #32 |
| 13 | End-of-call prompt ("Meeting ended — stop in 9s?") plus a max-length cap | Adopt | Superwhisper, Wispr defaults; Hex "never stops" | M | **NEW** (extend #32) |
| 14 | Hide the egg from screen shares/recordings during calls | Adopt | Wispr setting | M | **NEW** (extend #19/#20) |
| 15 | Mini egg: "hide for 1 h" plus click-through when hidden; snap to edges/corners rather than free float only | Adopt | Wispr Flow Bar; Hex corner capsule | M | #20 |
| 16 | Hybrid hotkey: tap = toggle, hold = push-to-talk on one key | Adopt | VoiceInk Hybrid; Hex double-tap lock | M | #5 |
| 17 | Strip silence hallucinations ("thank you") as well as bracket tags; trim silence before decode | Adopt | Hex #108; HN | M | #7, #10 |
| 18 | Dictation history with retry/re-transcribe from saved audio (short retention) | Adopt | Superwhisper/VoiceInk history | M | #28 (retry **NEW**) |
| 19 | Mid-meeting "key moment" hotkey that drops a timestamped marker into the note | Adopt (later) | Trace HN praise | L-M | **NEW** |
| 20 | Calendar-based meeting titles; append to recurring-meeting notes | Consider later | HN wish list | L | **NEW** (Phase 7) |
| 21 | Don't claim features before they work (diarization, local-only) | Avoid | Hyprnote speaker-ID thread; anarlog local-model confusion | M | #21 (README honesty) |
| 22 | Don't make the default mode cloud, or require an account/SSO | Avoid | Superwhisper default cloud mode; Granola mandatory SSO | M | #22 |
| 23 | Don't auto-post consent messages into meeting chat (brittle per-app automation); keep the one-time reminder + visible recording state | Avoid (for now) | Wispr consent-notice doc (needs Chrome, per-app) | L | #32 |
| 24 | Don't bolt on "AI frills"; summaries stay optional and on-device first | Avoid | Trace author; HN | L-M | #34, #35 |
| 25 | Live preview text while speaking | Defer | Most-requested in Hex/HN, but spec defers live captions | M | Out of scope (Phase 7) / **NEW** |

---

## Unresolved questions
- Do a manual Reddit pass (r/macapps, r/ObsidianMD) to confirm the Wispr screenshot story and gather Obsidian-specific asks?
- Mic bleed (#5 in §5): new ticket or fold into #30/#31?
- End-of-call prompt + max length: extend #32 or a new ticket?
- Hide the egg from screen share: default on during meetings only, or always?
- Label "Me/Them" (Granola) or "You/Them" (Hex)?
- Per-app "Always record" in v1, or Ask-only?
